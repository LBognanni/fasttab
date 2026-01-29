const std = @import("std");
const x11 = @import("x11.zig");
const ui = @import("ui.zig");
const worker = @import("worker.zig");
const thumbnail = @import("thumbnail.zig");
const nav = @import("navigation.zig");

const rl = ui.rl;
const log = std.log.scoped(.fasttab);

// Re-export navigation functions for external use
pub const moveSelectionRight = nav.moveSelectionRight;
pub const moveSelectionLeft = nav.moveSelectionLeft;
pub const moveSelectionDown = nav.moveSelectionDown;
pub const moveSelectionUp = nav.moveSelectionUp;

pub const AppError = error{
    NoWindows,
    WorkerTimeout,
    OutOfMemory,
};

/// State machine for the Alt+Tab switcher
pub const SwitcherState = enum {
    idle,
    switching,
};

/// Monitor information for window positioning
pub const MonitorInfo = struct {
    index: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Application state encapsulating all raylib window and UI management
pub const App = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ui.WindowItem),
    selected_index: usize,
    current_layout: ui.GridLayout,
    font: rl.Font,
    monitor: MonitorInfo,
    window_hidden: bool,
    daemon_mode: bool,
    should_quit: bool,
    update_queue: ?*worker.UpdateQueue,
    xcb_conn: *x11.xcb.xcb_connection_t,
    xcb_root: x11.xcb.xcb_window_t,
    xcb_atoms: x11.Atoms,
    state: SwitcherState,
    icon_texture_cache: std.StringHashMap(rl.Texture2D),

    const Self = @This();

    /// Initialize the application with items from the worker
    pub fn init(
        allocator: std.mem.Allocator,
        initial_result: *worker.RefreshResult,
        mouse_pos: x11.MousePosition,
        daemon_mode: bool,
        update_queue: ?*worker.UpdateQueue,
        xcb_conn: *x11.xcb.xcb_connection_t,
        xcb_root: x11.xcb.xcb_window_t,
        xcb_atoms: x11.Atoms,
    ) !Self {
        // Build initial window items from worker result
        var items = std.ArrayList(ui.WindowItem).init(allocator);
        errdefer {
            for (items.items) |*item| {
                item.thumbnail.deinit();
                if (!std.mem.eql(u8, item.title, "(unknown)")) {
                    allocator.free(item.title);
                }
            }
            items.deinit();
        }

        try items.ensureTotalCapacity(initial_result.updates.items.len);

        // Build icon texture cache from initial updates
        var icon_texture_cache = std.StringHashMap(rl.Texture2D).init(allocator);

        for (initial_result.updates.items) |*upd| {
            const thumb = thumbnail.Thumbnail{
                .data = upd.thumbnail_data,
                .width = upd.thumbnail_width,
                .height = upd.thumbnail_height,
                .allocator = upd.allocator,
            };

            items.appendAssumeCapacity(ui.WindowItem{
                .id = upd.window_id,
                .title = upd.title,
                .thumbnail = thumb,
                .texture = undefined,
                .icon_texture = null,
                .wm_class = upd.wm_class,
                .display_width = 0,
                .display_height = 0,
            });

            // Transfer ownership - prevent deinit from freeing
            upd.thumbnail_data = &[_]u8{};
            upd.title = "(unknown)";
            upd.wm_class = "(unknown)";
        }

        // Calculate initial layout
        const layout = ui.calculateGridLayout(items.items, ui.THUMBNAIL_HEIGHT);

        // Create raylib window
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        rl.InitWindow(@intCast(layout.total_width), @intCast(layout.total_height), "FastTab");
        rl.SetTargetFPS(60);

        // Load system font
        const font = ui.loadSystemFont(ui.TITLE_FONT_SIZE * 2);

        // Load textures from thumbnails and icons
        for (items.items) |*item| {
            item.texture = ui.loadTextureFromThumbnail(&item.thumbnail);
        }

        // Process icon data from initial updates (textures must be created after InitWindow)
        for (initial_result.updates.items, 0..) |*upd, i| {
            if (upd.icon_data) |icon_data| {
                const wm_class = items.items[i].wm_class;
                if (!std.mem.eql(u8, wm_class, "(unknown)") and !icon_texture_cache.contains(wm_class)) {
                    const icon_thumb = thumbnail.Thumbnail{
                        .data = icon_data,
                        .width = upd.icon_width,
                        .height = upd.icon_height,
                        .allocator = upd.allocator,
                    };
                    const icon_tex = ui.loadTextureFromThumbnail(&icon_thumb);
                    const cache_key = allocator.dupe(u8, wm_class) catch continue;
                    icon_texture_cache.put(cache_key, icon_tex) catch {
                        allocator.free(cache_key);
                        rl.UnloadTexture(icon_tex);
                        continue;
                    };
                }
                // Free the icon data - we've uploaded it to GPU
                upd.allocator.free(icon_data);
                upd.icon_data = null;
            }
        }

        // Assign icon textures to items from cache
        for (items.items) |*item| {
            if (!std.mem.eql(u8, item.wm_class, "(unknown)")) {
                item.icon_texture = icon_texture_cache.get(item.wm_class);
            }
        }

        // Find monitor containing mouse cursor
        const monitor = findMonitorAtPosition(mouse_pos);

        // Non-daemon mode: center window on monitor
        const win_x = monitor.x + @divTrunc(monitor.width - @as(i32, @intCast(layout.total_width)), 2);
        const win_y = monitor.y + @divTrunc(monitor.height - @as(i32, @intCast(layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);
        log.info("App initialized: {d} windows, monitor {d} at ({d},{d})", .{
            items.items.len,
            monitor.index,
            monitor.x,
            monitor.y,
        });

        return Self{
            .allocator = allocator,
            .items = items,
            .selected_index = 0,
            .current_layout = layout,
            .font = font,
            .monitor = monitor,
            .window_hidden = false,
            .daemon_mode = daemon_mode,
            .should_quit = false,
            .update_queue = update_queue,
            .xcb_conn = xcb_conn,
            .xcb_root = xcb_root,
            .xcb_atoms = xcb_atoms,
            .state = .idle,
            .icon_texture_cache = icon_texture_cache,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        // Unload textures and close window (window stays open even when "hidden")
        for (self.items.items) |*item| {
            rl.UnloadTexture(item.texture);
            // Don't unload icon_texture here - it's shared via icon_texture_cache
        }

        // Unload icon textures from cache
        var icon_iter = self.icon_texture_cache.iterator();
        while (icon_iter.next()) |entry| {
            rl.UnloadTexture(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.icon_texture_cache.deinit();

        rl.UnloadFont(self.font);
        rl.CloseWindow();

        // Free item data
        for (self.items.items) |*item| {
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                self.allocator.free(item.title);
            }
            if (!std.mem.eql(u8, item.wm_class, "(unknown)")) {
                self.allocator.free(item.wm_class);
            }
        }
        self.items.deinit();
    }

    /// Check if the app should continue running
    pub fn isRunning(self: *const Self) bool {
        return !self.should_quit;
    }

    /// Get the number of windows
    pub fn windowCount(self: *const Self) usize {
        return self.items.items.len;
    }

    /// Get the current layout
    pub fn getLayout(self: *const Self) ui.GridLayout {
        return self.current_layout;
    }

    /// Get the X11 window ID of the raylib window
    pub fn getWindowId(self: *const Self) x11.xcb.xcb_window_t {
        _ = self;
        const handle_ptr = rl.GetWindowHandle();
        if (handle_ptr == null) {
            log.err("GetWindowHandle returned null", .{});
            return 0;
        }

        // Debug: print raw pointer and first bytes
        const ptr_bytes: [*]const u8 = @ptrCast(handle_ptr);
        log.debug("GetWindowHandle ptr: {*}, bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
            handle_ptr,
            ptr_bytes[0],
            ptr_bytes[1],
            ptr_bytes[2],
            ptr_bytes[3],
            ptr_bytes[4],
            ptr_bytes[5],
            ptr_bytes[6],
            ptr_bytes[7],
        });

        // Try reading as u32 (xcb_window_t size)
        var window_id_32: u32 = 0;
        @memcpy(std.mem.asBytes(&window_id_32), ptr_bytes[0..4]);
        log.debug("As u32: {d}", .{window_id_32});

        // Try reading as c_ulong (X11 Window type)
        var window_id_64: c_ulong = 0;
        @memcpy(std.mem.asBytes(&window_id_64), ptr_bytes[0..@sizeOf(c_ulong)]);
        log.debug("As c_ulong: {d}", .{window_id_64});

        if (window_id_32 != 0) {
            return window_id_32;
        }
        return @intCast(window_id_64);
    }

    /// Process one frame: check for window close, render
    pub fn update(self: *Self) void {
        if (self.window_hidden) {
            // In daemon mode with hidden window, skip rendering
            std.time.sleep(16 * std.time.ns_per_ms);
            return;
        }

        // Check if window should close (fallback for window manager close)
        if (rl.WindowShouldClose()) {
            if (self.daemon_mode) {
                self.cancelSwitching();
            } else {
                self.should_quit = true;
                return;
            }
        }

        // Render (all keyboard input is handled via XCB events)
        self.render();
    }

    /// Process an update from the background worker
    pub fn processWorkerUpdate(self: *Self, update_result: *worker.RefreshResult) void {
        // if (self.window_hidden) {
        //     log.debug("Processing update while hidden: {d} current windows, {d} updates", .{
        //         update_result.current_window_ids.items.len,
        //         update_result.updates.items.len,
        //     });
        // }

        // Build set of current window IDs
        var current_window_set = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(self.allocator);
        defer current_window_set.deinit();
        for (update_result.current_window_ids.items) |wid| {
            current_window_set.put(wid, {}) catch {};
        }

        // Find and remove closed windows
        self.removeClosedWindows(&current_window_set);

        // Process updates for existing and new windows
        self.applyWindowUpdates(update_result);

        // Adjust selected index
        if (self.items.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.items.items.len) {
            self.selected_index = self.items.items.len - 1;
        }

        // Recalculate and update layout
        self.updateLayout();
    }

    /// Move selection to next window (wraps around)
    pub fn selectNext(self: *Self) void {
        if (self.items.items.len == 0) return;
        self.selected_index = (self.selected_index + 1) % self.items.items.len;
    }

    /// Move selection to previous window (wraps around)
    pub fn selectPrev(self: *Self) void {
        if (self.items.items.len == 0) return;
        if (self.selected_index == 0) {
            self.selected_index = self.items.items.len - 1;
        } else {
            self.selected_index -= 1;
        }
    }

    /// Hide the switcher window
    pub fn hideWindow(self: *Self) void {
        log.debug("Hiding window", .{});

        // Notify worker that window is hidden (optimize captures)
        if (self.update_queue) |queue| {
            queue.setWindowVisible(false);
        }

        rl.SetWindowState(rl.FLAG_WINDOW_HIDDEN);

        self.window_hidden = true;
    }

    /// Show the switcher window (public for socket commands)
    pub fn showWindow(self: *Self) void {
        log.debug("Showing window with {d} items", .{self.items.items.len});

        // Notify worker that window is visible (capture all windows)
        if (self.update_queue) |queue| {
            queue.setWindowVisible(true);
        }

        // Recalculate layout and resize window if needed
        const prev_layout = self.current_layout;
        self.current_layout = ui.calculateGridLayout(self.items.items, ui.THUMBNAIL_HEIGHT);

        if (self.current_layout.total_width != prev_layout.total_width or
            self.current_layout.total_height != prev_layout.total_height)
        {
            rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
        }

        // Query current mouse position and find monitor
        const mouse_pos = x11.getMousePosition(self.xcb_conn, self.xcb_root);
        self.monitor = findMonitorAtPosition(mouse_pos);

        // Center window on monitor
        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        // Show the window and focus it
        rl.ClearWindowState(rl.FLAG_WINDOW_HIDDEN);
        rl.SetWindowFocused();

        self.window_hidden = false;
    }

    // === Alt+Tab state machine ===

    /// Handle initial Alt+Tab press: grab keyboard, reorder by stacking, show switcher.
    pub fn handleAltTab(self: *Self, shift: bool) void {
        if (self.state == .switching) {
            // Already switching, treat as Tab press
            if (shift) {
                self.selectPrev();
            } else {
                self.selectNext();
            }
            return;
        }

        // Grab the keyboard so we get all key events during switching
        if (!x11.grabKeyboard(self.xcb_conn, self.xcb_root)) {
            log.err("Could not grab keyboard, aborting Alt+Tab", .{});
            return;
        }

        // Reorder items by stacking order (MRU)
        self.reorderByStacking();

        // Show the switcher
        if (shift) {
            // Shift+Tab: select last item
            if (self.items.items.len > 0) {
                self.selected_index = self.items.items.len - 1;
            }
        } else {
            // Tab: select index 1 (previous window) if available
            if (self.items.items.len > 1) {
                self.selected_index = 1;
            } else {
                self.selected_index = 0;
            }
        }

        self.showWindow();
        self.state = .switching;
        log.info("Alt+Tab switching started (shift={}, selected={d})", .{ shift, self.selected_index });
    }

    /// Handle a key event during switching.
    /// Returns true if the event was consumed.
    pub fn handleKeyEvent(self: *Self, keysym: u32, is_press: bool, state_mask: u16) bool {
        _ = state_mask;

        if (self.state != .switching) {
            return false;
        }

        if (!is_press) {
            // Key release: check for Alt release to confirm
            if (keysym == x11.XK_Alt_L or keysym == x11.XK_Alt_R) {
                self.confirmSwitching();
                return true;
            }
            return false;
        }

        // Key press during switching
        switch (keysym) {
            x11.XK_Tab => {
                self.selectNext();
                return true;
            },
            x11.XK_ISO_Left_Tab => {
                self.selectPrev();
                return true;
            },
            x11.XK_Escape => {
                self.cancelSwitching();
                return true;
            },
            x11.XK_Return => {
                self.confirmSwitching();
                return true;
            },
            x11.XK_Right => {
                self.selected_index = nav.moveSelectionRight(self.selected_index, self.items.items.len);
                return true;
            },
            x11.XK_Left => {
                self.selected_index = nav.moveSelectionLeft(self.selected_index, self.items.items.len);
                return true;
            },
            x11.XK_Down => {
                self.selected_index = nav.moveSelectionDown(self.selected_index, self.current_layout.columns, self.items.items.len);
                return true;
            },
            x11.XK_Up => {
                self.selected_index = nav.moveSelectionUp(self.selected_index, self.current_layout.columns);
                return true;
            },
            else => return false,
        }
    }

    /// Confirm switching: activate selected window, ungrab keyboard, hide
    pub fn confirmSwitching(self: *Self) void {
        if (self.state != .switching) return;

        // Activate the selected window
        if (self.items.items.len > 0 and self.selected_index < self.items.items.len) {
            const selected_id = self.items.items[self.selected_index].id;
            x11.activateWindow(self.xcb_conn, self.xcb_root, selected_id, self.xcb_atoms);
            log.info("Confirmed: activating window {d}", .{selected_id});
        }

        x11.ungrabKeyboard(self.xcb_conn);
        self.hideWindow();
        self.state = .idle;
    }

    /// Cancel switching: ungrab keyboard, hide (no activation)
    pub fn cancelSwitching(self: *Self) void {
        if (self.state != .switching) return;

        log.info("Switching cancelled", .{});
        x11.ungrabKeyboard(self.xcb_conn);
        self.hideWindow();
        self.state = .idle;
    }

    /// Reorder internal items to match stacking order (reversed = MRU first)
    fn reorderByStacking(self: *Self) void {
        const stacking = x11.getStackingWindowList(self.allocator, self.xcb_conn, self.xcb_root, self.xcb_atoms) catch |err| {
            log.warn("Could not get stacking list: {}", .{err});
            return;
        };
        defer self.allocator.free(stacking);

        if (stacking.len == 0) return;

        // Build a new ordering: stacking list reversed (topmost = MRU = first)
        var new_items = std.ArrayList(ui.WindowItem).init(self.allocator);
        defer new_items.deinit();
        new_items.ensureTotalCapacity(self.items.items.len) catch return;

        // Walk stacking list in reverse (topmost first)
        var si: usize = stacking.len;
        while (si > 0) {
            si -= 1;
            const stacking_id = stacking[si];
            for (self.items.items) |item| {
                if (item.id == stacking_id) {
                    new_items.appendAssumeCapacity(item);
                    break;
                }
            }
        }

        // Add any items that weren't in the stacking list (shouldn't happen normally)
        for (self.items.items) |item| {
            var found = false;
            for (new_items.items) |new_item| {
                if (new_item.id == item.id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                new_items.append(item) catch continue;
            }
        }

        // Replace items list (shallow copy, no memory to free since items are shared)
        self.items.clearRetainingCapacity();
        for (new_items.items) |item| {
            self.items.append(item) catch continue;
        }
    }

    // === Private methods ===

    fn render(self: *Self) void {
        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        ui.renderSwitcher(self.items.items, self.selected_index, self.font);
        rl.EndDrawing();
    }

    fn removeClosedWindows(self: *Self, current_window_set: *std.AutoHashMap(x11.xcb.xcb_window_t, void)) void {
        // Find windows to remove
        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();

        for (self.items.items, 0..) |item, idx| {
            if (!current_window_set.contains(item.id)) {
                to_remove.append(idx) catch {};
            }
        }

        // Remove in reverse order to maintain indices
        var remove_idx: usize = to_remove.items.len;
        while (remove_idx > 0) {
            remove_idx -= 1;
            const idx = to_remove.items[remove_idx];
            const item = &self.items.items[idx];

            rl.UnloadTexture(item.texture);
            // Don't unload icon_texture - shared via cache
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                self.allocator.free(item.title);
            }
            if (!std.mem.eql(u8, item.wm_class, "(unknown)")) {
                self.allocator.free(item.wm_class);
            }
            _ = self.items.orderedRemove(idx);
            log.debug("Removed window at index {d}", .{idx});
        }
    }

    fn applyWindowUpdates(self: *Self, update_result: *worker.RefreshResult) void {
        for (update_result.updates.items) |*upd| {
            // Find existing item
            var found_idx: ?usize = null;
            for (self.items.items, 0..) |item, idx| {
                if (item.id == upd.window_id) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                // Update existing window
                self.updateExistingWindow(idx, upd);
            } else {
                // Add new window
                self.addNewWindow(upd);
            }
        }
    }

    fn updateExistingWindow(self: *Self, idx: usize, upd: *worker.ThumbnailUpdate) void {
        const item = &self.items.items[idx];

        const new_thumb = thumbnail.Thumbnail{
            .data = upd.thumbnail_data,
            .width = upd.thumbnail_width,
            .height = upd.thumbnail_height,
            .allocator = upd.allocator,
        };

        // Update thumbnail data and texture
        item.thumbnail.deinit();
        item.thumbnail = new_thumb;

        const new_texture = ui.loadTextureFromThumbnail(&new_thumb);
        rl.UnloadTexture(item.texture);
        item.texture = new_texture;

        // Transfer ownership
        upd.thumbnail_data = &[_]u8{};

        // Update icon if missing
        if (item.icon_texture == null) {
            self.processIconForItem(item, upd);
        }
    }

    fn addNewWindow(self: *Self, upd: *worker.ThumbnailUpdate) void {
        const new_thumb = thumbnail.Thumbnail{
            .data = upd.thumbnail_data,
            .width = upd.thumbnail_width,
            .height = upd.thumbnail_height,
            .allocator = upd.allocator,
        };

        const texture = ui.loadTextureFromThumbnail(&new_thumb);

        var new_item = ui.WindowItem{
            .id = upd.window_id,
            .title = upd.title,
            .thumbnail = new_thumb,
            .texture = texture,
            .icon_texture = null,
            .wm_class = upd.wm_class,
            .display_width = 0,
            .display_height = 0,
        };

        // Process icon for this new item
        self.processIconForItem(&new_item, upd);

        self.items.append(new_item) catch {
            rl.UnloadTexture(texture);
            if (!std.mem.eql(u8, new_item.wm_class, "(unknown)")) {
                self.allocator.free(new_item.wm_class);
            }
            return;
        };

        log.debug("Added new window {d}: {s}", .{ new_item.id, new_item.title });

        // Transfer ownership
        upd.thumbnail_data = &[_]u8{};
        upd.title = "(unknown)";
        upd.wm_class = "(unknown)";
    }

    /// Process icon data from a ThumbnailUpdate and assign icon_texture to item.
    /// Checks the icon_texture_cache first, then creates from icon_data if available.
    fn processIconForItem(self: *Self, item: *ui.WindowItem, upd: *worker.ThumbnailUpdate) void {
        const wm_class = item.wm_class;
        if (std.mem.eql(u8, wm_class, "(unknown)")) return;

        // Check cache first
        if (self.icon_texture_cache.get(wm_class)) |cached_tex| {
            item.icon_texture = cached_tex;
            return;
        }

        // Create from icon_data if available
        if (upd.icon_data) |icon_data| {
            const icon_thumb = thumbnail.Thumbnail{
                .data = icon_data,
                .width = upd.icon_width,
                .height = upd.icon_height,
                .allocator = upd.allocator,
            };
            const icon_tex = ui.loadTextureFromThumbnail(&icon_thumb);
            const cache_key = self.allocator.dupe(u8, wm_class) catch {
                rl.UnloadTexture(icon_tex);
                return;
            };
            self.icon_texture_cache.put(cache_key, icon_tex) catch {
                self.allocator.free(cache_key);
                rl.UnloadTexture(icon_tex);
                return;
            };
            item.icon_texture = icon_tex;

            // Free the icon data - uploaded to GPU
            upd.allocator.free(icon_data);
            upd.icon_data = null;
        }
    }

    fn updateLayout(self: *Self) void {
        const prev_width = self.current_layout.total_width;
        const prev_height = self.current_layout.total_height;
        self.current_layout = ui.calculateGridLayout(self.items.items, ui.THUMBNAIL_HEIGHT);

        // Only update window size/position if window is visible and size changed
        if (!self.window_hidden and (self.current_layout.total_width != prev_width or self.current_layout.total_height != prev_height)) {
            rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
            const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
            const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
            rl.SetWindowPosition(win_x, win_y);
            log.debug("Window resized to {d}x{d}", .{ self.current_layout.total_width, self.current_layout.total_height });
        }
    }
};

/// Find the monitor containing the given position
pub fn findMonitorAtPosition(pos: x11.MousePosition) MonitorInfo {
    const monitor_count = rl.GetMonitorCount();

    var m: i32 = 0;
    while (m < monitor_count) : (m += 1) {
        const mx = rl.GetMonitorPosition(m).x;
        const my = rl.GetMonitorPosition(m).y;
        const mw = rl.GetMonitorWidth(m);
        const mh = rl.GetMonitorHeight(m);

        if (pos.x >= @as(i32, @intFromFloat(mx)) and
            pos.x < @as(i32, @intFromFloat(mx)) + mw and
            pos.y >= @as(i32, @intFromFloat(my)) and
            pos.y < @as(i32, @intFromFloat(my)) + mh)
        {
            return MonitorInfo{
                .index = m,
                .x = @intFromFloat(mx),
                .y = @intFromFloat(my),
                .width = mw,
                .height = mh,
            };
        }
    }

    // Default to first monitor
    return MonitorInfo{
        .index = 0,
        .x = 0,
        .y = 0,
        .width = 1920,
        .height = 1080,
    };
}
