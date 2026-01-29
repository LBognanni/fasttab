const std = @import("std");

// Feature flags
pub const FILTER_BY_CURRENT_DESKTOP = true;

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_image.h");
    @cInclude("xcb/xcb_keysyms.h");
});

const log = std.log.scoped(.fasttab);

// Keysym constants (from X11/keysymdef.h)
pub const XK_Tab = 0xff09;
pub const XK_ISO_Left_Tab = 0xfe20;
pub const XK_Alt_L = 0xffe9;
pub const XK_Alt_R = 0xffea;
pub const XK_Escape = 0xff1b;
pub const XK_Return = 0xff0d;
pub const XK_Left = 0xff51;
pub const XK_Up = 0xff52;
pub const XK_Right = 0xff53;
pub const XK_Down = 0xff54;

// Modifier masks (u16 to match xcb_grab_key modifiers parameter)
pub const MOD_SHIFT: u16 = 1; // XCB_MOD_MASK_SHIFT
pub const MOD_LOCK: u16 = 2; // XCB_MOD_MASK_LOCK (CapsLock)
pub const MOD_ALT: u16 = 8; // XCB_MOD_MASK_1
pub const MOD_MOD2: u16 = 16; // XCB_MOD_MASK_2 (NumLock typically)

// Cached current process PID (computed once)
var cached_current_pid: ?std.posix.pid_t = null;

fn getCurrentPid() std.posix.pid_t {
    if (cached_current_pid) |pid| {
        return pid;
    }
    const pid = std.os.linux.getpid();
    cached_current_pid = pid;
    return pid;
}

/// Cache for window -> PID mappings
pub const PidCache = struct {
    map: std.AutoHashMap(xcb.xcb_window_t, std.posix.pid_t),

    pub fn init(allocator: std.mem.Allocator) PidCache {
        return .{
            .map = std.AutoHashMap(xcb.xcb_window_t, std.posix.pid_t).init(allocator),
        };
    }

    pub fn deinit(self: *PidCache) void {
        self.map.deinit();
    }

    pub fn get(self: *PidCache, window: xcb.xcb_window_t) ?std.posix.pid_t {
        return self.map.get(window);
    }

    pub fn put(self: *PidCache, window: xcb.xcb_window_t, pid: std.posix.pid_t) void {
        self.map.put(window, pid) catch {};
    }

    pub fn remove(self: *PidCache, window: xcb.xcb_window_t) void {
        _ = self.map.remove(window);
    }

    pub fn clear(self: *PidCache) void {
        self.map.clearRetainingCapacity();
    }
};

pub const X11Error = error{
    ConnectionFailed,
    ConnectionError,
    AtomNotFound,
    PropertyFetchFailed,
    NoScreen,
    CompositeExtensionMissing,
    PixmapCreationFailed,
    ImageCaptureFailed,
    GeometryFetchFailed,
    OutOfMemory,
};

pub const Atoms = struct {
    net_client_list: xcb.xcb_atom_t,
    net_wm_name: xcb.xcb_atom_t,
    wm_name: xcb.xcb_atom_t,
    wm_class: xcb.xcb_atom_t,
    utf8_string: xcb.xcb_atom_t,
    net_wm_window_type: xcb.xcb_atom_t,
    net_wm_window_type_normal: xcb.xcb_atom_t,
    net_wm_window_type_desktop: xcb.xcb_atom_t,
    net_wm_window_type_dock: xcb.xcb_atom_t,
    net_wm_window_type_dialog: xcb.xcb_atom_t,
    net_wm_window_type_utility: xcb.xcb_atom_t,
    net_wm_state: xcb.xcb_atom_t,
    net_wm_state_hidden: xcb.xcb_atom_t,
    net_current_desktop: xcb.xcb_atom_t,
    net_wm_desktop: xcb.xcb_atom_t,
    net_wm_pid: xcb.xcb_atom_t,
    net_client_list_stacking: xcb.xcb_atom_t,
    net_active_window: xcb.xcb_atom_t,
    net_wm_icon: xcb.xcb_atom_t,
};

