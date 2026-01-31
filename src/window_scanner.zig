const std = @import("std");
const x11 = @import("x11.zig");
const thumbnail = @import("thumbnail.zig");

const log = std.log.scoped(.fasttab);

pub const ScanOptions = struct {
    /// Windows we already have thumbnails for - used to skip re-capturing minimized windows
    known_windows: ?[]const x11.xcb.xcb_window_t = null,
    /// When true, only capture NEW windows (skip all known windows, not just minimized)
    /// When false, only skip minimized known windows (default behavior)
    capture_only_new: bool = false,
    /// Enable parallel thumbnail processing using thread pool
    parallel_processing: bool = true,
    /// Maximum threads for parallel processing (null = auto-detect)
    max_threads: ?u32 = null,
};

pub const ProcessedWindow = struct {
    window_id: x11.xcb.xcb_window_t,
    title: []const u8,
    thumbnail: ?thumbnail.Thumbnail, // null if capture failed (e.g., minimized window on refresh)
    is_minimized: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessedWindow) void {
        if (self.thumbnail) |*thumb| {
            thumb.deinit();
        }
        if (!std.mem.eql(u8, self.title, "(unknown)")) {
            self.allocator.free(self.title);
        }
    }
};

pub const ScanResult = struct {
    /// Successfully processed windows with thumbnails
    items: std.ArrayList(ProcessedWindow),
    /// All window IDs on current desktop (including minimized, for tracking)
    window_ids: std.ArrayList(x11.xcb.xcb_window_t),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScanResult {
        return .{
            .items = std.ArrayList(ProcessedWindow).init(allocator),
            .window_ids = std.ArrayList(x11.xcb.xcb_window_t).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScanResult) void {
        for (self.items.items) |*item| {
            item.deinit();
        }
        self.items.deinit();
        self.window_ids.deinit();
    }
};

/// Internal struct for passing data to worker threads
const CaptureTask = struct {
    window_id: x11.xcb.xcb_window_t,
    title: []const u8,
    raw_capture: ?x11.RawCapture,
    is_minimized: bool,
    is_new_window: bool,
};

const ProcessResult = struct {
    thumb: ?thumbnail.Thumbnail,
    task_idx: usize,
};

/// Scan and process windows from X11.
/// - Filters windows by type and current desktop
/// - Captures thumbnails in parallel (if enabled)
/// - Skips re-capturing minimized windows that are already known
pub fn scanAndProcess(allocator: std.mem.Allocator, conn: *x11.Connection, options: ScanOptions, pidCache: ?*x11.PidCache) !ScanResult {
    // Build a set of known windows for fast lookup
    var known_set = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
    defer known_set.deinit();
    if (options.known_windows) |known| {
        for (known) |wid| {
            try known_set.put(wid, {});
        }
    }

    // Get current window list from X11
    const windows = try x11.getWindowList(conn.conn, conn.root, conn.atoms);

    var result = ScanResult.init(allocator);
    errdefer result.deinit();

    // First pass: filter windows and prepare capture tasks
    var capture_tasks = std.ArrayList(CaptureTask).init(allocator);
    defer {
        for (capture_tasks.items) |*task| {
            if (task.raw_capture) |*cap| {
                allocator.free(cap.data);
            }
        }
        capture_tasks.deinit();
    }

    var stats = struct {
        total: usize = 0,
        filtered_by_type: usize = 0,
        filtered_by_desktop: usize = 0,
        skipped_minimized: usize = 0,
        capture_failed: usize = 0,
    }{};

    for (windows) |window_id| {
        stats.total += 1;

        if (x11.isCurrentExecutable(conn.conn, window_id, conn.atoms, pidCache)) {
            continue;
        }

        // Filter by window type
        if (!x11.shouldShowWindow(conn.conn, window_id, conn.atoms)) {
            stats.filtered_by_type += 1;
            continue;
        }

        // Filter by current desktop
        if (!x11.isWindowOnCurrentDesktop(conn.conn, window_id, conn.root, conn.atoms)) {
            stats.filtered_by_desktop += 1;
            continue;
        }

        // Add to window_ids (all windows on current desktop)
        try result.window_ids.append(window_id);

        const is_minimized = x11.isWindowMinimized(conn.conn, window_id, conn.atoms);
        const is_known = known_set.contains(window_id);

        // When capture_only_new is true (window hidden), skip ALL known windows
        // When false (window visible or first scan), only skip minimized known windows
        if (options.capture_only_new and is_known) {
            stats.skipped_minimized += 1; // reusing counter for skipped windows
            continue;
        }
        if (is_minimized and is_known) {
            stats.skipped_minimized += 1;
            continue;
        }

        // Get window title
        const title = x11.getWindowTitle(allocator, conn.conn, window_id, conn.atoms);

        // Try to capture raw image
        const raw_capture = x11.captureRawImage(allocator, conn.conn, window_id, title) catch |err| {
            // If geometry fetch failed, window no longer exists - remove from window_ids
            if (err == x11.X11Error.GeometryFetchFailed) {
                _ = result.window_ids.pop();
                if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
                log.debug("Window {x} no longer exists", .{window_id});
                continue;
            }

            // For other errors, keep window in list but mark capture as failed
            stats.capture_failed += 1;
            log.debug("Failed to capture window {x}: {}", .{ window_id, err });

            try capture_tasks.append(.{
                .window_id = window_id,
                .title = title,
                .raw_capture = null,
                .is_minimized = is_minimized,
                .is_new_window = !is_known,
            });
            continue;
        };

        try capture_tasks.append(.{
            .window_id = window_id,
            .title = title,
            .raw_capture = raw_capture,
            .is_minimized = is_minimized,
            .is_new_window = !is_known,
        });
    }

    // Second pass: process captures into thumbnails
    if (capture_tasks.items.len == 0) {
        // log.debug("Scanner: {d} total, {d} filtered by type, {d} by desktop, {d} skipped minimized, 0 to process", .{
        //     stats.total,
        //     stats.filtered_by_type,
        //     stats.filtered_by_desktop,
        //     stats.skipped_minimized,
        // });
        return result;
    }

    // Allocate result array for parallel processing
    var process_results = try allocator.alloc(ProcessResult, capture_tasks.items.len);
    defer allocator.free(process_results);

    for (process_results, 0..) |*r, idx| {
        r.* = .{ .thumb = null, .task_idx = idx };
    }

    if (options.parallel_processing and capture_tasks.items.len > 1) {
        // Parallel processing with thread pool
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const max_threads = options.max_threads orelse @as(u32, @intCast(cpu_count));
        const thread_count: u32 = @intCast(@max(1, @min(max_threads, capture_tasks.items.len)));

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = allocator,
            .n_jobs = thread_count,
        });

        for (capture_tasks.items, 0..) |*task, idx| {
            if (task.raw_capture) |*cap| {
                try pool.spawn(struct {
                    fn work(raw_cap: *const x11.RawCapture, res: *ProcessResult, alloc: std.mem.Allocator) void {
                        res.thumb = thumbnail.processRawCapture(raw_cap, alloc) catch null;
                    }
                }.work, .{ cap, &process_results[idx], allocator });
            }
        }

        pool.deinit(); // Waits for all tasks to complete
    } else {
        // Sequential processing
        for (capture_tasks.items, 0..) |*task, idx| {
            if (task.raw_capture) |*cap| {
                process_results[idx].thumb = thumbnail.processRawCapture(cap, allocator) catch null;
            }
        }
    }

    // Collect results
    try result.items.ensureTotalCapacity(capture_tasks.items.len);

    for (capture_tasks.items, 0..) |*task, idx| {
        const thumb = process_results[idx].thumb;

        // For new windows without thumbnails, skip them (they'll be retried)
        // For known windows, we keep them in window_ids but don't add to items
        if (thumb == null and task.is_new_window) {
            if (!std.mem.eql(u8, task.title, "(unknown)")) {
                allocator.free(task.title);
            }
            task.title = "(unknown)"; // Prevent double-free
            continue;
        }

        // If we have a thumbnail, add to items
        if (thumb != null) {
            result.items.appendAssumeCapacity(.{
                .window_id = task.window_id,
                .title = task.title,
                .thumbnail = thumb,
                .is_minimized = task.is_minimized,
                .allocator = allocator,
            });
            task.title = "(unknown)"; // Transfer ownership, prevent double-free
        } else {
            // No thumbnail but known window - title already allocated, just free it
            if (!std.mem.eql(u8, task.title, "(unknown)")) {
                allocator.free(task.title);
            }
            task.title = "(unknown)";
        }
    }

    // log.debug("Scanner: {d} total, {d} filtered by type, {d} by desktop, {d} skipped minimized, {d} captured", .{
    //     stats.total,
    //     stats.filtered_by_type,
    //     stats.filtered_by_desktop,
    //     stats.skipped_minimized,
    //     result.items.items.len,
    // });

    return result;
}
