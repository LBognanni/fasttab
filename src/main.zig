const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");

const log = std.log.scoped(.fasttab);

pub fn main() !void {
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    if (args_iter.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "daemon") or std.mem.eql(u8, cmd, "--daemon")) {
            return runDaemon();
        }
        std.debug.print("Unknown command: {s}\n", .{cmd});
        std.debug.print("Usage: fasttab [daemon]\n", .{});
        std.process.exit(1);
    }

    // No arguments - run daemon
    return runDaemon();
}

/// Run the daemon with XCB key grabbing
fn runDaemon() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Connect to X11
    var conn = try x11.Connection.init();
    defer conn.deinit();

    // Register for PropertyNotify events on root window
    const event_mask = [_]u32{x11.xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
    _ = x11.xcb.xcb_change_window_attributes(conn.conn, conn.root, x11.xcb.XCB_CW_EVENT_MASK, &event_mask);
    conn.flush();

    // Grab Alt+Tab passively
    x11.grabAltTab(conn.conn, conn.root);
    defer x11.ungrabAltTab(conn.conn, conn.root);

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
        try stdout.print(" {x} {s} ({d}x{d})\n", .{ update.window_id, update.title, update.thumbnail_width, update.thumbnail_height });
    }

    // Get mouse position BEFORE initializing raylib
    const mouse_pos = x11.getMousePosition(conn.conn, conn.root);

    // Initialize app in daemon mode (window created but hidden)
    var application = try app.App.init(allocator, &initial_result, mouse_pos, true, &update_queue, conn.conn, conn.root, conn.atoms);
    defer application.deinit();
    application.hideWindow();

    try stdout.print("Daemon ready: {d} windows tracked, Alt+Tab grabbed.\n", .{application.windowCount()});

    // Main loop: poll on XCB file descriptor
    const xcb_fd = x11.getXcbFd(conn.conn);
    var pollfds = [_]std.posix.pollfd{
        .{ .fd = xcb_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (application.isRunning()) {
        // Poll for XCB events (16ms timeout ~= 60fps)
        _ = std.posix.poll(&pollfds, 16) catch {};

        // Process XCB events (key press/release)
        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            processXcbEvents(&application, conn.conn);
        }

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

    try stdout.print("Daemon stopped.\n", .{});
}

/// Process all pending XCB events (key press/release)
fn processXcbEvents(application: *app.App, conn: *x11.xcb.xcb_connection_t) void {
    while (true) {
        const event = x11.xcb.xcb_poll_for_event(conn);
        if (event == null) break;
        defer std.c.free(event);

        const response_type = event.*.response_type & 0x7f;

        switch (response_type) {
            x11.xcb.XCB_KEY_PRESS => {
                const key_event: *x11.xcb.xcb_key_press_event_t = @ptrCast(event);
                const keysym = x11.keycodeToKeysym(conn, key_event.detail, 0);
                const state_mask = key_event.state;

                // Check for Shift via state mask or keysym
                const is_shift = (state_mask & x11.MOD_SHIFT) != 0;

                if (application.state == .idle) {
                    // Idle: only respond to Alt+Tab / Alt+Shift+Tab
                    if (keysym == x11.XK_Tab or keysym == x11.XK_ISO_Left_Tab) {
                        application.handleAltTab(is_shift or keysym == x11.XK_ISO_Left_Tab);
                    }
                } else {
                    // Switching: forward all key presses
                    // For Tab with Shift held, also check ISO_Left_Tab
                    const effective_keysym = if (keysym == x11.XK_Tab and is_shift)
                        x11.XK_ISO_Left_Tab
                    else
                        keysym;
                    _ = application.handleKeyEvent(effective_keysym, true, state_mask);
                }
            },
            x11.xcb.XCB_KEY_RELEASE => {
                const key_event: *x11.xcb.xcb_key_release_event_t = @ptrCast(event);
                const keysym = x11.keycodeToKeysym(conn, key_event.detail, 0);
                const state_mask = key_event.state;

                _ = application.handleKeyEvent(keysym, false, state_mask);
            },
            else => {},
        }
    }
}
