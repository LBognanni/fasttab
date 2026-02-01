const std = @import("std");
const x11 = @import("x11.zig");
const thumbnail = @import("thumbnail.zig");
const window_scanner = @import("window_scanner.zig");

const log = std.log.scoped(.fasttab);
const DELAY_SECONDS: f32 = 0.25; // seconds between scans

pub const UpdateTask = union(enum) {
    window_added: WindowAdded,
    window_removed: WindowRemoved,
    thumbnail_updated: ThumbnailUpdated,
    title_updated: TitleUpdated,
    icon_added: IconAdded,

    pub const WindowAdded = struct {
        window_id: x11.xcb.xcb_window_t,
        title: []const u8, // owned
        icon_id: []const u8, // owned (WM_CLASS)
        thumbnail_data: []u8, // owned RGBA
        thumbnail_width: u32,
        thumbnail_height: u32,
        thumbnail_version: u32,
        title_version: u32,
        allocator: std.mem.Allocator,
    };
    pub const WindowRemoved = struct { window_id: x11.xcb.xcb_window_t };
    pub const ThumbnailUpdated = struct {
        window_id: x11.xcb.xcb_window_t,
        thumbnail_data: []u8, // owned RGBA
        thumbnail_width: u32,
        thumbnail_height: u32,
        thumbnail_version: u32,
        allocator: std.mem.Allocator,
    };
    pub const TitleUpdated = struct {
        window_id: x11.xcb.xcb_window_t,
        title: []const u8, // owned
        title_version: u32,
        allocator: std.mem.Allocator,
    };
    pub const IconAdded = struct {
        icon_id: []const u8, // owned (WM_CLASS)
        icon_data: []u8, // owned RGBA
        icon_width: u32,
        icon_height: u32,
        allocator: std.mem.Allocator,
    };

    pub fn deinit(self: *UpdateTask) void {
        switch (self.*) {
            .window_added => |*t| {
                if (t.thumbnail_data.len > 0) t.allocator.free(t.thumbnail_data);
                if (t.title.len > 0) t.allocator.free(t.title);
                if (t.icon_id.len > 0) t.allocator.free(t.icon_id);
            },
            .window_removed => {},
            .thumbnail_updated => |*t| {
                if (t.thumbnail_data.len > 0) t.allocator.free(t.thumbnail_data);
            },
            .title_updated => |*t| {
                if (t.title.len > 0) t.allocator.free(t.title);
            },
            .icon_added => |*t| {
                if (t.icon_data.len > 0) t.allocator.free(t.icon_data);
                if (t.icon_id.len > 0) t.allocator.free(t.icon_id);
            },
        }
    }
};

pub const TaskQueue = struct {
    mutex: std.Thread.Mutex = .{},
    tasks: std.ArrayList(UpdateTask),
    should_stop: bool = false,
    window_visible: bool = true,
    first_scan_done: bool = false,

    pub fn init(allocator: std.mem.Allocator) TaskQueue {
        return .{
            .tasks = std.ArrayList(UpdateTask).init(allocator),
        };
    }

    pub fn push(self: *TaskQueue, task: UpdateTask) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tasks.append(task) catch {
            // On OOM, discard the task and free its data
            var t = task;
            t.deinit();
        };
    }

    pub fn drainAll(self: *TaskQueue, out: *std.ArrayList(UpdateTask)) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.tasks.items.len;
        // Attempt to move items to 'out'. If we can't append, we just clear tasks to avoid
        // unbound growth, but ideally we would want to signal error or retry.
        // For now, assume out has capacity or can grow.
        out.appendSlice(self.tasks.items) catch {
            // If we fail to copy, we unfortunately have to drop them to avoid deadlock/stall,
            // or we could keep them. Let's keep them if copy fails, hoping next time it works?
            // But main thread loop might depend on draining.
            // Let's drop them to be safe against infinite loop, but log it?
            // Cannot log easily inside here without scope.
            // Given typical usage, OOM here is fatal anyway.
            return 0;
        };
        self.tasks.clearRetainingCapacity();
        return count;
    }

    pub fn requestStop(self: *TaskQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_stop = true;
    }

    pub fn shouldStop(self: *TaskQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_stop;
    }

    pub fn setWindowVisible(self: *TaskQueue, visible: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.window_visible = visible;
    }

    pub fn isWindowVisible(self: *TaskQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.window_visible;
    }

    pub fn setFirstScanDone(self: *TaskQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.first_scan_done = true;
    }

    pub fn waitForFirstScan(self: *TaskQueue, timeout_ms: u64) bool {
        const start = std.time.milliTimestamp();
        while (true) {
            self.mutex.lock();
            const done = self.first_scan_done;
            const stopped = self.should_stop;
            self.mutex.unlock();

            if (done) return true;
            if (stopped) return false;

            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed >= @as(i64, @intCast(timeout_ms))) return false;

            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn deinit(self: *TaskQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tasks.items) |*task| {
            task.deinit();
        }
        self.tasks.deinit();
    }
};