pub const MousePosition = struct {
    x: i32,
    y: i32,
};

// Raw capture data from X11 (before processing)
pub const RawCapture = struct {
    window_id: xcb.xcb_window_t,
    title: []const u8,
    width: u16,
    height: u16,
    data: []u8, // Raw BGRA from X11
    depth: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RawCapture) void {
        self.allocator.free(self.data);
        if (!std.mem.eql(u8, self.title, "(unknown)")) {
            self.allocator.free(self.title);
        }
    }
};

pub const Connection = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: xcb.xcb_window_t,
    atoms: Atoms,

    pub fn init() X11Error!Connection {
        var screen_num: c_int = 0;
        const conn = xcb.xcb_connect(null, &screen_num);
        if (conn == null) {
            return X11Error.ConnectionFailed;
        }

        if (xcb.xcb_connection_has_error(conn) != 0) {
            xcb.xcb_disconnect(conn);
            return X11Error.ConnectionError;
        }

        // Get the screen
        const setup = xcb.xcb_get_setup(conn);
        var iter = xcb.xcb_setup_roots_iterator(setup);

        var i: c_int = 0;
        while (i < screen_num) : (i += 1) {
            xcb.xcb_screen_next(&iter);
        }
        const screen = iter.data;
        if (screen == null) {
            xcb.xcb_disconnect(conn);
            return X11Error.NoScreen;
        }

        const atoms = try initAtoms(conn.?);
        try initComposite(conn.?, screen.*.root);

        return Connection{
            .conn = conn.?,
            .screen = screen.?,
            .root = screen.*.root,
            .atoms = atoms,
        };
    }

    pub fn deinit(self: *Connection) void {
        xcb.xcb_disconnect(self.conn);
    }

    pub fn flush(self: *Connection) void {
        _ = xcb.xcb_flush(self.conn);
    }
};

fn internAtom(conn: *xcb.xcb_connection_t, name: [:0]const u8) X11Error!xcb.xcb_atom_t {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, null);
    if (reply == null) {
        return X11Error.AtomNotFound;
    }
    defer std.c.free(reply);
    return reply.*.atom;
}

pub fn initAtoms(conn: *xcb.xcb_connection_t) X11Error!Atoms {
    return Atoms{
        .net_client_list = try internAtom(conn, "_NET_CLIENT_LIST"),
        .net_wm_name = try internAtom(conn, "_NET_WM_NAME"),
        .wm_name = try internAtom(conn, "WM_NAME"),
        .wm_class = try internAtom(conn, "WM_CLASS"),
        .utf8_string = try internAtom(conn, "UTF8_STRING"),
        .net_wm_window_type = try internAtom(conn, "_NET_WM_WINDOW_TYPE"),
        .net_wm_window_type_normal = try internAtom(conn, "_NET_WM_WINDOW_TYPE_NORMAL"),
        .net_wm_window_type_desktop = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DESKTOP"),
        .net_wm_window_type_dock = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK"),
        .net_wm_window_type_dialog = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DIALOG"),
        .net_wm_window_type_utility = try internAtom(conn, "_NET_WM_WINDOW_TYPE_UTILITY"),
        .net_wm_state = try internAtom(conn, "_NET_WM_STATE"),
        .net_wm_state_hidden = try internAtom(conn, "_NET_WM_STATE_HIDDEN"),
        .net_current_desktop = try internAtom(conn, "_NET_CURRENT_DESKTOP"),
        .net_wm_desktop = try internAtom(conn, "_NET_WM_DESKTOP"),
        .net_wm_pid = try internAtom(conn, "_NET_WM_PID"),
        .net_client_list_stacking = try internAtom(conn, "_NET_CLIENT_LIST_STACKING"),
        .net_active_window = try internAtom(conn, "_NET_ACTIVE_WINDOW"),
        .net_wm_icon = try internAtom(conn, "_NET_WM_ICON"),
    };
}

