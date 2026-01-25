const std = @import("std");
const x11 = @import("x11.zig");
const thumbnail = @import("thumbnail.zig");

const log = std.log.scoped(.fasttab);

pub const ThumbnailUpdate = struct {
    window_id: x11.xcb.xcb_window_t,
    title: []const u8,
    thumbnail_data: []u8,
    thumbnail_width: u32,
    thumbnail_height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ThumbnailUpdate) void {
        if (self.thumbnail_data.len > 0) {
            self.allocator.free(self.thumbnail_data);
        }
        if (!std.mem.eql(u8, self.title, "(unknown)")) {
            self.allocator.free(self.title);
        }
    }
};

pub const RefreshResult = struct {
    updates: std.ArrayList(ThumbnailUpdate),
    current_window_ids: std.ArrayList(x11.xcb.xcb_window_t),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RefreshResult {
        return .{
            .updates = std.ArrayList(ThumbnailUpdate).init(allocator),
            .current_window_ids = std.ArrayList(x11.xcb.xcb_window_t).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RefreshResult) void {
        for (self.updates.items) |*update| {
            update.deinit();
        }
        self.updates.deinit();
        self.current_window_ids.deinit();
    }
};

pub const UpdateQueue = struct {
    mutex: std.Thread.Mutex = .{},
    pending_result: ?RefreshResult = null,
    should_stop: bool = false,
    our_window_id: x11.xcb.xcb_window_t = 0,

    pub fn push(self: *UpdateQueue, result: RefreshResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_result) |*old| {
            old.deinit();
        }
        self.pending_result = result;
    }

    pub fn pop(self: *UpdateQueue) ?RefreshResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_result) |result| {
            self.pending_result = null;
            return result;
        }
        return null;
    }

    pub fn requestStop(self: *UpdateQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_stop = true;
    }

    pub fn shouldStop(self: *UpdateQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_stop;
    }

    pub fn setOurWindowId(self: *UpdateQueue, id: x11.xcb.xcb_window_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.our_window_id = id;
    }

    pub fn getOurWindowId(self: *UpdateQueue) x11.xcb.xcb_window_t {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.our_window_id;
    }
};

pub fn backgroundWorker(queue: *UpdateQueue, allocator: std.mem.Allocator) void {
    // Create our own X11 connection (X11 is not thread-safe)
    var conn = x11.Connection.init() catch |err| {
        log.err("Background worker: Failed to connect to X11: {}", .{err});
        return;
    };
    defer conn.deinit();

    log.info("Background worker started", .{});

    // Main worker loop
    while (!queue.shouldStop()) {
        // Sleep for refresh interval
        std.time.sleep(1 * std.time.ns_per_s);

        if (queue.shouldStop()) break;

        const our_window_id = queue.getOurWindowId();

        // Get current window list
        const windows = x11.getWindowList(conn.conn, conn.root, conn.atoms) catch |err| {
            log.warn("Background worker: Failed to get window list: {}", .{err});
            continue;
        };

        var result = RefreshResult.init(allocator);
        errdefer result.deinit();

        // Capture all windows
        for (windows) |window_id| {
            if (window_id == our_window_id) continue;
            if (!x11.shouldShowWindow(conn.conn, window_id, conn.atoms)) continue;

            result.current_window_ids.append(window_id) catch continue;

            const title = x11.getWindowTitle(allocator, conn.conn, window_id, conn.atoms);

            const raw_capture = x11.captureRawImage(allocator, conn.conn, window_id, title) catch |err| {
                log.debug("Background worker: Failed to capture window {d}: {}", .{ window_id, err });
                if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
                continue;
            };
            defer allocator.free(raw_capture.data);

            const thumb = thumbnail.processRawCapture(&raw_capture, allocator) catch |err| {
                log.debug("Background worker: Failed to process window {d}: {}", .{ window_id, err });
                if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
                continue;
            };

            result.updates.append(ThumbnailUpdate{
                .window_id = window_id,
                .title = title,
                .thumbnail_data = thumb.data,
                .thumbnail_width = thumb.width,
                .thumbnail_height = thumb.height,
                .allocator = allocator,
            }) catch {
                allocator.free(thumb.data);
                if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
                continue;
            };
        }

        queue.push(result);
        log.debug("Background worker: Pushed update with {d} thumbnails", .{result.updates.items.len});
    }

    log.info("Background worker stopped", .{});
}