const TrackedWindow = struct {
    title: []const u8, // owned copy for comparison
    icon_id: []const u8, // owned copy (WM_CLASS)
    title_version: u32,
    thumbnail_version: u32,
    allocator: std.mem.Allocator,

    fn deinit(self: *TrackedWindow) void {
        self.allocator.free(self.title);
        self.allocator.free(self.icon_id);
    }
};

/// Fetch icon from X11, process it, and store in cache. Returns cached thumbnail on success.
fn fetchAndCacheIcon(
    allocator: std.mem.Allocator,
    conn: *x11.Connection,
    window_id: x11.xcb.xcb_window_t,
    wm_class: []const u8,
    icon_cache: *std.StringHashMap(thumbnail.Thumbnail),
) ?thumbnail.Thumbnail {
    var icon_raw = x11.getWindowIcon(allocator, conn.conn, window_id, conn.atoms, thumbnail.ICON_SIZE) orelse return null;
    defer icon_raw.deinit();

    const icon_thumb = thumbnail.processIconArgb(icon_raw.data, icon_raw.width, icon_raw.height, allocator) catch return null;

    // Make a copy for the cache (icon_thumb.data will be the canonical cached copy)
    const cache_key = allocator.dupe(u8, wm_class) catch {
        var t = icon_thumb;
        t.deinit();
        return null;
    };

    icon_cache.put(cache_key, icon_thumb) catch {
        allocator.free(cache_key);
        var t = icon_thumb;
        t.deinit();
        return null;
    };

    // Return the cached entry (the cache now owns the data)
    return icon_cache.get(wm_class);
}

