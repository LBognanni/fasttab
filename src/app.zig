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
    window_close_time: ?i64,
    daemon_mode: bool,
    should_quit: bool,
    update_queue: ?*worker.UpdateQueue,

    const Self = @This();

    /// Initialize the application with items from the worker
    pub fn init(
        allocator: std.mem.Allocator,
        initial_result: *worker.RefreshResult,
        mouse_pos: x11.MousePosition,
        daemon_mode: bool,
        update_queue: ?*worker.UpdateQueue,
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
                .display_width = 0,
                .display_height = 0,
            });

            // Transfer ownership - prevent deinit from freeing
            upd.thumbnail_data = &[_]u8{};
            upd.title = "(unknown)";
        }

        // Calculate initial layout
        const layout = ui.calculateGridLayout(items.items, ui.THUMBNAIL_HEIGHT);

        // Initialize raylib window
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        rl.InitWindow(@intCast(layout.total_width), @intCast(layout.total_height), "FastTab");
        rl.SetTargetFPS(60);

        // Load system font
        const font = ui.loadSystemFont(ui.TITLE_FONT_SIZE * 2);

        // Load textures from thumbnails
        for (items.items) |*item| {
            item.texture = ui.loadTextureFromThumbnail(&item.thumbnail);
        }

        // Find monitor containing mouse cursor
        const monitor = findMonitorAtPosition(mouse_pos);

        // Center window on the target monitor
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
            .window_close_time = null,
            .daemon_mode = daemon_mode,
            .should_quit = false,
            .update_queue = update_queue,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        // Unload resources (only if window is still open)
        if (!self.window_hidden) {
            for (self.items.items) |*item| {
                rl.UnloadTexture(item.texture);
            }
            rl.UnloadFont(self.font);
            rl.CloseWindow();
        }

        // Free item data
        for (self.items.items) |*item| {
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                self.allocator.free(item.title);
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

    /// Process one frame: handle input, check for window close, render
    pub fn update(self: *Self) void {
        // Check if window should close
        if (!self.window_hidden) {
            if (rl.WindowShouldClose() or (self.items.items.len > 0 and rl.IsKeyPressed(rl.KEY_ESCAPE))) {
                if (self.daemon_mode) {
                    self.hideWindow();
                } else {
                    self.should_quit = true;
                    return;
                }
            }
        }

        // In daemon mode, reopen window after delay
        if (self.daemon_mode and self.window_hidden) {
            if (self.window_close_time) |close_time| {
                const elapsed = std.time.milliTimestamp() - close_time;
                if (elapsed >= 4000) {
                    self.showWindow();
                }
            }
        }

        // Handle keyboard input (only when window is visible)
        if (!self.window_hidden and self.items.items.len > 0) {
            self.handleKeyboardInput();
        }

        // Render or sleep
        if (!self.window_hidden) {
            self.render();
        } else {
            // In daemon mode with hidden window, sleep briefly to avoid busy loop
            std.time.sleep(16 * std.time.ns_per_ms);
        }
    }

    /// Process an update from the background worker
    pub fn processWorkerUpdate(self: *Self, update_result: *worker.RefreshResult) void {
        if (self.window_hidden) {
            log.debug("Processing update while hidden: {d} current windows, {d} updates", .{
                update_result.current_window_ids.items.len,
                update_result.updates.items.len,
            });
        }

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

    // === Private methods ===

    fn hideWindow(self: *Self) void {
        log.debug("Hiding window", .{});

        // Notify worker that window is hidden (optimize captures)
        if (self.update_queue) |queue| {
            queue.setWindowVisible(false);
        }

        // Unload all textures before closing window
        for (self.items.items) |*item| {
            rl.UnloadTexture(item.texture);
            item.texture = rl.Texture2D{};
        }
        rl.UnloadFont(self.font);
        rl.CloseWindow();

        self.window_hidden = true;
        self.window_close_time = std.time.milliTimestamp();
    }

    fn showWindow(self: *Self) void {
        log.debug("Showing window with {d} items", .{self.items.items.len});

        // Notify worker that window is visible (capture all windows)
        if (self.update_queue) |queue| {
            queue.setWindowVisible(true);
        }

        // Recalculate layout in case windows changed
        self.current_layout = ui.calculateGridLayout(self.items.items, ui.THUMBNAIL_HEIGHT);

        // Reinitialize raylib window
        rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        rl.InitWindow(@intCast(self.current_layout.total_width), @intCast(self.current_layout.total_height), "FastTab");
        rl.SetTargetFPS(60);

        // Reload font
        self.font = ui.loadSystemFont(ui.TITLE_FONT_SIZE * 2);

        // Reload textures for all items
        for (self.items.items) |*item| {
            if (item.thumbnail.data.len > 0) {
                item.texture = ui.loadTextureFromThumbnail(&item.thumbnail);
            } else {
                item.texture = rl.Texture2D{};
            }
        }

        // Center window on monitor
        const win_x = self.monitor.x + @divTrunc(self.monitor.width - @as(i32, @intCast(self.current_layout.total_width)), 2);
        const win_y = self.monitor.y + @divTrunc(self.monitor.height - @as(i32, @intCast(self.current_layout.total_height)), 2);
        rl.SetWindowPosition(win_x, win_y);

        self.window_hidden = false;
        self.window_close_time = null;
    }

    fn handleKeyboardInput(self: *Self) void {
        const count = self.items.items.len;
        const cols = self.current_layout.columns;

        if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_TAB)) {
            self.selected_index = nav.moveSelectionRight(self.selected_index, count);
        }
        if (rl.IsKeyPressed(rl.KEY_LEFT)) {
            self.selected_index = nav.moveSelectionLeft(self.selected_index, count);
        }
        if (rl.IsKeyPressed(rl.KEY_DOWN)) {
            self.selected_index = nav.moveSelectionDown(self.selected_index, cols, count);
        }
        if (rl.IsKeyPressed(rl.KEY_UP)) {
            self.selected_index = nav.moveSelectionUp(self.selected_index, cols);
        }
    }

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
                if (self.window_hidden) {
                    log.debug("Will remove window {d}: {s}", .{ item.id, item.title });
                }
            }
        }

        // Remove in reverse order to maintain indices
        var remove_idx: usize = to_remove.items.len;
        while (remove_idx > 0) {
            remove_idx -= 1;
            const idx = to_remove.items[remove_idx];
            const item = &self.items.items[idx];

            if (!self.window_hidden) {
                rl.UnloadTexture(item.texture);
            }
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                self.allocator.free(item.title);
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

        // Update thumbnail data
        item.thumbnail.deinit();
        item.thumbnail = new_thumb;

        // Only update texture if window is visible
        if (!self.window_hidden) {
            const new_texture = ui.loadTextureFromThumbnail(&new_thumb);
            rl.UnloadTexture(item.texture);
            item.texture = new_texture;
        }

        // Transfer ownership
        upd.thumbnail_data = &[_]u8{};
    }

    fn addNewWindow(self: *Self, upd: *worker.ThumbnailUpdate) void {
        const new_thumb = thumbnail.Thumbnail{
            .data = upd.thumbnail_data,
            .width = upd.thumbnail_width,
            .height = upd.thumbnail_height,
            .allocator = upd.allocator,
        };

        // Only create texture if window is visible
        const texture = if (!self.window_hidden)
            ui.loadTextureFromThumbnail(&new_thumb)
        else
            rl.Texture2D{};

        const new_item = ui.WindowItem{
            .id = upd.window_id,
            .title = upd.title,
            .thumbnail = new_thumb,
            .texture = texture,
            .display_width = 0,
            .display_height = 0,
        };

        self.items.append(new_item) catch {
            if (!self.window_hidden) rl.UnloadTexture(texture);
            return;
        };

        if (self.window_hidden) {
            log.debug("Added new window {d}: {s} (hidden)", .{ new_item.id, new_item.title });
        } else {
            log.debug("Added new window {d}: {s}", .{ new_item.id, new_item.title });
        }

        // Transfer ownership
        upd.thumbnail_data = &[_]u8{};
        upd.title = "(unknown)";
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
