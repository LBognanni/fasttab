const std = @import("std");
const x11 = @import("x11.zig");
const thumbnail = @import("thumbnail.zig");
const window_scanner = @import("window_scanner.zig");

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
    window_visible: bool = true, // Whether the app window is currently visible

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

    pub fn setWindowVisible(self: *UpdateQueue, visible: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.window_visible = visible;
    }

    pub fn isWindowVisible(self: *UpdateQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.window_visible;
    }

    /// Clean up any pending result that was never consumed
    pub fn deinit(self: *UpdateQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_result) |*result| {
            result.deinit();
            self.pending_result = null;
        }
    }

    /// Wait for a result with timeout. Returns null if timeout expires or stop requested.
    pub fn popBlocking(self: *UpdateQueue, timeout_ms: u64) ?RefreshResult {
        const start = std.time.milliTimestamp();
        const timeout_ns = timeout_ms * std.time.ns_per_ms;

        while (true) {
            // Check for result
            if (self.pop()) |result| {
                return result;
            }

            // Check for stop request
            if (self.shouldStop()) {
                return null;
            }

            // Check timeout
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed >= @as(i64, @intCast(timeout_ms))) {
                return null;
            }

            // Sleep briefly before retrying
            std.time.sleep(10 * std.time.ns_per_ms);
            _ = timeout_ns; // Silence unused warning
        }
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

    // Track known windows between refreshes
    var known_windows = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
    defer known_windows.deinit();

    // Buffer for known window list
    var known_list = std.ArrayList(x11.xcb.xcb_window_t).init(allocator);
    defer known_list.deinit();

    var is_first_scan = true;
    var pidCache = x11.PidCache.init(allocator);
    defer pidCache.deinit();

    const ourPid = std.os.linux.getpid();
    log.debug("Background worker: Our PID is {d}", .{ourPid});

    // Main worker loop
    while (!queue.shouldStop()) {
        // For first scan, don't wait - produce results immediately
        if (!is_first_scan) {
            std.time.sleep(1 * std.time.ns_per_s);
        }

        if (queue.shouldStop()) break;

        // Build known window list for scanner
        known_list.clearRetainingCapacity();
        var known_iter = known_windows.keyIterator();
        while (known_iter.next()) |key| {
            known_list.append(key.*) catch {};
        }

        // Determine capture mode:
        // - First scan: capture all windows
        // - Window visible: capture all windows (to refresh thumbnails)
        // - Window hidden: only capture NEW windows (idle optimization)
        const window_visible = queue.isWindowVisible();
        const capture_only_new = !is_first_scan and !window_visible;

        // Use window_scanner for parallel processing
        var scan_result = window_scanner.scanAndProcess(allocator, &conn, .{
            .known_windows = if (known_list.items.len > 0) known_list.items else null,
            .capture_only_new = capture_only_new,
            .parallel_processing = true,
        }, &pidCache) catch |err| {
            log.warn("Background worker: Scan failed: {}", .{err});
            continue;
        };
        defer scan_result.deinit();

        // Update known windows with current window list
        known_windows.clearRetainingCapacity();
        for (scan_result.window_ids.items) |wid| {
            known_windows.put(wid, {}) catch {};
        }

        // Convert scan result to RefreshResult for the queue
        var result = RefreshResult.init(allocator);
        errdefer result.deinit();

        // Copy window IDs
        for (scan_result.window_ids.items) |wid| {
            result.current_window_ids.append(wid) catch {};
        }

        // Convert ProcessedWindows to ThumbnailUpdates
        for (scan_result.items.items) |*item| {
            if (item.thumbnail) |thumb| {
                // Duplicate title for the update (scanner will free its copy)
                const title_copy = if (std.mem.eql(u8, item.title, "(unknown)"))
                    item.title
                else
                    allocator.dupe(u8, item.title) catch "(unknown)";

                // Duplicate thumbnail data (scanner will free its copy)
                const data_copy = allocator.dupe(u8, thumb.data) catch continue;

                result.updates.append(ThumbnailUpdate{
                    .window_id = item.window_id,
                    .title = title_copy,
                    .thumbnail_data = data_copy,
                    .thumbnail_width = thumb.width,
                    .thumbnail_height = thumb.height,
                    .allocator = allocator,
                }) catch {
                    allocator.free(data_copy);
                    if (!std.mem.eql(u8, title_copy, "(unknown)")) {
                        allocator.free(title_copy);
                    }
                    continue;
                };
            }
        }

        queue.push(result);
        // log.debug("Background worker: {d} windows, {d} thumbnails", .{
        //     scan_result.window_ids.items.len,
        //     scan_result.items.items.len,
        // });

        is_first_scan = false;
    }

    log.info("Background worker stopped", .{});
}