pub fn backgroundWorker(queue: *TaskQueue, allocator: std.mem.Allocator) void {
    // Create our own X11 connection (X11 is not thread-safe)
    var conn = x11.Connection.init() catch |err| {
        log.err("Background worker: Failed to connect to X11: {}", .{err});
        return;
    };
    defer conn.deinit();

    log.info("Background worker started", .{});

    // Track known windows between refreshes (for scanner optimization)
    var known_windows = std.AutoHashMap(x11.xcb.xcb_window_t, void).init(allocator);
    defer known_windows.deinit();

    // Track detailed window state for change detection
    var tracked_windows = std.AutoHashMap(x11.xcb.xcb_window_t, TrackedWindow).init(allocator);
    defer {
        var iter = tracked_windows.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        tracked_windows.deinit();
    }

    // Buffer for known window list (scanner input)
    var known_list = std.ArrayList(x11.xcb.xcb_window_t).init(allocator);
    defer known_list.deinit();

    var is_first_scan = true;
    var pidCache = x11.PidCache.init(allocator);
    defer pidCache.deinit();

    // Icon cache: WM_CLASS -> processed icon thumbnail (raw RGBA data)
    var icon_cache = std.StringHashMap(thumbnail.Thumbnail).init(allocator);
    defer {
        var ic_iter = icon_cache.iterator();
        while (ic_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var thumb = entry.value_ptr.*;
            thumb.deinit();
        }
        icon_cache.deinit();
    }

    // Track which icons have been pushed to the queue
    var pushed_icons = std.StringHashMap(void).init(allocator);
    defer pushed_icons.deinit();

    const ourPid = std.os.linux.getpid();
    log.debug("Background worker: Our PID is {d}", .{ourPid});

    // Main worker loop
    while (!queue.shouldStop()) {
        // For first scan, don't wait - produce results immediately
        if (!is_first_scan) {
            std.time.sleep(DELAY_SECONDS * std.time.ns_per_s);
        }

        if (queue.shouldStop()) break;

        // Build known window list for scanner
        known_list.clearRetainingCapacity();
        var known_iter = known_windows.keyIterator();
        while (known_iter.next()) |key| {
            known_list.append(key.*) catch {};
        }

        // Determine capture mode
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

        // 1. Detect removals
        var tracked_ids = std.ArrayList(x11.xcb.xcb_window_t).init(allocator);
        // Collect keys first to avoid modification during iteration issues
        var tracked_iter = tracked_windows.keyIterator();
        while (tracked_iter.next()) |key| {
            tracked_ids.append(key.*) catch {};
        }
        defer tracked_ids.deinit();

        for (tracked_ids.items) |wid| {
            var found = false;
            for (scan_result.window_ids.items) |swid| {
                if (swid == wid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Window removed
                queue.push(.{ .window_removed = .{ .window_id = wid } });
                if (tracked_windows.fetchRemove(wid)) |entry| {
                    var tw = entry.value;
                    tw.deinit();
                }
            }
        }

        // 2. Process captured windows (additions and updates)
        for (scan_result.items.items) |*item| {
            if (item.thumbnail) |thumb| {
                // Check if existing
                if (tracked_windows.getPtr(item.window_id)) |existing| {
                    // Update existing

                    // Check title
                    if (!std.mem.eql(u8, item.title, existing.title)) {
                        existing.title_version += 1;

                        // Handle ownership of item.title
                        const new_title = if (std.mem.eql(u8, item.title, "(unknown)"))
                            allocator.dupe(u8, "(unknown)") catch continue
                        else
                            allocator.dupe(u8, item.title) catch continue;

                        allocator.free(existing.title);
                        existing.title = new_title; // Transfer ownership to tracked

                        // Send update with copy
                        const title_update = allocator.dupe(u8, existing.title) catch continue;
                        queue.push(.{ .title_updated = .{
                            .window_id = item.window_id,
                            .title = title_update,
                            .title_version = existing.title_version,
                            .allocator = allocator,
                        } });
                    }

                    // Update thumbnail
                    // For now, always update if captured (visible)
                    // (Change detection could be added here)
                    existing.thumbnail_version += 1;
                    const thumb_data = allocator.dupe(u8, thumb.data) catch continue;

                    queue.push(.{ .thumbnail_updated = .{
                        .window_id = item.window_id,
                        .thumbnail_data = thumb_data,
                        .thumbnail_width = thumb.width,
                        .thumbnail_height = thumb.height,
                        .thumbnail_version = existing.thumbnail_version,
                        .allocator = allocator,
                    } });
                } else {
                    // New window
                    const wm_class = x11.getWindowClass(allocator, conn.conn, item.window_id, conn.atoms);
                    defer {
                        if (!std.mem.eql(u8, wm_class, "(unknown)")) {
                            allocator.free(wm_class);
                        }
                    }

                    // Check if we need to send icon
                    if (!pushed_icons.contains(wm_class)) {
                        var icon_data_copy: ?[]u8 = null;
                        var icon_w: u32 = 0;
                        var icon_h: u32 = 0;

                        if (icon_cache.get(wm_class)) |cached_icon| {
                            icon_data_copy = allocator.dupe(u8, cached_icon.data) catch null;
                            icon_w = cached_icon.width;
                            icon_h = cached_icon.height;
                        } else {
                            const icon_opt = fetchAndCacheIcon(allocator, &conn, item.window_id, wm_class, &icon_cache);
                            if (icon_opt) |cached| {
                                icon_data_copy = allocator.dupe(u8, cached.data) catch null;
                                icon_w = cached.width;
                                icon_h = cached.height;
                            }
                        }

                        if (icon_data_copy) |idc| {
                            const icon_id_owned = allocator.dupe(u8, wm_class) catch {
                                allocator.free(idc);
                                continue;
                            };

                            queue.push(.{ .icon_added = .{
                                .icon_id = icon_id_owned,
                                .icon_data = idc,
                                .icon_width = icon_w,
                                .icon_height = icon_h,
                                .allocator = allocator,
                            } });

                            pushed_icons.put(allocator.dupe(u8, wm_class) catch continue, {}) catch {};
                        }
                    }

                    // Add window
                    const title_owned = if (std.mem.eql(u8, item.title, "(unknown)"))
                        allocator.dupe(u8, "(unknown)") catch continue
                    else
                        allocator.dupe(u8, item.title) catch continue;

                    const icon_id_owned = if (std.mem.eql(u8, wm_class, "(unknown)"))
                        allocator.dupe(u8, "(unknown)") catch {
                            allocator.free(title_owned);
                            continue;
                        }
                    else
                        allocator.dupe(u8, wm_class) catch {
                            allocator.free(title_owned);
                            continue;
                        };

                    const thumb_data = allocator.dupe(u8, thumb.data) catch {
                        allocator.free(title_owned);
                        allocator.free(icon_id_owned);
                        continue;
                    };

                    const tracked = TrackedWindow{
                        .title = title_owned, // Takes ownership
                        .icon_id = icon_id_owned, // Takes ownership
                        .title_version = 1,
                        .thumbnail_version = 1,
                        .allocator = allocator,
                    };
                    tracked_windows.put(item.window_id, tracked) catch {
                        // Cleanup
                        var t = tracked;
                        t.deinit();
                        allocator.free(thumb_data);
                        continue;
                    };

                    // Send to queue (needs its own copies)
                    const title_send = allocator.dupe(u8, title_owned) catch {
                        // tracked already owns title_owned, so just free data for send
                        allocator.free(thumb_data);
                        continue;
                    };
                    const icon_id_send = allocator.dupe(u8, icon_id_owned) catch {
                        allocator.free(title_send);
                        allocator.free(thumb_data);
                        continue;
                    };

                    queue.push(.{ .window_added = .{
                        .window_id = item.window_id,
                        .title = title_send,
                        .icon_id = icon_id_send,
                        .thumbnail_data = thumb_data,
                        .thumbnail_width = thumb.width,
                        .thumbnail_height = thumb.height,
                        .thumbnail_version = 1,
                        .title_version = 1,
                        .allocator = allocator,
                    } });
                }
            }
        }

        // Update known windows for scanner optimization
        known_windows.clearRetainingCapacity();
        for (scan_result.window_ids.items) |wid| {
            known_windows.put(wid, {}) catch {};
        }

        if (is_first_scan) {
            queue.setFirstScanDone();
            is_first_scan = false;
        }
    }

    // Cleanup pushed_icons keys
    var pi_iter = pushed_icons.keyIterator();
    while (pi_iter.next()) |key| {
        allocator.free(key.*);
    }

    log.info("Background worker stopped", .{});
}
