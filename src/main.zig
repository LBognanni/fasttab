const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");

const log = std.log.scoped(.fasttab);

pub fn main() !void {
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    var replace = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        } else if (std.mem.eql(u8, arg, "daemon") or std.mem.eql(u8, arg, "--daemon")) {
            // explicit daemon mode, continue
        } else {
            std.debug.print("Unknown command: {s}\n", .{arg});
            std.debug.print("Usage: fasttab [daemon] [--replace]\n", .{});
            std.process.exit(1);
        }
    }

    if (replace) {
        try killExistingInstance();
        // Give it a moment to die and release X11 grabs
        std.time.sleep(200 * std.time.ns_per_ms);
    }

    // Run daemon
    return runDaemon();
}

fn killExistingInstance() !void {
    const my_pid = std.c.getpid();
    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (pid == my_pid) continue;

        // Check comm
        var buf: [256]u8 = undefined;
        const comm_path = try std.fmt.bufPrint(&buf, "/proc/{d}/comm", .{pid});
        const file = std.fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer file.close();

        const bytes_read = try file.readAll(&buf);
        const comm = std.mem.trimRight(u8, buf[0..bytes_read], "\n");

        if (std.mem.eql(u8, comm, "fasttab")) {
            std.debug.print("Killing existing instance (PID {d})...\n", .{pid});
            std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
                std.debug.print("Failed to kill PID {d}: {}\n", .{pid, err});
            };
        }
    }
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
    var task_queue = worker.TaskQueue.init(allocator);

    const worker_thread = std.Thread.spawn(.{}, worker.backgroundWorker, .{ &task_queue, allocator }) catch |err| {
        log.err("Failed to spawn background worker: {}", .{err});
        return err;
    };

    try stdout.print("Waiting for initial window scan...\n", .{});

    // Wait for first scan completion from worker
    if (!task_queue.waitForFirstScan(10000)) {
        try stdout.print("Timeout waiting for worker scan.\n", .{});
        task_queue.requestStop();
        worker_thread.join();
        task_queue.deinit();
        return;
    }

    try stdout.print("Initial scan complete.\n", .{});

    // Initialize app in daemon mode (window created but hidden)
    // App init drains the queue for initial windows
    var application = try app.App.init(allocator, &task_queue, true, conn.conn, conn.root, conn.atoms);
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

        // Process updates from queue
        application.drainUpdateQueue();

        // Update and render
        application.update();
    }

    // Stop background worker
    task_queue.requestStop();
    worker_thread.join();
    task_queue.deinit();

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
                    _ = application.handleKeyEvent(effective_keysym, true);
                }
            },
            x11.xcb.XCB_KEY_RELEASE => {
                const key_event: *x11.xcb.xcb_key_release_event_t = @ptrCast(event);
                const keysym = x11.keycodeToKeysym(conn, key_event.detail, 0);

                _ = application.handleKeyEvent(keysym, false);
            },
            else => {},
        }
    }
}
