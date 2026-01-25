const std = @import("std");

// Feature flags
pub const FILTER_BY_CURRENT_DESKTOP = true;

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_image.h");
});

const log = std.log.scoped(.fasttab);

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