pub fn initComposite(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) X11Error!void {
    _ = root;

    const cookie = xcb.xcb_composite_query_version(conn, 0, 4);
    const reply = xcb.xcb_composite_query_version_reply(conn, cookie, null);
    if (reply == null) {
        return X11Error.CompositeExtensionMissing;
    }
    defer std.c.free(reply);
}

pub fn getWindowList(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t, atoms: Atoms) X11Error![]xcb.xcb_window_t {
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        root,
        atoms.net_client_list,
        xcb.XCB_ATOM_WINDOW,
        0,
        1024,
    );
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return X11Error.PropertyFetchFailed;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return &[_]xcb.xcb_window_t{};
    }

    const data: [*]xcb.xcb_window_t = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const count = @as(usize, @intCast(len)) / @sizeOf(xcb.xcb_window_t);
    return data[0..count];
}

pub fn getWindowTitle(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) []const u8 {
    // Try _NET_WM_NAME (UTF-8) first
    const net_cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_name, atoms.utf8_string, 0, 1024);
    const net_reply = xcb.xcb_get_property_reply(conn, net_cookie, null);
    if (net_reply != null) {
        defer std.c.free(net_reply);
        const len = xcb.xcb_get_property_value_length(net_reply);
        if (len > 0) {
            const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(net_reply));
            return allocator.dupe(u8, data[0..@intCast(len)]) catch "(unknown)";
        }
    }

    // Fallback to WM_NAME
    const wm_cookie = xcb.xcb_get_property(conn, 0, window, atoms.wm_name, xcb.XCB_ATOM_STRING, 0, 1024);
    const wm_reply = xcb.xcb_get_property_reply(conn, wm_cookie, null);
    if (wm_reply != null) {
        defer std.c.free(wm_reply);
        const len = xcb.xcb_get_property_value_length(wm_reply);
        if (len > 0) {
            const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(wm_reply));
            return allocator.dupe(u8, data[0..@intCast(len)]) catch "(unknown)";
        }
    }

    return "(unknown)";
}

pub fn shouldShowWindow(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) bool {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_window_type, xcb.XCB_ATOM_ATOM, 0, 32);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return true;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return true;
    }

    const data: [*]const xcb.xcb_atom_t = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const count = @as(usize, @intCast(len)) / @sizeOf(xcb.xcb_atom_t);

    for (data[0..count]) |window_type| {
        if (window_type == atoms.net_wm_window_type_desktop) {
            return false;
        }
        if (window_type == atoms.net_wm_window_type_dock) {
            return false;
        }
        if (window_type == atoms.net_wm_window_type_normal or
            window_type == atoms.net_wm_window_type_dialog or
            window_type == atoms.net_wm_window_type_utility)
        {
            return true;
        }
    }

    return true;
}

/// Check if a window is minimized (has _NET_WM_STATE_HIDDEN)
pub fn isWindowMinimized(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) bool {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_state, xcb.XCB_ATOM_ATOM, 0, 32);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return false;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return false;
    }

    const data: [*]const xcb.xcb_atom_t = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const count = @as(usize, @intCast(len)) / @sizeOf(xcb.xcb_atom_t);

    for (data[0..count]) |state| {
        if (state == atoms.net_wm_state_hidden) {
            return true;
        }
    }

    return false;
}

/// Get the current virtual desktop number from root window
pub fn getCurrentDesktop(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t, atoms: Atoms) ?u32 {
    const cookie = xcb.xcb_get_property(conn, 0, root, atoms.net_current_desktop, xcb.XCB_ATOM_CARDINAL, 0, 1);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return null;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len < @sizeOf(u32)) {
        return null;
    }

    const data: *const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return data.*;
}

/// Get the desktop number a window is on (0xFFFFFFFF means "all desktops")
pub fn getWindowDesktop(conn: *xcb.xcb_connection_t, window: xcb.xcb_window_t, atoms: Atoms) ?u32 {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_desktop, xcb.XCB_ATOM_CARDINAL, 0, 1);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return null;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len < @sizeOf(u32)) {
        return null;
    }

    const data: *const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return data.*;
}

