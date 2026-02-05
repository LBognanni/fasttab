const std = @import("std");
const x11 = @import("x11.zig");

const log = std.log.scoped(.fasttab);

pub const ScanOptions = struct {
    /// Windows we already have - used to detect new/removed windows
    known_windows: ?[]const x11.xcb.xcb_window_t = null,
    /// When true, only return NEW windows (skip all known windows)
    /// When false, only skip minimized known windows (default behavior)
    capture_only_new: bool = false,
};

pub const ProcessedWindow = struct {
    window_id: x11.xcb.xcb_window_t,
    title: []const u8,
    is_minimized: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessedWindow) void {
        if (!std.mem.eql(u8, self.title, "(unknown)")) {
            self.allocator.free(self.title);
        }
    }
};

pub const ScanResult = struct {
    /// Discovered windows
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

/// Scan windows from X11.
/// - Filters windows by type and current desktop
/// - Returns window info (no thumbnail capture - that's done via GLX on main thread)
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
    const windows = try x11.getWindowList(allocator, conn.conn, conn.root, conn.atoms);
    defer allocator.free(windows);

    var result = ScanResult.init(allocator);
    errdefer result.deinit();

    for (windows) |window_id| {
        if (x11.isCurrentExecutable(conn.conn, window_id, conn.atoms, pidCache)) {
            continue;
        }

        // Filter by window type
        if (!x11.shouldShowWindow(conn.conn, window_id, conn.atoms)) {
            continue;
        }

        // Filter by current desktop
        if (!x11.isWindowOnCurrentDesktop(conn.conn, window_id, conn.root, conn.atoms)) {
            continue;
        }

        // Add to window_ids (all windows on current desktop)
        try result.window_ids.append(window_id);

        const is_minimized = x11.isWindowMinimized(conn.conn, window_id, conn.atoms);
        const is_known = known_set.contains(window_id);

        // When capture_only_new is true (window hidden), skip ALL known windows
        // When false (window visible or first scan), only skip minimized known windows
        if (options.capture_only_new and is_known) {
            continue;
        }
        if (is_minimized and is_known) {
            continue;
        }

        // Get window title
        const title = x11.getWindowTitle(allocator, conn.conn, window_id, conn.atoms);

        try result.items.append(.{
            .window_id = window_id,
            .title = title,
            .is_minimized = is_minimized,
            .allocator = allocator,
        });
    }

    return result;
}
