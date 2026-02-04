const std = @import("std");
const x11 = @import("x11.zig");
const ui = @import("ui.zig");
const worker = @import("worker.zig");
const thumbnail = @import("thumbnail.zig");
const nav = @import("navigation.zig");

const rl = ui.rl;
const log = std.log.scoped(.fasttab);

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
    items: std.ArrayList(ui.DisplayWindow),
    selected_index: usize,
    mouseover_index: ?usize,
    current_layout: ui.GridLayout,
    font: rl.Font,
    monitor: MonitorInfo,
    window_hidden: bool,
    daemon_mode: bool,
    should_quit: bool,
    update_queue: ?*worker.TaskQueue,
    temp_tasks: std.ArrayList(worker.UpdateTask),
    conn: *x11.Connection,
    state: SwitcherState,
    icon_texture_cache: std.StringHashMap(rl.Texture2D),
    window_textures: std.AutoHashMap(x11.xcb.xcb_window_t, x11.WindowTexture),
    focus_grace_frames: u8,

    const Self = @This();

    /// Initialize the application with items from the worker
    pub fn init(
        allocator: std.mem.Allocator,
        task_queue: *worker.TaskQueue,
        daemon_mode: bool,
        conn: *x11.Connection,
    ) !Self {
        // Create empty items list and caches
        const items = std.ArrayList(ui.DisplayWindow).init(allocator);
        const icon_texture_cache = std.StringHashMap(rl.Texture2D).init(allocator);
        const window_textures = std.AutoHashMap(x11.xcb.xcb_window_t, x11.WindowTexture).init(allocator);
        const temp_tasks = std.ArrayList(worker.UpdateTask).init(allocator);

        // Create raylib window (hidden initially)
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST | rl.FLAG_WINDOW_HIDDEN);
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        // Initial size doesn't matter much as it starts hidden and resizes on show
        rl.InitWindow(800, 600, "FastTab");
        rl.SetTargetFPS(60);

        // Load system font
        const font = ui.loadSystemFont(ui.TITLE_FONT_SIZE);

        // Default layout
        const layout = ui.GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = ui.THUMBNAIL_HEIGHT,
            .total_width = ui.PADDING * 2,
            .total_height = ui.PADDING * 2,
        };

        // Default monitor (updated on show)
        const monitor = MonitorInfo{
            .index = 0,
            .x = 0,
            .y = 0,
            .width = 1920,
            .height = 1080,
        };

        var self = Self{
            .allocator = allocator,
            .items = items,
            .selected_index = 0,
            .mouseover_index = null,
            .current_layout = layout,
            .font = font,
            .monitor = monitor,
            .window_hidden = true,
            .daemon_mode = daemon_mode,
            .should_quit = false,
            .update_queue = task_queue,
            .temp_tasks = temp_tasks,
            .conn = conn,
            .state = .idle,
            .icon_texture_cache = icon_texture_cache,
            .window_textures = window_textures,
            .focus_grace_frames = 0,
        };

        // Process initial tasks
        self.drainUpdateQueue();

        log.info("App initialized: {d} windows tracked", .{self.items.items.len});

        return self;
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        // Unload textures and close window
        for (self.items.items) |*item| {
            // Check if this is a GLX texture (owned by window_textures)
            if (self.window_textures.contains(item.id)) {
                // Don't unload GLX textures here - they're owned by window_textures
            } else {
                // Regular texture - unload it
                rl.UnloadTexture(item.thumbnail_texture);
            }
            // Don't unload icon_texture here - it's shared via icon_texture_cache
            // Free owned fields
            self.allocator.free(item.title);
            self.allocator.free(item.icon_id);
        }
        self.items.deinit();

        // Clean up window textures
        var tex_iter = self.window_textures.valueIterator();
        while (tex_iter.next()) |tex| {
            var t = tex.*;
            t.deinit(self.conn);
        }
        self.window_textures.deinit();

        // Unload icon textures from cache
        var icon_iter = self.icon_texture_cache.iterator();
        while (icon_iter.next()) |entry| {
            rl.UnloadTexture(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.icon_texture_cache.deinit();

        // Clean up temp tasks
        for (self.temp_tasks.items) |*task| {
            task.deinit();
        }
        self.temp_tasks.deinit();

        rl.UnloadFont(self.font);
        rl.CloseWindow();
    }

    /// Check if the app should continue running
    pub fn isRunning(self: *const Self) bool {
        return !self.should_quit;
    }

    /// Get the number of windows
    pub fn windowCount(self: *const Self) usize {
        return self.items.items.len;
    }

    /// Process one frame: check for window close, render
    pub fn update(self: *Self) void {
        if (self.window_hidden) {
            // In daemon mode with hidden window, skip rendering
            std.time.sleep(16 * std.time.ns_per_ms);
            return;
        }

        // Check if window should close
        if (rl.WindowShouldClose()) {
            if (self.daemon_mode) {
                self.cancelSwitching();
            } else {
                self.should_quit = true;
                return;
            }
        }

        // Cancel switching if window loses focus (e.g., clicked outside)
        if (self.focus_grace_frames > 0) {
            self.focus_grace_frames -= 1;
        } else if (self.state == .switching and !rl.IsWindowFocused()) {
            self.cancelSwitching();
            return;
        }

        // Handle mouse input
        const mouse_pos = rl.GetMousePosition();
        if (ui.getItemAtPosition(self.items.items, self.current_layout, mouse_pos)) |idx| {
            rl.SetMouseCursor(rl.MOUSE_CURSOR_POINTING_HAND);
            self.mouseover_index = idx;
            if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
                self.selected_index = idx;
                self.confirmSwitching();
            }
        } else {
            rl.SetMouseCursor(rl.MOUSE_CURSOR_DEFAULT);
            self.mouseover_index = null;
        }

        // Render
        self.render();
    }

    pub fn drainUpdateQueue(self: *Self) void {
        const queue = self.update_queue orelse return;

        // Move tasks to temp buffer
        _ = queue.drainAll(&self.temp_tasks);
        if (self.temp_tasks.items.len == 0) return;

        var any_changes = false;

        for (self.temp_tasks.items) |*task| {
            any_changes = true;
            switch (task.*) {
                .window_added => |*data| {
                    // Try to create GLX texture if available
                    var texture: rl.Texture2D = undefined;
                    var source_width: u32 = 0;
                    var source_height: u32 = 0;

                    if (self.conn.use_glx and !data.is_minimized) {
                        const win_tex = x11.createWindowTexture(self.conn, data.window_id) catch |err| {
                            log.err("GLX texture failed for {x}: {}, falling back to XCB", .{ data.window_id, err });
                            // TODO: Fallback to XCB capture
                            continue;
                        };

                        texture = win_tex.toRaylibTexture();
                        source_width = win_tex.width;
                        source_height = win_tex.height;

                        self.window_textures.put(data.window_id, win_tex) catch {
                            var t = win_tex;
                            t.deinit(self.conn);
                            continue;
                        };
                    } else {
                        // GLX not available or window minimized - skip for now
                        // TODO: Implement XCB fallback
                        log.warn("GLX not available for window {x}, skipping", .{data.window_id});
                        continue;
                    }

                    // Look up icon
                    var icon_tex: ?rl.Texture2D = null;
                    if (self.icon_texture_cache.get(data.icon_id)) |tex| {
                        icon_tex = tex;
                    }

                    // Create display window (taking ownership of title and icon_id)
                    const new_item = ui.DisplayWindow{
                        .id = data.window_id,
                        .title = data.title,
                        .thumbnail_texture = texture,
                        .icon_texture = icon_tex,
                        .icon_id = data.icon_id,
                        .title_version = 1,
                        .thumbnail_version = 1,
                        .source_width = source_width,
                        .source_height = source_height,
                        .display_width = 0,
                        .display_height = 0,
                        .is_glx = self.conn.use_glx,
                    };

                    self.items.append(new_item) catch {
                        // Free the strings since we failed to append
                        self.allocator.free(data.title);
                        self.allocator.free(data.icon_id);
                        if (self.window_textures.fetchRemove(data.window_id)) |entry| {
                            var t = entry.value;
                            t.deinit(self.conn);
                        }
                        continue;
                    };

                    // Clear ownership from task
                    data.title = &[_]u8{};
                    data.icon_id = &[_]u8{};
                },

                .window_removed => |*data| {
                    for (self.items.items, 0..) |*item, i| {
                        if (item.id == data.window_id) {
                            // Clean up WindowTexture if it exists
                            if (self.window_textures.fetchRemove(data.window_id)) |entry| {
                                var tex = entry.value;
                                tex.deinit(self.conn);
                            } else {
                                // Not a GLX texture, unload normally
                                rl.UnloadTexture(item.thumbnail_texture);
                            }
                            self.allocator.free(item.title);
                            self.allocator.free(item.icon_id);
                            _ = self.items.orderedRemove(i);
                            break;
                        }
                    }
                },

                .thumbnail_updated => |*data| {
                    for (self.items.items) |*item| {
                        if (item.id == data.window_id) {
                            if (data.thumbnail_version > item.thumbnail_version) {
                                rl.UnloadTexture(item.thumbnail_texture);
                                const thumb = thumbnail.Thumbnail{
                                    .data = data.thumbnail_data,
                                    .width = data.thumbnail_width,
                                    .height = data.thumbnail_height,
                                    .allocator = data.allocator,
                                };
                                item.thumbnail_texture = ui.loadTextureFromThumbnail(&thumb);
                                item.thumbnail_version = data.thumbnail_version;
                                item.source_width = data.thumbnail_width;
                                item.source_height = data.thumbnail_height;
                            }
                            break;
                        }
                    }
                    // Free pixel data
                    data.allocator.free(data.thumbnail_data);
                    data.thumbnail_data = &[_]u8{};
                },

                .title_updated => |*data| {
                    var found = false;
                    for (self.items.items) |*item| {
                        if (item.id == data.window_id) {
                            found = true;
                            if (data.title_version > item.title_version) {
                                self.allocator.free(item.title);
                                item.title = data.title;
                                item.title_version = data.title_version;
                                // Clear from task
                                data.title = &[_]u8{};
                            }
                            break;
                        }
                    }
                    if (!found or data.title.len > 0) {
                        // If not used, free it
                        if (data.title.len > 0) data.allocator.free(data.title);
                        data.title = &[_]u8{};
                    }
                },

                .icon_added => |*data| {
                    const thumb = thumbnail.Thumbnail{
                        .data = data.icon_data,
                        .width = data.icon_width,
                        .height = data.icon_height,
                        .allocator = data.allocator,
                    };
                    const texture = ui.loadTextureFromThumbnail(&thumb);

                    self.icon_texture_cache.put(data.icon_id, texture) catch {
                        rl.UnloadTexture(texture);
                        data.allocator.free(data.icon_id);
                        data.allocator.free(data.icon_data);
                        data.icon_id = &[_]u8{};
                        data.icon_data = &[_]u8{};
                        continue;
                    };

                    // Update all items that use this icon
                    for (self.items.items) |*item| {
                        if (std.mem.eql(u8, item.icon_id, data.icon_id)) {
                            item.icon_texture = texture;
                        }
                    }

                    // Clear ownership from task
                    // icon_id is now owned by map key
                    data.icon_id = &[_]u8{};
                    // icon_data uploaded to GPU, free it
                    data.allocator.free(data.icon_data);
                    data.icon_data = &[_]u8{};
                },
            }
        }

        // Clean up tasks
        for (self.temp_tasks.items) |*task| {
            task.deinit();
        }
        self.temp_tasks.clearRetainingCapacity();

        if (any_changes) {
            // Adjust selected index if out of bounds
            if (self.items.items.len == 0) {
                self.selected_index = 0;
            } else if (self.selected_index >= self.items.items.len) {
                self.selected_index = self.items.items.len - 1;
            }

            // Recalculate layout
            self.updateLayout();
        }
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

        // Notify worker that window is hidden
        if (self.update_queue) |queue| {
            queue.setWindowVisible(false);
        }

        rl.SetWindowState(rl.FLAG_WINDOW_HIDDEN);

        self.window_hidden = true;
    }

    /// Show the switcher window (public for socket commands)
    pub fn showWindow(self: *Self) void {
        log.debug("Showing window with {d} items", .{self.items.items.len});

        // Notify worker that window is visible
        if (self.update_queue) |queue| {
            queue.setWindowVisible(true);
        }

        // Recalculate layout
        self.current_layout = ui.calculateBestLayout(self.items.items);

        // Query current mouse position and find monitor
        const mouse_pos = x11.getMousePosition(self.conn.conn, self.conn.root);
        self.monitor = findMonitorAtPosition(mouse_pos);

        rl.ClearWindowState(rl.FLAG_WINDOW_HIDDEN);

        // Set size after showing - SetWindowSize on a hidden window may not take effect
        rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));

        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        rl.SetWindowFocused();

        self.focus_grace_frames = 5;
        self.window_hidden = false;
    }

    // === Alt+Tab state machine ===

    /// Handle initial Alt+Tab press
    pub fn handleAltTab(self: *Self, shift: bool) void {
        if (self.state == .switching) {
            if (shift) {
                self.selectPrev();
            } else {
                self.selectNext();
            }
            return;
        }

        if (!x11.grabKeyboard(self.conn.conn, self.conn.root)) {
            log.err("Could not grab keyboard, aborting Alt+Tab", .{});
            return;
        }

        self.reorderByStacking();

        if (shift) {
            if (self.items.items.len > 0) {
                self.selected_index = self.items.items.len - 1;
            }
        } else {
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
    pub fn handleKeyEvent(self: *Self, keysym: u32, is_press: bool) bool {
        if (self.state != .switching) {
            return false;
        }

        if (!is_press) {
            if (keysym == x11.XK_Alt_L or keysym == x11.XK_Alt_R) {
                self.confirmSwitching();
                return true;
            }
            return false;
        }

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

    /// Confirm switching
    pub fn confirmSwitching(self: *Self) void {
        if (self.state != .switching) return;

        if (self.items.items.len > 0 and self.selected_index < self.items.items.len) {
            const selected_id = self.items.items[self.selected_index].id;
            x11.activateWindow(self.conn.conn, self.conn.root, selected_id, self.conn.atoms);
            log.info("Confirmed: activating window {x}", .{selected_id});
        }

        x11.ungrabKeyboard(self.conn.conn);
        self.hideWindow();
        self.state = .idle;
    }

    /// Cancel switching
    pub fn cancelSwitching(self: *Self) void {
        if (self.state != .switching) return;

        log.info("Switching cancelled", .{});
        x11.ungrabKeyboard(self.conn.conn);
        self.hideWindow();
        self.state = .idle;
    }

    /// Handle damage event for a window (rebind GLX texture)
    pub fn handleDamageEvent(self: *Self, drawable: x11.xcb.xcb_window_t) void {
        if (self.window_textures.getPtr(drawable)) |tex| {
            if (!tex.rebind(self.conn)) {
                // Rebind failed — texture is stale, remove it
                log.warn("Removing stale GLX texture for window {x}", .{drawable});
                var t = self.window_textures.fetchRemove(drawable) orelse return;
                t.value.deinit(self.conn);
                return;
            }
            _ = x11.xcb.xcb_damage_subtract(self.conn.conn, tex.damage, 0, 0);
        }
    }

    /// Reorder internal items to match stacking order (reversed = MRU first)
    fn reorderByStacking(self: *Self) void {
        const stacking = x11.getStackingWindowList(self.allocator, self.conn.conn, self.conn.root, self.conn.atoms) catch |err| {
            log.warn("Could not get stacking list: {}", .{err});
            return;
        };
        defer self.allocator.free(stacking);

        if (stacking.len == 0) return;

        var new_items = std.ArrayList(ui.DisplayWindow).init(self.allocator);
        defer new_items.deinit();
        new_items.ensureTotalCapacity(self.items.items.len) catch return;

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

        self.items.clearRetainingCapacity();
        for (new_items.items) |item| {
            self.items.append(item) catch continue;
        }
    }

    // === Private methods ===

    fn render(self: *Self) void {
        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        ui.renderSwitcher(self.items.items, self.current_layout, self.selected_index, self.mouseover_index, self.font);
        rl.EndDrawing();
    }

    fn updateLayout(self: *Self) void {
        const prev_width = self.current_layout.total_width;
        const prev_height = self.current_layout.total_height;
        self.current_layout = ui.calculateBestLayout(self.items.items);

        if (!self.window_hidden and (self.current_layout.total_width != prev_width or self.current_layout.total_height != prev_height)) {
            rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
            const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
            const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
            rl.SetWindowPosition(win_x, win_y);
            log.debug("Window resized to {d}x{d}", .{ self.current_layout.total_width, self.current_layout.total_height });
        }
    }
};

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

    return MonitorInfo{
        .index = 0,
        .x = 0,
        .y = 0,
        .width = 1920,
        .height = 1080,
    };
}