/// Check if a window is on the current desktop (or on all desktops)
pub fn isWindowOnCurrentDesktop(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    root: xcb.xcb_window_t,
    atoms: Atoms,
) bool {
    if (!FILTER_BY_CURRENT_DESKTOP) {
        return true;
    }

    const current_desktop = getCurrentDesktop(conn, root, atoms) orelse return true;
    const window_desktop = getWindowDesktop(conn, window, atoms) orelse return true;

    // 0xFFFFFFFF means window is on all desktops (sticky)
    if (window_desktop == 0xFFFFFFFF) {
        return true;
    }

    return window_desktop == current_desktop;
}

pub fn getMousePosition(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) MousePosition {
    const cookie = xcb.xcb_query_pointer(conn, root);
    const reply = xcb.xcb_query_pointer_reply(conn, cookie, null);
    if (reply == null) {
        return MousePosition{ .x = 0, .y = 0 };
    }
    defer std.c.free(reply);
    return MousePosition{
        .x = reply.*.root_x,
        .y = reply.*.root_y,
    };
}

pub fn captureRawImage(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    title: []const u8,
) X11Error!RawCapture {
    // Redirect this specific window
    const redirect_cookie = xcb.xcb_composite_redirect_window_checked(conn, window, xcb.XCB_COMPOSITE_REDIRECT_AUTOMATIC);
    const redirect_error = xcb.xcb_request_check(conn, redirect_cookie);
    if (redirect_error != null) {
        log.warn("xcb_composite_redirect_window failed for {d}: error_code={d}", .{
            window,
            redirect_error.*.error_code,
        });
        std.c.free(redirect_error);
    }

    // Get window geometry
    const geom_cookie = xcb.xcb_get_geometry(conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(conn, geom_cookie, null);
    if (geom_reply == null) {
        return X11Error.GeometryFetchFailed;
    }
    defer std.c.free(geom_reply);

    const width = geom_reply.*.width;
    const height = geom_reply.*.height;

    if (width == 0 or height == 0) {
        return X11Error.ImageCaptureFailed;
    }

    // Get pixmap for window using Composite
    const pixmap = xcb.xcb_generate_id(conn);
    const name_cookie = xcb.xcb_composite_name_window_pixmap_checked(conn, window, pixmap);
    const name_error = xcb.xcb_request_check(conn, name_cookie);
    if (name_error != null) {
        std.c.free(name_error);
        return X11Error.PixmapCreationFailed;
    }
    defer _ = xcb.xcb_free_pixmap(conn, pixmap);

    // Get image from pixmap
    const image_cookie = xcb.xcb_get_image(
        conn,
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
        pixmap,
        0,
        0,
        width,
        height,
        ~@as(u32, 0),
    );

    var error_ptr: ?*xcb.xcb_generic_error_t = null;
    var image_reply = xcb.xcb_get_image_reply(conn, image_cookie, &error_ptr);

    if (image_reply == null) {
        if (error_ptr != null) {
            std.c.free(error_ptr);
        }
        // Try fallback: get image directly from window
        const fallback_cookie = xcb.xcb_get_image(
            conn,
            xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
            window,
            0,
            0,
            width,
            height,
            ~@as(u32, 0),
        );
        var fallback_error: ?*xcb.xcb_generic_error_t = null;
        image_reply = xcb.xcb_get_image_reply(conn, fallback_cookie, &fallback_error);
        if (image_reply == null) {
            if (fallback_error != null) {
                std.c.free(fallback_error);
            }
            return X11Error.ImageCaptureFailed;
        }
    }
    defer std.c.free(image_reply);

    const image_data_len = xcb.xcb_get_image_data_length(image_reply);
    const image_data: [*]const u8 = @ptrCast(xcb.xcb_get_image_data(image_reply));
    const depth = image_reply.?.*.depth;

    // Copy the raw data to our buffer
    const data = try allocator.alloc(u8, @intCast(image_data_len));
    errdefer allocator.free(data);
    @memcpy(data, image_data[0..@intCast(image_data_len)]);

    return RawCapture{
        .window_id = window,
        .title = title,
        .width = width,
        .height = height,
        .data = data,
        .depth = depth,
        .allocator = allocator,
    };
}

/// Get the PID of the process that owns a window (uncached version)
fn getWindowPidUncached(conn: *xcb.xcb_connection_t, window: xcb.xcb_window_t, atoms: Atoms) ?std.posix.pid_t {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_pid, xcb.XCB_ATOM_CARDINAL, 0, 1);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return null;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len < @sizeOf(u32)) {
        return null;
    }

    const data: *const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return @intCast(data.*);
}

