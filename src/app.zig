const std = @import("std");
const x11 = @import("x11.zig");
const ui = @import("ui.zig");
const worker = @import("worker.zig");
const thumbnail = @import("thumbnail.zig");
const nav = @import("navigation.zig");

const rl = ui.rl;
const log = std.log.scoped(.fasttab);

const PROFILE_SLOW_SHOW_WINDOW_US: i128 = 5_000;
const PROFILE_SLOW_HIDE_WINDOW_US: i128 = 5_000;
const PROFILE_SLOW_REACQUIRE_WINDOW_US: i128 = 4_000;
const PROFILE_SLOW_REACQUIRE_FRAME_US: i128 = 8_000;

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
    downsample_shader: ?ui.DownsampleShader,
    show_delay_frames: ?u8,
    reacquire_pending: bool,
    reacquire_cursor: usize,

    const Self = @This();

    /// Initialize the application with items from the worker
    pub fn init(
        allocator: std.mem.Allocator,
        task_queue: *worker.TaskQueue,
        daemon_mode: bool,
        conn: *x11.Connection,
    ) !Self {
        const items = std.ArrayList(ui.DisplayWindow).init(allocator);
        const icon_texture_cache = std.StringHashMap(rl.Texture2D).init(allocator);
        const window_textures = std.AutoHashMap(x11.xcb.xcb_window_t, x11.WindowTexture).init(allocator);
        const temp_tasks = std.ArrayList(worker.UpdateTask).init(allocator);

        // Create raylib window (hidden initially via FLAG_WINDOW_HIDDEN)
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST | rl.FLAG_WINDOW_HIDDEN);
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        rl.InitWindow(800, 600, "FastTab");
        rl.SetTargetFPS(60);
        const font = ui.loadSystemFont(ui.TITLE_FONT_SIZE);
        const downsample_shader = ui.DownsampleShader.load();

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
            .downsample_shader = downsample_shader,
            .show_delay_frames = null,
            .reacquire_pending = false,
            .reacquire_cursor = 0,
        };

        self.drainUpdateQueue();

        log.info("App initialized: {d} windows tracked", .{self.items.items.len});

        return self;
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        // Free owned fields from items (textures are cleaned up via window_textures)
        for (self.items.items) |*item| {
            // Don't unload thumbnail_texture here - it's owned by window_textures
            // Don't unload icon_texture here - it's shared via icon_texture_cache
            if (item.cached_snapshot) |snapshot| {
                rl.UnloadRenderTexture(snapshot);
            }
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

        // Unload downsample shader
        if (self.downsample_shader) |*shader| {
            shader.unload();
        }

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
            // Check if the deferred show countdown has elapsed
            if (self.show_delay_frames) |*remaining| {
                if (remaining.* == 0) {
                    self.show_delay_frames = null;
                    self.showWindow();
                    // Fall through to render the first frame immediately
                } else {
                    remaining.* -= 1;
                    std.time.sleep(16 * std.time.ns_per_ms);
                    return;
                }
            } else {
                // No show pending, sleep
                std.time.sleep(16 * std.time.ns_per_ms);
                return;
            }
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

        self.processReacquireQueue();

        // Render
        self.render();
    }

    pub fn drainUpdateQueue(self: *Self) void {
        const queue = self.update_queue orelse return;

        _ = queue.drainAll(&self.temp_tasks);
        if (self.temp_tasks.items.len == 0) return;

        var any_changes = false;

        for (self.temp_tasks.items) |*task| {
            any_changes = true;
            switch (task.*) {
                .window_added => |*data| {
                    var texture: rl.Texture2D = std.mem.zeroes(rl.Texture2D);
                    var source_width: u32 = 0;
                    var source_height: u32 = 0;
                    var has_texture = false;

                    // Attempt to create GLX texture (may fail for minimized windows, etc.)
                    if (!data.is_minimized) {
                        if (x11.createWindowTexture(self.conn, data.window_id)) |win_tex| {
                            texture = win_tex.toRaylibTexture();
                            source_width = win_tex.width;
                            source_height = win_tex.height;

                            self.window_textures.put(data.window_id, win_tex) catch {
                                var t = win_tex;
                                t.deinit(self.conn);
                                // Fall through — window still gets added without a texture
                            };

                            if (self.window_textures.contains(data.window_id)) {
                                has_texture = true;

                                // Release binding immediately if hidden so other compositors can use the pixmap
                                if (self.window_hidden) {
                                    if (self.window_textures.getPtr(data.window_id)) |stored_tex| {
                                        stored_tex.release(self.conn);
                                    }
                                }
                            }
                        } else |err| {
                            log.warn("GLX texture failed for {x}: {}, showing icon fallback", .{ data.window_id, err });
                        }
                    } else {
                        log.debug("Minimized window {x}, showing icon fallback", .{data.window_id});
                    }

                    // Look up icon
                    var icon_tex: ?rl.Texture2D = null;
                    if (self.icon_texture_cache.get(data.icon_id)) |tex| {
                        icon_tex = tex;
                    }

                    // Create display window (taking ownership of title and icon_id)
                    // Windows without a texture will render with the icon fallback (Tier 3)
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
                        .thumbnail_ready = has_texture and !self.window_hidden,
                        .cached_snapshot = null,
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
                            // Clean up WindowTexture
                            if (self.window_textures.fetchRemove(data.window_id)) |entry| {
                                var tex = entry.value;
                                tex.deinit(self.conn);
                            }
                            self.allocator.free(item.title);
                            self.allocator.free(item.icon_id);
                            _ = self.items.orderedRemove(i);
                            break;
                        }
                    }
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
        const start_ns = std.time.nanoTimestamp();

        // Notify worker that window is hidden
        if (self.update_queue) |queue| {
            queue.setWindowVisible(false);
        }
        const after_notify_ns = std.time.nanoTimestamp();

        rl.SetWindowState(rl.FLAG_WINDOW_HIDDEN);
        const after_hide_ns = std.time.nanoTimestamp();

        self.window_hidden = true;
        self.reacquire_pending = false;

        // Cache thumbnail snapshots before releasing GLX bindings
        self.cacheAllSnapshots();
        const after_snapshot_ns = std.time.nanoTimestamp();

        // Release GLX bindings so other compositors (KDE taskbar) can use the pixmaps
        self.releaseAllBindings();
        const after_release_ns = std.time.nanoTimestamp();

        const total_us = @divTrunc(after_release_ns - start_ns, std.time.ns_per_us);
        if (total_us >= PROFILE_SLOW_HIDE_WINDOW_US) {
            log.warn(
                "profile hideWindow(us): total={d} notify={d} hide={d} snapshot={d} release={d} windows={d}",
                .{
                    total_us,
                    @divTrunc(after_notify_ns - start_ns, std.time.ns_per_us),
                    @divTrunc(after_hide_ns - after_notify_ns, std.time.ns_per_us),
                    @divTrunc(after_snapshot_ns - after_hide_ns, std.time.ns_per_us),
                    @divTrunc(after_release_ns - after_snapshot_ns, std.time.ns_per_us),
                    self.window_textures.count(),
                },
            );
        } else {
            log.debug(
                "hideWindow(us): total={d} notify={d} hide={d} snapshot={d} release={d} windows={d}",
                .{
                    total_us,
                    @divTrunc(after_notify_ns - start_ns, std.time.ns_per_us),
                    @divTrunc(after_hide_ns - after_notify_ns, std.time.ns_per_us),
                    @divTrunc(after_snapshot_ns - after_hide_ns, std.time.ns_per_us),
                    @divTrunc(after_release_ns - after_snapshot_ns, std.time.ns_per_us),
                    self.window_textures.count(),
                },
            );
        }
    }

    /// Show the switcher window (public for socket commands)
    pub fn showWindow(self: *Self) void {
        const start_ns = std.time.nanoTimestamp();
        log.debug("Showing window with {d} items", .{self.items.items.len});

        // Notify worker that window is visible
        if (self.update_queue) |queue| {
            queue.setWindowVisible(true);
        }
        const after_notify_ns = std.time.nanoTimestamp();

        // Recalculate layout
        self.current_layout = ui.calculateBestLayout(self.items.items);
        const after_layout_ns = std.time.nanoTimestamp();

        // Query current mouse position and find monitor
        const mouse_pos = x11.getMousePosition(self.conn.conn, self.conn.root);
        self.monitor = findMonitorAtPosition(mouse_pos);
        const after_monitor_ns = std.time.nanoTimestamp();

        rl.ClearWindowState(rl.FLAG_WINDOW_HIDDEN);
        const after_map_ns = std.time.nanoTimestamp();

        // Set size after showing - SetWindowSize on a hidden window may not take effect
        rl.SetWindowSize(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height));
        const after_size_ns = std.time.nanoTimestamp();

        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);
        const after_position_ns = std.time.nanoTimestamp();

        rl.SetWindowFocused();
        const after_focus_ns = std.time.nanoTimestamp();

        self.focus_grace_frames = 5;
        self.window_hidden = false;

        self.reacquire_pending = self.hasPendingReacquire();
        self.reacquire_cursor = if (self.items.items.len > 0) self.selected_index % self.items.items.len else 0;

        const total_us = @divTrunc(after_focus_ns - start_ns, std.time.ns_per_us);
        if (total_us >= PROFILE_SLOW_SHOW_WINDOW_US) {
            log.info(
                "profile showWindow(us): total={d} notify={d} layout={d} monitor={d} map={d} size={d} position={d} focus={d}",
                .{
                    total_us,
                    @divTrunc(after_notify_ns - start_ns, std.time.ns_per_us),
                    @divTrunc(after_layout_ns - after_notify_ns, std.time.ns_per_us),
                    @divTrunc(after_monitor_ns - after_layout_ns, std.time.ns_per_us),
                    @divTrunc(after_map_ns - after_monitor_ns, std.time.ns_per_us),
                    @divTrunc(after_size_ns - after_map_ns, std.time.ns_per_us),
                    @divTrunc(after_position_ns - after_size_ns, std.time.ns_per_us),
                    @divTrunc(after_focus_ns - after_position_ns, std.time.ns_per_us),
                },
            );
        }
    }

    /// Number of frames to wait before showing the switcher window.
    /// If Alt is released before this, the window is never shown.
    const SHOW_DELAY_FRAMES: u8 = 1;

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

        // Don't show the window yet — wait a couple of frames.  If Alt is
        // released before the countdown expires we switch without ever
        // mapping the window, avoiding the show/hide race during rapid Alt+Tab.
        self.show_delay_frames = SHOW_DELAY_FRAMES;
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

        const start_ns = std.time.nanoTimestamp();

        if (self.items.items.len > 0 and self.selected_index < self.items.items.len) {
            const selected_id = self.items.items[self.selected_index].id;
            x11.activateWindow(self.conn.conn, self.conn.root, selected_id, self.conn.atoms);
            log.info("Confirmed: activating window {x}", .{selected_id});
        }
        const after_activate_ns = std.time.nanoTimestamp();

        x11.ungrabKeyboard(self.conn.conn);
        const after_ungrab_ns = std.time.nanoTimestamp();

        self.show_delay_frames = null;
        if (!self.window_hidden) {
            self.hideWindow();
        }
        const after_hide_ns = std.time.nanoTimestamp();

        self.state = .idle;

        log.info(
            "profile confirmSwitching(us): total={d} activate={d} ungrab={d} hide={d}",
            .{
                @divTrunc(after_hide_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_activate_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_ungrab_ns - after_activate_ns, std.time.ns_per_us),
                @divTrunc(after_hide_ns - after_ungrab_ns, std.time.ns_per_us),
            },
        );
    }

    /// Cancel switching
    pub fn cancelSwitching(self: *Self) void {
        if (self.state != .switching) return;

        const start_ns = std.time.nanoTimestamp();
        log.info("Switching cancelled", .{});
        x11.ungrabKeyboard(self.conn.conn);
        const after_ungrab_ns = std.time.nanoTimestamp();

        self.show_delay_frames = null;
        if (!self.window_hidden) {
            self.hideWindow();
        }
        const after_hide_ns = std.time.nanoTimestamp();

        self.state = .idle;

        log.info(
            "profile cancelSwitching(us): total={d} ungrab={d} hide={d}",
            .{
                @divTrunc(after_hide_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_ungrab_ns - start_ns, std.time.ns_per_us),
                @divTrunc(after_hide_ns - after_ungrab_ns, std.time.ns_per_us),
            },
        );
    }

    /// Handle damage event for a window (rebind GLX texture)
    pub fn handleDamageEvent(self: *Self, drawable: x11.xcb.xcb_window_t) void {
        if (self.window_textures.getPtr(drawable)) |tex| {
            // Always acknowledge the damage to prevent event queue buildup
            _ = x11.xcb.xcb_damage_subtract(self.conn.conn, tex.damage, 0, 0);

            // Skip rebind when hidden — bindings are released
            if (self.window_hidden) return;

            if (!tex.rebind(self.conn)) {
                // Rebind failed — pixmap is stale, try to reacquire a fresh one
                log.info("GLX rebind failed for window {x}, reacquiring pixmap", .{drawable});
                tex.invalidate(self.conn);
                if (!tex.reacquire(self.conn)) {
                    // Window is truly gone — destroy texture and remove from items
                    log.warn("Reacquire also failed for window {x}, removing", .{drawable});
                    var t = self.window_textures.fetchRemove(drawable) orelse return;
                    t.value.deinit(self.conn);
                    self.removeItemByWindowId(drawable);
                    if (self.update_queue) |q| q.reportDropped(drawable);
                    self.reacquire_pending = self.hasPendingReacquire();
                    self.reacquire_cursor = if (self.items.items.len > 0) self.reacquire_cursor % self.items.items.len else 0;
                    self.updateLayout();
                    return;
                }
                self.markThumbnailReady(drawable, true);
                if (self.findItemByWindowId(drawable)) |item| {
                    item.thumbnail_texture = tex.toRaylibTexture();
                    // Update dimensions in case the window was resized
                    if (item.source_width != tex.width or item.source_height != tex.height) {
                        item.source_width = tex.width;
                        item.source_height = tex.height;
                        self.updateLayout();
                    }
                }
                return;
            }

            self.markThumbnailReady(drawable, true);
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

    /// Release all GLX texture bindings (frees pixmaps for other compositors)
    fn releaseAllBindings(self: *Self) void {
        var iter = self.window_textures.valueIterator();
        while (iter.next()) |tex| {
            tex.release(self.conn);
        }
        for (self.items.items) |*item| {
            item.thumbnail_ready = false;
        }
        log.debug("Released {d} GLX bindings", .{self.window_textures.count()});
    }

    /// Cache snapshots of all live thumbnails into RenderTextures before releasing GLX bindings.
    /// Uses the downsample shader to render each live GLX texture into a per-window FBO at display size.
    fn cacheAllSnapshots(self: *Self) void {
        var cached_count: usize = 0;
        for (self.items.items) |*item| {
            if (!item.thumbnail_ready) continue;
            if (item.display_width == 0 or item.display_height == 0) continue;

            // Free any previous cached snapshot
            if (item.cached_snapshot) |prev| {
                rl.UnloadRenderTexture(prev);
                item.cached_snapshot = null;
            }

            const rt = rl.LoadRenderTexture(@intCast(item.display_width), @intCast(item.display_height));
            if (rt.id == 0) continue; // FBO creation failed

            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.thumbnail_texture.width),
                .height = @floatFromInt(item.thumbnail_texture.height),
            };
            const dest_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.display_width),
                .height = @floatFromInt(item.display_height),
            };

            rl.BeginTextureMode(rt);
            rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });

            if (self.downsample_shader) |*shader| {
                shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
                rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                shader.end();
            } else {
                rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            }

            rl.EndTextureMode();

            item.cached_snapshot = rt;
            cached_count += 1;
        }
        if (cached_count > 0) {
            log.debug("Cached {d} thumbnail snapshots", .{cached_count});
        }
    }

    const REACQUIRE_FRAME_BUDGET_NS: i128 = 10 * std.time.ns_per_ms;

    /// Incrementally reacquire GLX textures during update() to avoid blocking showWindow.
    fn processReacquireQueue(self: *Self) void {
        if (!self.reacquire_pending) return;
        if (self.window_hidden) {
            self.reacquire_pending = false;
            return;
        }

        const start_ns = std.time.nanoTimestamp();
        var layout_dirty = false;
        var reacquired_count: usize = 0;
        var failed_count: usize = 0;
        var max_window_us: i128 = 0;
        var max_window_id: x11.xcb.xcb_window_t = 0;
        var to_remove = std.ArrayList(x11.xcb.xcb_window_t).init(self.allocator);
        defer to_remove.deinit();

        while (std.time.nanoTimestamp() - start_ns < REACQUIRE_FRAME_BUDGET_NS) {
            const target_id = self.nextPendingReacquireWindowId() orelse break;
            const window_start_ns = std.time.nanoTimestamp();

            if (self.window_textures.getPtr(target_id)) |tex| {
                if (!tex.reacquire(self.conn)) {
                    to_remove.append(target_id) catch continue;
                    self.markThumbnailReady(target_id, true);
                    failed_count += 1;
                    continue;
                }

                const window_us = @divTrunc(std.time.nanoTimestamp() - window_start_ns, std.time.ns_per_us);
                if (window_us > max_window_us) {
                    max_window_us = window_us;
                    max_window_id = target_id;
                }
                if (window_us >= PROFILE_SLOW_REACQUIRE_WINDOW_US) {
                    log.debug("profile reacquire window: id={x} duration_us={d}", .{ target_id, window_us });
                }
                reacquired_count += 1;

                const new_w = tex.width;
                const new_h = tex.height;
                self.markThumbnailReady(target_id, true);
                if (self.findItemByWindowId(target_id)) |item| {
                    item.thumbnail_texture = tex.toRaylibTexture();
                    // Free cached snapshot now that live texture is available
                    if (item.cached_snapshot) |snapshot| {
                        rl.UnloadRenderTexture(snapshot);
                        item.cached_snapshot = null;
                    }
                    if (item.source_width != new_w or item.source_height != new_h) {
                        item.source_width = new_w;
                        item.source_height = new_h;
                        layout_dirty = true;
                    }
                }
            } else {
                // No texture yet (minimized or initial creation failed) — try to create one
                const win_tex = x11.createWindowTexture(self.conn, target_id) catch {
                    failed_count += 1;
                    // Leave thumbnail_ready = false; will retry on next show
                    continue;
                };

                self.window_textures.put(target_id, win_tex) catch {
                    var t = win_tex;
                    t.deinit(self.conn);
                    failed_count += 1;
                    continue;
                };

                const window_us = @divTrunc(std.time.nanoTimestamp() - window_start_ns, std.time.ns_per_us);
                if (window_us > max_window_us) {
                    max_window_us = window_us;
                    max_window_id = target_id;
                }
                if (window_us >= PROFILE_SLOW_REACQUIRE_WINDOW_US) {
                    log.debug("profile acquire new texture: id={x} duration_us={d}", .{ target_id, window_us });
                }
                reacquired_count += 1;

                self.markThumbnailReady(target_id, true);
                if (self.findItemByWindowId(target_id)) |item| {
                    // Update from the now-stored texture pointer
                    if (self.window_textures.getPtr(target_id)) |stored_tex| {
                        item.thumbnail_texture = stored_tex.toRaylibTexture();
                    }
                    if (item.source_width != win_tex.width or item.source_height != win_tex.height) {
                        item.source_width = win_tex.width;
                        item.source_height = win_tex.height;
                        layout_dirty = true;
                    }
                }
            }
        }

        for (to_remove.items) |wid| {
            log.warn("Removing stale GLX texture for window {x} during progressive reacquire", .{wid});
            if (self.window_textures.fetchRemove(wid)) |entry| {
                var t = entry.value;
                t.deinit(self.conn);
            }
            self.removeItemByWindowId(wid);
            if (self.update_queue) |q| q.reportDropped(wid);
            layout_dirty = true;
        }

        if (layout_dirty) {
            self.updateLayout();
        }

        self.reacquire_pending = self.hasPendingReacquire();

        const frame_us = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_us);
        if (frame_us >= PROFILE_SLOW_REACQUIRE_FRAME_US or failed_count > 0) {
            log.info(
                "profile reacquire frame(us): total={d} reacquired={d} failed={d} max_window={d} max_window_id={x} pending={}",
                .{ frame_us, reacquired_count, failed_count, max_window_us, max_window_id, self.reacquire_pending },
            );
        }
    }

    fn hasPendingReacquire(self: *Self) bool {
        for (self.items.items) |item| {
            if (!item.thumbnail_ready) {
                if (self.window_textures.getPtr(item.id)) |tex| {
                    if (!tex.bound) {
                        return true;
                    }
                } else {
                    // No texture at all (minimized or initial creation failed) — needs acquire
                    return true;
                }
            }
        }
        return false;
    }

    fn nextPendingReacquireWindowId(self: *Self) ?x11.xcb.xcb_window_t {
        if (self.items.items.len == 0) return null;

        if (self.selected_index < self.items.items.len) {
            const selected = self.items.items[self.selected_index];
            if (!selected.thumbnail_ready) {
                if (self.window_textures.getPtr(selected.id)) |tex| {
                    if (!tex.bound) {
                        return selected.id;
                    }
                } else {
                    return selected.id;
                }
            }
        }

        const start = self.reacquire_cursor % self.items.items.len;
        var offset: usize = 0;
        while (offset < self.items.items.len) : (offset += 1) {
            const idx = (start + offset) % self.items.items.len;
            const item = self.items.items[idx];
            if (item.thumbnail_ready) continue;

            if (self.window_textures.getPtr(item.id)) |tex| {
                if (!tex.bound) {
                    self.reacquire_cursor = (idx + 1) % self.items.items.len;
                    return item.id;
                }
            } else {
                self.reacquire_cursor = (idx + 1) % self.items.items.len;
                return item.id;
            }
        }

        return null;
    }

    fn findItemByWindowId(self: *Self, wid: x11.xcb.xcb_window_t) ?*ui.DisplayWindow {
        for (self.items.items) |*item| {
            if (item.id == wid) {
                return item;
            }
        }
        return null;
    }

    fn markThumbnailReady(self: *Self, wid: x11.xcb.xcb_window_t, ready: bool) void {
        if (self.findItemByWindowId(wid)) |item| {
            item.thumbnail_ready = ready;
        }
    }

    /// Remove a DisplayWindow from self.items by window ID, freeing owned strings.
    fn removeItemByWindowId(self: *Self, wid: x11.xcb.xcb_window_t) void {
        for (self.items.items, 0..) |*item, i| {
            if (item.id == wid) {
                if (item.cached_snapshot) |snapshot| {
                    rl.UnloadRenderTexture(snapshot);
                }
                self.allocator.free(item.title);
                self.allocator.free(item.icon_id);
                _ = self.items.orderedRemove(i);
                return;
            }
        }
    }

    fn render(self: *Self) void {
        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        const shader_ptr: ?*const ui.DownsampleShader = if (self.downsample_shader) |*s| s else null;
        ui.renderSwitcher(self.items.items, self.current_layout, self.selected_index, self.mouseover_index, self.font, shader_ptr);
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
