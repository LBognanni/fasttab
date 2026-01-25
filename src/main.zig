const std = @import("std");
const x11 = @import("x11.zig");
const thumbnail = @import("thumbnail.zig");
const ui = @import("ui.zig");
const worker = @import("worker.zig");

const rl = ui.rl;
const log = std.log.scoped(.fasttab);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Parse command-line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var daemon_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--daemon") or std.mem.eql(u8, arg, "daemon")) {
            daemon_mode = true;
        }
    }

    if (daemon_mode) {
        try stdout.print("Starting in daemon mode...\n", .{});
    }

    // Connect to X11
    var conn = try x11.Connection.init();
    defer conn.deinit();

    // Register for PropertyNotify events on root window
    const event_mask = [_]u32{x11.xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
    _ = x11.xcb.xcb_change_window_attributes(conn.conn, conn.root, x11.xcb.XCB_CW_EVENT_MASK, &event_mask);
    conn.flush();

    // Get window list
    const windows = try x11.getWindowList(conn.conn, conn.root, conn.atoms);

    if (windows.len == 0) {
        try stdout.print("No windows found.\n", .{});
        return;
    }

    // === PHASE 1: Capture raw images from X11 ===
    var raw_captures = std.ArrayList(x11.RawCapture).init(allocator);
    defer {
        for (raw_captures.items) |*cap| {
            cap.deinit();
        }
        raw_captures.deinit();
    }

    try stdout.print("Scanning {d} windows...\n", .{windows.len});

    for (windows) |window_id| {
        if (!x11.shouldShowWindow(conn.conn, window_id, conn.atoms)) {
            continue;
        }

        // Filter by current desktop if enabled
        if (!x11.isWindowOnCurrentDesktop(conn.conn, window_id, conn.root, conn.atoms)) {
            continue;
        }

        const title = x11.getWindowTitle(allocator, conn.conn, window_id, conn.atoms);

        var raw_capture = x11.captureRawImage(allocator, conn.conn, window_id, title) catch |err| {
            log.warn("Failed to capture window {d}: {}", .{ window_id, err });
            if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
            continue;
        };
        errdefer raw_capture.deinit();

        try raw_captures.append(raw_capture);
    }

    if (raw_captures.items.len == 0) {
        try stdout.print("No windows could be captured.\n", .{});
        return;
    }

    try stdout.print("Captured {d} raw images, processing with SIMD...\n", .{raw_captures.items.len});

    // === PHASE 2: Process raw captures in parallel ===
    var items = std.ArrayList(ui.WindowItem).init(allocator);
    defer {
        for (items.items) |*item| {
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                allocator.free(item.title);
            }
        }
        items.deinit();
    }

    try items.ensureTotalCapacity(raw_captures.items.len);

    const ProcessResult = struct {
        thumb: ?thumbnail.Thumbnail,
        capture_idx: usize,
    };

    var results = try allocator.alloc(ProcessResult, raw_captures.items.len);
    defer allocator.free(results);

    for (results, 0..) |*r, idx| {
        r.* = .{ .thumb = null, .capture_idx = idx };
    }

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const thread_count: u32 = @intCast(@max(1, @min(cpu_count, raw_captures.items.len)));

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = thread_count,
    });

    for (raw_captures.items, 0..) |*capture, idx| {
        try pool.spawn(struct {
            fn work(cap: *const x11.RawCapture, res: *ProcessResult, alloc: std.mem.Allocator) void {
                res.thumb = thumbnail.processRawCapture(cap, alloc) catch null;
            }
        }.work, .{ capture, &results[idx], allocator });
    }

    pool.deinit();

    for (results, 0..) |result, idx| {
        if (result.thumb) |thumb| {
            const capture = &raw_captures.items[idx];
            try stdout.print("  Processed: {s} ({d}x{d})\n", .{ capture.title, thumb.width, thumb.height });

            const title_copy = if (std.mem.eql(u8, capture.title, "(unknown)"))
                capture.title
            else
                try allocator.dupe(u8, capture.title);

            items.appendAssumeCapacity(ui.WindowItem{
                .id = capture.window_id,
                .title = title_copy,
                .thumbnail = thumb,
                .texture = undefined,
                .display_width = 0,
                .display_height = 0,
            });
        } else {
            log.warn("Failed to process window {d}", .{raw_captures.items[idx].window_id});
        }
    }

    if (items.items.len == 0) {
        try stdout.print("No windows could be captured.\n", .{});
        return;
    }

    // Calculate initial layout
    const layout = ui.calculateGridLayout(items.items, ui.THUMBNAIL_HEIGHT);

    try stdout.print("Grid layout: {d} cols x {d} rows, window size: {d}x{d}\n", .{
        layout.columns,
        layout.rows,
        layout.total_width,
        layout.total_height,
    });

    // Get mouse position BEFORE initializing raylib
    const mouse_pos = x11.getMousePosition(conn.conn, conn.root);

    // Create update queue and start background worker BEFORE raylib initialization
    var update_queue = worker.UpdateQueue{};
    // We'll set our window ID after creating the window

    const worker_thread = std.Thread.spawn(.{}, worker.backgroundWorker, .{ &update_queue, allocator }) catch |err| {
        log.err("Failed to spawn background worker: {}", .{err});
        return err;
    };

    // In daemon mode, wait 2 seconds to demonstrate background thumbnailing
    if (daemon_mode) {
        try stdout.print("Daemon mode: background worker running, waiting 2 seconds before showing window...\n", .{});
        std.time.sleep(2 * std.time.ns_per_s);
        try stdout.print("Initializing window...\n", .{});
    }

    // Save window list before creating raylib window
    const windows_before_raylib = try x11.getWindowList(conn.conn, conn.root, conn.atoms);
    var pre_raylib_windows = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
    defer pre_raylib_windows.deinit();
    for (windows_before_raylib) |wid| {
        try pre_raylib_windows.put(wid, {});
    }

    // Initialize raylib
    rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(@intCast(layout.total_width), @intCast(layout.total_height), "FastTab");
    rl.SetTargetFPS(60);

    // Find our own window ID
    conn.flush();
    std.time.sleep(50 * std.time.ns_per_ms);
    const windows_after_raylib = x11.getWindowList(conn.conn, conn.root, conn.atoms) catch &[_]x11.xcb.xcb_window_t{};
    var our_window_id: x11.xcb.xcb_window_t = 0;
    for (windows_after_raylib) |wid| {
        if (!pre_raylib_windows.contains(wid)) {
            our_window_id = wid;
            log.info("Detected our window ID: {d}", .{our_window_id});
            break;
        }
    }

    // Now set our window ID in the update queue
    update_queue.setOurWindowId(our_window_id);

    // Load system font
    var font = ui.loadSystemFont(ui.TITLE_FONT_SIZE * 2);

    // Load textures from thumbnails
    for (items.items) |*item| {
        item.texture = ui.loadTextureFromThumbnail(&item.thumbnail);
    }

    // Find monitor containing mouse cursor
    const monitor_count = rl.GetMonitorCount();
    var target_monitor: i32 = 0;
    var mon_x: i32 = 0;
    var mon_y: i32 = 0;
    var mon_width: i32 = 1920;
    var mon_height: i32 = 1080;

    var m: i32 = 0;
    while (m < monitor_count) : (m += 1) {
        const mx = rl.GetMonitorPosition(m).x;
        const my = rl.GetMonitorPosition(m).y;
        const mw = rl.GetMonitorWidth(m);
        const mh = rl.GetMonitorHeight(m);

        if (mouse_pos.x >= @as(i32, @intFromFloat(mx)) and
            mouse_pos.x < @as(i32, @intFromFloat(mx)) + mw and
            mouse_pos.y >= @as(i32, @intFromFloat(my)) and
            mouse_pos.y < @as(i32, @intFromFloat(my)) + mh)
        {
            target_monitor = m;
            mon_x = @intFromFloat(mx);
            mon_y = @intFromFloat(my);
            mon_width = mw;
            mon_height = mh;
            break;
        }
    }

    // Center window on the target monitor
    const win_x = mon_x + @divTrunc(mon_width - @as(i32, @intCast(layout.total_width)), 2);
    const win_y = mon_y + @divTrunc(mon_height - @as(i32, @intCast(layout.total_height)), 2);
    rl.SetWindowPosition(win_x, win_y);

    try stdout.print("Mouse at ({d}, {d}), using monitor {d}\n", .{ mouse_pos.x, mouse_pos.y, target_monitor });
    if (daemon_mode) {
        try stdout.print("Displaying {d} windows in switcher (daemon mode - closing window will keep process running).\n", .{items.items.len});
    } else {
        try stdout.print("Displaying {d} windows in switcher. Press ESC or close window to exit.\n", .{items.items.len});
    }

    var selected_index: usize = 0;
    var current_layout = layout;
    var window_hidden = false;
    var window_close_time: ?i64 = null;

    // Main render loop
    // In daemon mode, continue running even if window is closed
    while (true) {
        // Check if window should close (only call raylib functions when window is open)
        if (!window_hidden and (rl.WindowShouldClose() or (items.items.len > 0 and rl.IsKeyPressed(rl.KEY_ESCAPE)))) {
            if (daemon_mode) {
                // In daemon mode, close the window but keep running
                try stdout.print("Window closed but daemon continues running. Will reopen in 4 seconds...\n", .{});

                // Unload all textures before closing window
                for (items.items) |*item| {
                    rl.UnloadTexture(item.texture);
                    item.texture = rl.Texture2D{}; // Set to empty/invalid texture
                }
                rl.UnloadFont(font);

                rl.CloseWindow();
                window_hidden = true;
                window_close_time = std.time.milliTimestamp();
            } else {
                // In normal mode, exit the loop
                break;
            }
        }

        // In daemon mode, reopen window after 4 seconds
        if (daemon_mode and window_hidden) {
            if (window_close_time) |close_time| {
                const elapsed = std.time.milliTimestamp() - close_time;
                if (elapsed >= 4000) {
                    try stdout.print("Reopening window...\n", .{});

                    // Recalculate layout in case windows changed
                    current_layout = ui.calculateGridLayout(items.items, ui.THUMBNAIL_HEIGHT);

                    // Reinitialize raylib window
                    rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
                    rl.SetTraceLogLevel(rl.LOG_WARNING);
                    rl.InitWindow(@intCast(current_layout.total_width), @intCast(current_layout.total_height), "FastTab");
                    rl.SetTargetFPS(60);

                    // Reload font
                    font = ui.loadSystemFont(ui.TITLE_FONT_SIZE * 2);

                    // Reload textures for all items (they were unloaded when window closed)
                    try stdout.print("Reopening window with {d} items\n", .{items.items.len});
                    log.debug("Reloading textures for {d} windows", .{items.items.len});
                    for (items.items) |*item| {
                        // Only load texture if we have valid thumbnail data
                        // (minimized windows might not have been captured)
                        if (item.thumbnail.data.len > 0) {
                            item.texture = ui.loadTextureFromThumbnail(&item.thumbnail);
                            log.debug("  Loaded texture for window {d}: {s} (data len: {d})", .{ item.id, item.title, item.thumbnail.data.len });
                        } else {
                            item.texture = rl.Texture2D{};
                            log.debug("  Skipped texture for window {d}: {s} (NO thumbnail data)", .{ item.id, item.title });
                        }
                    }

                    // Center window on monitor
                    const new_win_x = mon_x + @divTrunc(mon_width - @as(i32, @intCast(current_layout.total_width)), 2);
                    const new_win_y = mon_y + @divTrunc(mon_height - @as(i32, @intCast(current_layout.total_height)), 2);
                    rl.SetWindowPosition(new_win_x, new_win_y);

                    window_hidden = false;
                    window_close_time = null;
                    try stdout.print("Window reopened with {d} windows.\n", .{items.items.len});
                }
            }
        }
        // Poll update queue from background worker
        if (update_queue.pop()) |*update_result| {
            defer @constCast(update_result).deinit();

            if (window_hidden) {
                log.debug("Processing update while hidden: {d} current windows, {d} updates", .{
                    update_result.current_window_ids.items.len,
                    update_result.updates.items.len,
                });
            }

            var current_window_set = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
            defer current_window_set.deinit();
            for (update_result.current_window_ids.items) |wid| {
                current_window_set.put(wid, {}) catch {};
            }

            var update_map = std.AutoHashMap(x11.xcb.xcb_window_t, *worker.ThumbnailUpdate).init(allocator);
            defer update_map.deinit();
            for (update_result.updates.items) |*update| {
                update_map.put(update.window_id, update) catch {};
            }

            // Find windows to remove
            var to_remove = std.ArrayList(usize).init(allocator);
            defer to_remove.deinit();
            for (items.items, 0..) |item, idx| {
                if (!current_window_set.contains(item.id)) {
                    to_remove.append(idx) catch {};
                    if (window_hidden) {
                        log.debug("Will remove window {d}: {s} (not in current set)", .{ item.id, item.title });
                    }
                }
            }

            // Remove closed windows
            var remove_idx: usize = to_remove.items.len;
            while (remove_idx > 0) {
                remove_idx -= 1;
                const idx = to_remove.items[remove_idx];
                const item = &items.items[idx];
                if (!window_hidden) rl.UnloadTexture(item.texture);
                item.thumbnail.deinit();
                if (!std.mem.eql(u8, item.title, "(unknown)")) {
                    allocator.free(item.title);
                }
                _ = items.orderedRemove(idx);
                log.debug("Removed window at index {d}", .{idx});
            }

            // Process updates for existing and new windows
            for (update_result.updates.items) |*update| {
                var found_idx: ?usize = null;
                for (items.items, 0..) |item, idx| {
                    if (item.id == update.window_id) {
                        found_idx = idx;
                        break;
                    }
                }

                if (found_idx) |idx| {
                    const item = &items.items[idx];

                    const new_thumb = thumbnail.Thumbnail{
                        .data = update.thumbnail_data,
                        .width = update.thumbnail_width,
                        .height = update.thumbnail_height,
                        .allocator = update.allocator,
                    };

                    // Update thumbnail data
                    item.thumbnail.deinit();
                    item.thumbnail = new_thumb;

                    // Only update texture if window is visible
                    if (!window_hidden) {
                        const new_texture = ui.loadTextureFromThumbnail(&new_thumb);
                        rl.UnloadTexture(item.texture);
                        item.texture = new_texture;
                    }
                    // If window is hidden, texture remains empty and will be created when window reopens

                    update.thumbnail_data = &[_]u8{};
                } else {
                    const new_thumb = thumbnail.Thumbnail{
                        .data = update.thumbnail_data,
                        .width = update.thumbnail_width,
                        .height = update.thumbnail_height,
                        .allocator = update.allocator,
                    };

                    // Only create texture if window is visible
                    const texture = if (!window_hidden)
                        ui.loadTextureFromThumbnail(&new_thumb)
                    else
                        rl.Texture2D{};

                    const new_item = ui.WindowItem{
                        .id = update.window_id,
                        .title = update.title,
                        .thumbnail = new_thumb,
                        .texture = texture,
                        .display_width = 0,
                        .display_height = 0,
                    };

                    items.append(new_item) catch {
                        if (!window_hidden) rl.UnloadTexture(texture);
                        continue;
                    };

                    if (window_hidden) {
                        log.debug("Added new window {d}: {s} (window hidden, no texture)", .{ new_item.id, new_item.title });
                    } else {
                        log.debug("Added new window {d}: {s}", .{ new_item.id, new_item.title });
                    }

                    update.thumbnail_data = &[_]u8{};
                    update.title = "(unknown)";
                }
            }

            // Adjust selected index
            if (items.items.len == 0) {
                selected_index = 0;
            } else if (selected_index >= items.items.len) {
                selected_index = items.items.len - 1;
            }

            // Recalculate layout
            const prev_width = current_layout.total_width;
            const prev_height = current_layout.total_height;
            current_layout = ui.calculateGridLayout(items.items, ui.THUMBNAIL_HEIGHT);

            // Only update window size/position if window is visible
            if (!window_hidden and (current_layout.total_width != prev_width or current_layout.total_height != prev_height)) {
                rl.SetWindowSize(@intCast(current_layout.total_width), @intCast(current_layout.total_height));
                const new_win_x = mon_x + @divTrunc(mon_width - @as(i32, @intCast(current_layout.total_width)), 2);
                const new_win_y = mon_y + @divTrunc(mon_height - @as(i32, @intCast(current_layout.total_height)), 2);
                rl.SetWindowPosition(new_win_x, new_win_y);
                log.debug("Window resized to {d}x{d}", .{ current_layout.total_width, current_layout.total_height });
            }
        }

        // Handle keyboard input (only when window is visible)
        if (!window_hidden and items.items.len > 0) {
            if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_TAB)) {
                selected_index = (selected_index + 1) % items.items.len;
            }
            if (rl.IsKeyPressed(rl.KEY_LEFT)) {
                if (selected_index == 0) {
                    selected_index = items.items.len - 1;
                } else {
                    selected_index -= 1;
                }
            }
            if (rl.IsKeyPressed(rl.KEY_DOWN)) {
                const cols = current_layout.columns;
                selected_index = @min(selected_index + cols, items.items.len - 1);
            }
            if (rl.IsKeyPressed(rl.KEY_UP)) {
                const cols = current_layout.columns;
                if (selected_index >= cols) {
                    selected_index -= cols;
                }
            }
        }

        // Only render if window is visible
        if (!window_hidden) {
            rl.BeginDrawing();
            rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
            ui.renderSwitcher(items.items, selected_index, font);
            rl.EndDrawing();
        } else {
            // In daemon mode with hidden window, sleep briefly to avoid busy loop
            std.time.sleep(16 * std.time.ns_per_ms); // ~60 FPS equivalent
        }
    }

    // Stop background worker
    update_queue.requestStop();
    worker_thread.join();
    update_queue.deinit(); // Clean up any unconsumed results

    // Unload resources (only if window is still open)
    if (!window_hidden) {
        for (items.items) |*item| {
            rl.UnloadTexture(item.texture);
        }
        rl.UnloadFont(font);
        rl.CloseWindow();
    }
    try stdout.print("Switcher closed.\n", .{});
}