/// Get the PID of the process that owns a window (cached version)
pub fn getWindowPid(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
    cache: ?*PidCache,
) ?std.posix.pid_t {
    // Check cache first
    if (cache) |c| {
        if (c.get(window)) |pid| {
            return pid;
        }
    }

    // Query X11
    const pid = getWindowPidUncached(conn, window, atoms) orelse return null;

    // Store in cache
    if (cache) |c| {
        c.put(window, pid);
    }

    return pid;
}

/// Check if a window was spawned by the current executable
/// Compares the executable path of the window's process with the current process
pub fn isCurrentExecutable(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
    pidCache: ?*PidCache,
) bool {
    const window_pid = getWindowPid(conn, window, atoms, pidCache) orelse return false;
    const current_pid = getCurrentPid();

    // Quick check: same PID means same process
    if (window_pid == current_pid) {
        return true;
    }

    return false;
}

// === Key Grab Infrastructure ===

/// Grab Alt+Tab and Alt+Shift+Tab passively on the root window.
/// Each combo needs 4 grabs for NumLock/CapsLock variants.
pub fn grabAltTab(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) void {
    const key_symbols = xcb.xcb_key_symbols_alloc(conn);
    if (key_symbols == null) {
        log.err("Failed to allocate key symbols", .{});
        return;
    }
    defer xcb.xcb_key_symbols_free(key_symbols);

    // Modifier variants: bare, +CapsLock, +NumLock, +CapsLock+NumLock
    const lock_variants = [_]u16{
        0,
        MOD_LOCK,
        MOD_MOD2,
        MOD_LOCK | MOD_MOD2,
    };

    // Grab Alt+Tab (4 lock variants)
    const tab_codes = xcb.xcb_key_symbols_get_keycode(key_symbols, XK_Tab);
    if (tab_codes) |codes| {
        defer std.c.free(codes);
        var i: usize = 0;
        while (codes[i] != 0) : (i += 1) {
            for (lock_variants) |lock| {
                _ = xcb.xcb_grab_key(conn, 1, root, MOD_ALT | lock, codes[i], xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
                // Also grab Alt+Shift+Tab
                _ = xcb.xcb_grab_key(conn, 1, root, MOD_ALT | MOD_SHIFT | lock, codes[i], xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            }
        }
    }

    // Grab Alt+Shift+ISO_Left_Tab (some keyboards send this instead of Shift+Tab)
    const shift_tab_codes = xcb.xcb_key_symbols_get_keycode(key_symbols, XK_ISO_Left_Tab);
    if (shift_tab_codes) |codes| {
        defer std.c.free(codes);
        var i: usize = 0;
        while (codes[i] != 0) : (i += 1) {
            for (lock_variants) |lock| {
                _ = xcb.xcb_grab_key(conn, 1, root, MOD_ALT | lock, codes[i], xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
                _ = xcb.xcb_grab_key(conn, 1, root, MOD_ALT | MOD_SHIFT | lock, codes[i], xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC);
            }
        }
    }

    _ = xcb.xcb_flush(conn);
    log.info("Alt+Tab grabbed", .{});
}

/// Release all passive Alt+Tab key grabs.
pub fn ungrabAltTab(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) void {
    const key_symbols = xcb.xcb_key_symbols_alloc(conn);
    if (key_symbols == null) return;
    defer xcb.xcb_key_symbols_free(key_symbols);

    const lock_variants = [_]u16{
        0,
        MOD_LOCK,
        MOD_MOD2,
        MOD_LOCK | MOD_MOD2,
    };

    const tab_codes = xcb.xcb_key_symbols_get_keycode(key_symbols, XK_Tab);
    if (tab_codes) |codes| {
        defer std.c.free(codes);
        var i: usize = 0;
        while (codes[i] != 0) : (i += 1) {
            for (lock_variants) |lock| {
                _ = xcb.xcb_ungrab_key(conn, codes[i], root, MOD_ALT | lock);
                _ = xcb.xcb_ungrab_key(conn, codes[i], root, MOD_ALT | MOD_SHIFT | lock);
            }
        }
    }

    const shift_tab_codes = xcb.xcb_key_symbols_get_keycode(key_symbols, XK_ISO_Left_Tab);
    if (shift_tab_codes) |codes| {
        defer std.c.free(codes);
        var i: usize = 0;
        while (codes[i] != 0) : (i += 1) {
            for (lock_variants) |lock| {
                _ = xcb.xcb_ungrab_key(conn, codes[i], root, MOD_ALT | lock);
                _ = xcb.xcb_ungrab_key(conn, codes[i], root, MOD_ALT | MOD_SHIFT | lock);
            }
        }
    }

    _ = xcb.xcb_flush(conn);
    log.info("Alt+Tab ungrabbed", .{});
}

/// Actively grab the keyboard so ALL key events go to us during switching.
pub fn grabKeyboard(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) bool {
    const cookie = xcb.xcb_grab_keyboard(
        conn,
        1, // owner_events
        root,
        0, // XCB_CURRENT_TIME
        xcb.XCB_GRAB_MODE_ASYNC,
        xcb.XCB_GRAB_MODE_ASYNC,
    );
    const reply = xcb.xcb_grab_keyboard_reply(conn, cookie, null);
    if (reply == null) {
        log.err("Failed to grab keyboard (no reply)", .{});
        return false;
    }
    defer std.c.free(reply);

    if (reply.*.status != 0) { // XCB_GRAB_STATUS_SUCCESS
        log.err("Failed to grab keyboard: status={d}", .{reply.*.status});
        return false;
    }

    log.debug("Keyboard grabbed", .{});
    return true;
}

/// Release the active keyboard grab.
pub fn ungrabKeyboard(conn: *xcb.xcb_connection_t) void {
    _ = xcb.xcb_ungrab_keyboard(conn, 0); // XCB_CURRENT_TIME
    _ = xcb.xcb_flush(conn);
    log.debug("Keyboard ungrabbed", .{});
}

/// Activate a window using _NET_ACTIVE_WINDOW client message.
pub fn activateWindow(
    conn: *xcb.xcb_connection_t,
    root: xcb.xcb_window_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) void {
    var event: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = window;
    event.type = atoms.net_active_window;
    event.data.data32[0] = 2; // Source indication: pager
    event.data.data32[1] = 0; // XCB_CURRENT_TIME
    event.data.data32[2] = 0; // Currently active window (0 = none)

    const mask: u32 = @bitCast(@as(c_int, xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT));
    _ = xcb.xcb_send_event(
        conn,
        0,
        root,
        mask,
        @ptrCast(&event),
    );
    _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_flush(conn);
    log.debug("Activated window {d}", .{window});
}

/// Get the stacking window list (_NET_CLIENT_LIST_STACKING) as an owned slice.
/// Caller must free the returned slice with the provided allocator.
pub fn getStackingWindowList(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    root: xcb.xcb_window_t,
    atoms: Atoms,
) ![]xcb.xcb_window_t {
    const cookie = xcb.xcb_get_property(
        conn,
        0,
        root,
        atoms.net_client_list_stacking,
        xcb.XCB_ATOM_WINDOW,
        0,
        1024,
    );
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return X11Error.PropertyFetchFailed;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return allocator.alloc(xcb.xcb_window_t, 0);
    }

    const data: [*]const xcb.xcb_window_t = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const count = @as(usize, @intCast(len)) / @sizeOf(xcb.xcb_window_t);

    // Copy to owned slice (XCB reply buffer will be freed)
    const result = try allocator.alloc(xcb.xcb_window_t, count);
    @memcpy(result, data[0..count]);
    return result;
}

/// Convert a keycode to a keysym using xcb-keysyms.
pub fn keycodeToKeysym(conn: *xcb.xcb_connection_t, keycode: xcb.xcb_keycode_t, col: u16) xcb.xcb_keysym_t {
    const key_symbols = xcb.xcb_key_symbols_alloc(conn);
    if (key_symbols == null) return 0;
    defer xcb.xcb_key_symbols_free(key_symbols);
    return xcb.xcb_key_symbols_get_keysym(key_symbols, keycode, @intCast(col));
}

/// Get the XCB connection file descriptor for polling.
pub fn getXcbFd(conn: *xcb.xcb_connection_t) std.posix.fd_t {
    return xcb.xcb_get_file_descriptor(conn);
}

/// Raw icon data from _NET_WM_ICON (ARGB u32 pixels)
pub const IconData = struct {
    data: []u32,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IconData) void {
        self.allocator.free(self.data);
    }
};

/// Get the WM_CLASS of a window (returns the class name, the second null-terminated string).
/// Caller must free the returned slice if it is not "(unknown)".
pub fn getWindowClass(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) []const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.wm_class, xcb.XCB_ATOM_STRING, 0, 256);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return "(unknown)";
    }
    defer std.c.free(reply);

    const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
    if (len == 0) {
        return "(unknown)";
    }

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const bytes = data[0..len];

    // WM_CLASS is two null-terminated strings: instance\0class\0
    // Find the first null to skip instance name
    var first_null: ?usize = null;
    for (bytes, 0..) |b, i| {
        if (b == 0) {
            first_null = i;
            break;
        }
    }

    if (first_null) |pos| {
        if (pos + 1 < len) {
            const class_start = pos + 1;
            // Find end of class string (next null or end of data)
            var class_end = class_start;
            while (class_end < len and bytes[class_end] != 0) {
                class_end += 1;
            }
            if (class_end > class_start) {
                return allocator.dupe(u8, bytes[class_start..class_end]) catch "(unknown)";
            }
        }
    }

    return "(unknown)";
}

