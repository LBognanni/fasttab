const std = @import("std");
const x11 = @import("x11.zig");
const worker = @import("worker.zig");
const app = @import("app.zig");
const client = @import("client.zig");
const socket = @import("socket.zig");

const log = std.log.scoped(.fasttab);

pub fn main() !void {
    // Fast path: check for CLI commands before any heavy initialization
    // This enables <5ms response time for show/index/hide commands
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip program name

    if (args_iter.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "show")) {
            // show with optional window IDs
            if (args_iter.next()) |ids| {
                client.sendShow(ids) catch |err| {
                    switch (err) {
                        client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                        else => std.debug.print("Error: failed to send command\n", .{}),
                    }
                    std.process.exit(1);
                };
            } else {
                // No IDs - show all windows
                client.sendShowAll() catch |err| {
                    switch (err) {
                        client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                        else => std.debug.print("Error: failed to send command\n", .{}),
                    }
                    std.process.exit(1);
                };
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "index")) {
            const n = args_iter.next() orelse {
                std.debug.print("Usage: fasttab index <n>\n", .{});
                std.process.exit(1);
            };
            client.sendIndex(n) catch |err| {
                switch (err) {
                    client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                    else => std.debug.print("Error: failed to send command\n", .{}),
                }
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, cmd, "hide")) {
            client.sendHide() catch |err| {
                switch (err) {
                    client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                    else => std.debug.print("Error: failed to send command\n", .{}),
                }
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, cmd, "next")) {
            client.sendNext() catch |err| {
                switch (err) {
                    client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                    else => std.debug.print("Error: failed to send command\n", .{}),
                }
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, cmd, "prev")) {
            client.sendPrev() catch |err| {
                switch (err) {
                    client.ClientError.SocketNotFound => std.debug.print("Error: daemon not running (socket not found)\n", .{}),
                    else => std.debug.print("Error: failed to send command\n", .{}),
                }
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, cmd, "daemon") or std.mem.eql(u8, cmd, "--daemon")) {
            return runDaemon(true);
        }
        // Unknown command - fall through to daemon mode
        std.debug.print("Unknown command: {s}\n", .{cmd});
        std.debug.print("Usage: fasttab [daemon|show|index|hide|next|prev]\n", .{});
        std.process.exit(1);
    }

    // No arguments - run in non-daemon mode (legacy behavior)
    return runDaemon(false);
}

/// Run the daemon (full initialization with X11, raylib, socket server)
fn runDaemon(daemon_mode: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    if (daemon_mode) {
        try stdout.print("Starting in daemon mode...\n", .{});
    }

    // Initialize socket server (before any other resources for early binding)
    var sock_server = socket.SocketServer.init(allocator) catch |err| {
        log.err("Failed to initialize socket server: {}", .{err});
        return err;
    };
    defer sock_server.deinit();

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
    var application = try app.App.init(allocator, &initial_result, mouse_pos, daemon_mode, &update_queue);
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

    // Main loop with poll-based event handling
    var pollfds = [_]std.posix.pollfd{
        .{ .fd = sock_server.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (application.isRunning()) {
        // Poll for socket events (16ms timeout ~= 60fps)
        _ = std.posix.poll(&pollfds, 16) catch {};

        // Check for socket commands
        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            if (sock_server.acceptAndRead()) |*parsed_cmd| {
                defer @constCast(parsed_cmd).deinit(allocator);
                handleSocketCommand(&application, parsed_cmd.command);
            }
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

    try stdout.print("Switcher closed.\n", .{});
}

/// Handle a command received from the socket
fn handleSocketCommand(application: *app.App, cmd: socket.Command) void {
    switch (cmd) {
        .show => |maybe_ids| {
            if (maybe_ids) |ids| {
                log.info("Socket command: SHOW with {d} windows", .{ids.len});
                application.showWithWindows(ids);
            } else {
                log.info("Socket command: SHOW (all windows)", .{});
                application.showAll();
            }
        },
        .index => |idx| {
            log.info("Socket command: INDEX {d}", .{idx});
            application.setSelectedIndex(idx);
        },
        .hide => {
            log.info("Socket command: HIDE", .{});
            application.hideWindow();
        },
        .next => {
            log.info("Socket command: NEXT", .{});
            application.selectNext();
        },
        .prev => {
            log.info("Socket command: PREV", .{});
            application.selectPrev();
        },
    }
}
