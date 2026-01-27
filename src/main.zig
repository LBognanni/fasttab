const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");

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

    // Create update queue and start background worker
    var update_queue = worker.UpdateQueue{};

    const worker_thread = std.Thread.spawn(.{}, worker.backgroundWorker, .{ &update_queue, allocator }) catch |err| {
        log.err("Failed to spawn background worker: {}", .{err});
        return err;
    };

    try stdout.print("Waiting for initial window scan...\n", .{});

    // Wait for initial result from worker
    var initial_result = update_queue.popBlocking(10000) orelse {
        try stdout.print("No windows found (timeout waiting for worker).\n", .{});
        update_queue.requestStop();
        worker_thread.join();
        return;
    };
    defer initial_result.deinit();

    if (initial_result.updates.items.len == 0) {
        try stdout.print("No windows could be captured.\n", .{});
        update_queue.requestStop();
        worker_thread.join();
        return;
    }

    try stdout.print("Found {d} windows.\n", .{initial_result.updates.items.len});

    for (initial_result.updates.items) |update| {
        try stdout.print("  {s} ({d}x{d})\n", .{ update.title, update.thumbnail_width, update.thumbnail_height });
    }

    // Get mouse position BEFORE initializing raylib
    const mouse_pos = x11.getMousePosition(conn.conn, conn.root);

    // In daemon mode, wait before showing window
    if (daemon_mode) {
        try stdout.print("Daemon mode: background worker running, waiting 2 seconds before showing window...\n", .{});
        std.time.sleep(2 * std.time.ns_per_s);
        try stdout.print("Initializing window...\n", .{});
    }

    // Save window list before creating raylib window (to detect our own window ID)
    const windows_before_raylib = try x11.getWindowList(conn.conn, conn.root, conn.atoms);
    var pre_raylib_windows = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
    defer pre_raylib_windows.deinit();
    for (windows_before_raylib) |wid| {
        try pre_raylib_windows.put(wid, {});
    }

    // Initialize the application
    var application = try app.App.init(allocator, &initial_result, mouse_pos, daemon_mode);
    defer application.deinit();

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

    // Set our window ID in the update queue
    update_queue.setOurWindowId(our_window_id);

    const layout = application.getLayout();
    try stdout.print("Grid layout: {d} cols x {d} rows, window size: {d}x{d}\n", .{
        layout.columns,
        layout.rows,
        layout.total_width,
        layout.total_height,
    });

    try stdout.print("Mouse at ({d}, {d}), using monitor {d}\n", .{
        mouse_pos.x,
        mouse_pos.y,
        application.monitor.index,
    });

    if (daemon_mode) {
        try stdout.print("Displaying {d} windows in switcher (daemon mode - closing window will keep process running).\n", .{application.windowCount()});
    } else {
        try stdout.print("Displaying {d} windows in switcher. Press ESC or close window to exit.\n", .{application.windowCount()});
    }

    // Main loop
    while (application.isRunning()) {
        // Poll update queue from background worker
        if (update_queue.pop()) |*update_result| {
            defer @constCast(update_result).deinit();
            application.processWorkerUpdate(@constCast(update_result));
        }

        // Update and render
        application.update();
    }

    // Stop background worker
    update_queue.requestStop();
    worker_thread.join();
    update_queue.deinit();

    try stdout.print("Switcher closed.\n", .{});
}