/// Get the best icon from _NET_WM_ICON closest to target_size.
/// Returns null if no icon is available. Caller owns the returned IconData.
pub fn getWindowIcon(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
    target_size: u32,
) ?IconData {
    // _NET_WM_ICON can be very large (multiple icons at various sizes)
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_icon, xcb.XCB_ATOM_CARDINAL, 0, 65536);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return null;
    }
    defer std.c.free(reply);

    const byte_len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
    const u32_count = byte_len / @sizeOf(u32);
    if (u32_count < 3) { // Need at least width + height + 1 pixel
        return null;
    }

    const data: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const values = data[0..u32_count];

    // Walk through icon entries to find the one closest to target_size
    var best_offset: ?usize = null;
    var best_width: u32 = 0;
    var best_height: u32 = 0;
    var best_diff: u32 = std.math.maxInt(u32);

    var offset: usize = 0;
    while (offset + 2 <= u32_count) {
        const w = values[offset];
        const h = values[offset + 1];
        const pixel_count: usize = @as(usize, w) * @as(usize, h);

        if (w == 0 or h == 0 or offset + 2 + pixel_count > u32_count) {
            break;
        }

        // Prefer closest to target, favor larger over smaller
        const size = @max(w, h);
        const diff = if (size >= target_size) size - target_size else (target_size - size) * 2;
        if (best_offset == null or diff < best_diff) {
            best_offset = offset;
            best_width = w;
            best_height = h;
            best_diff = diff;
        }

        offset += 2 + pixel_count;
    }

    if (best_offset) |bo| {
        const pixel_count: usize = @as(usize, best_width) * @as(usize, best_height);
        const icon_pixels = allocator.alloc(u32, pixel_count) catch return null;
        @memcpy(icon_pixels, values[bo + 2 .. bo + 2 + pixel_count]);
        return IconData{
            .data = icon_pixels,
            .width = best_width,
            .height = best_height,
            .allocator = allocator,
        };
    }

    return null;
}
