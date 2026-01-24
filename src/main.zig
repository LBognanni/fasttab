const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const log = std.log.scoped(.fasttab);

const X11Error = error{
    ConnectionFailed,
    ConnectionError,
    AtomNotFound,
    PropertyFetchFailed,
    NoScreen,
};

const Atoms = struct {
    net_client_list: xcb.xcb_atom_t,
    net_wm_name: xcb.xcb_atom_t,
    wm_name: xcb.xcb_atom_t,
    wm_class: xcb.xcb_atom_t,
    utf8_string: xcb.xcb_atom_t,
};

const WindowInfo = struct {
    id: xcb.xcb_window_t,
    title: []const u8,
    class: []const u8,
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

fn initAtoms(conn: *xcb.xcb_connection_t) X11Error!Atoms {
    return Atoms{
        .net_client_list = try internAtom(conn, "_NET_CLIENT_LIST"),
        .net_wm_name = try internAtom(conn, "_NET_WM_NAME"),
        .wm_name = try internAtom(conn, "WM_NAME"),
        .wm_class = try internAtom(conn, "WM_CLASS"),
        .utf8_string = try internAtom(conn, "UTF8_STRING"),
    };
}

fn getWindowList(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t, atoms: Atoms) X11Error![]xcb.xcb_window_t {
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

fn getWindowProperty(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    property: xcb.xcb_atom_t,
    prop_type: xcb.xcb_atom_t,
) ?[]const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, window, property, prop_type, 0, 1024);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return null;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return null;
    }

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    // We need to copy the data since reply will be freed
    return data[0..@intCast(len)];
}

fn getWindowTitle(
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

fn getWindowClass(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) []const u8 {
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.wm_class, xcb.XCB_ATOM_STRING, 0, 1024);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        return "(unknown)";
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        return "(unknown)";
    }

    // WM_CLASS contains two null-terminated strings: instance name and class name
    // We want the class name (second one)
    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const slice = data[0..@intCast(len)];

    // Find the first null terminator
    var i: usize = 0;
    while (i < slice.len and slice[i] != 0) : (i += 1) {}

    // Skip past the null to get to the class name
    if (i + 1 < slice.len) {
        const class_start = i + 1;
        var class_end = class_start;
        while (class_end < slice.len and slice[class_end] != 0) : (class_end += 1) {}
        if (class_end > class_start) {
            return allocator.dupe(u8, slice[class_start..class_end]) catch "(unknown)";
        }
    }

    // If no second string, return the first one (instance name)
    if (i > 0) {
        return allocator.dupe(u8, slice[0..i]) catch "(unknown)";
    }

    return "(unknown)";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Connect to X11
    var screen_num: c_int = 0;
    const conn = xcb.xcb_connect(null, &screen_num);
    if (conn == null) {
        log.err("Failed to connect to X11 server", .{});
        return X11Error.ConnectionFailed;
    }
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) {
        log.err("X11 connection error", .{});
        return X11Error.ConnectionError;
    }

    // Get the screen
    const setup = xcb.xcb_get_setup(conn);
    var iter = xcb.xcb_setup_roots_iterator(setup);

    // Navigate to the correct screen
    var i: c_int = 0;
    while (i < screen_num) : (i += 1) {
        xcb.xcb_screen_next(&iter);
    }
    const screen = iter.data;
    if (screen == null) {
        return X11Error.NoScreen;
    }
    const root = screen.*.root;

    // Initialize atoms
    const atoms = try initAtoms(conn.?);

    // Get window list
    const windows = try getWindowList(conn.?, root, atoms);

    if (windows.len == 0) {
        try stdout.print("No windows found.\n", .{});
        return;
    }

    // Print each window's info
    for (windows) |window_id| {
        const title = getWindowTitle(allocator, conn.?, window_id, atoms);
        defer if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);

        const class = getWindowClass(allocator, conn.?, window_id, atoms);
        defer if (!std.mem.eql(u8, class, "(unknown)")) allocator.free(class);

        try stdout.print("Window ID: {d}\n", .{window_id});
        try stdout.print("  Title: {s}\n", .{title});
        try stdout.print("  Class: {s}\n", .{class});
    }
}
