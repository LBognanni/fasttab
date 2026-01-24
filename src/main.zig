const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_image.h");
});
const stb = @cImport({
    @cInclude("stb_image_write.h");
});

const log = std.log.scoped(.fasttab);

const X11Error = error{
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

fn initComposite(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) X11Error!void {
    _ = root; // Not needed anymore - we redirect individual windows instead

    const cookie = xcb.xcb_composite_query_version(conn, 0, 4);
    const reply = xcb.xcb_composite_query_version_reply(conn, cookie, null);
    if (reply == null) {
        return X11Error.CompositeExtensionMissing;
    }
    defer std.c.free(reply);

    // NOTE: We do NOT redirect root's subwindows here because that conflicts with KWin/compositors.
    // Instead, we redirect each individual window before capturing it.
}

const Thumbnail = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Thumbnail) void {
        self.allocator.free(self.data);
    }
};

fn captureWindowThumbnail(
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
) X11Error!Thumbnail {
    // Redirect this specific window (not root subwindows - that conflicts with KWin)
    const redirect_cookie = xcb.xcb_composite_redirect_window_checked(conn, window, xcb.XCB_COMPOSITE_REDIRECT_AUTOMATIC);
    const redirect_error = xcb.xcb_request_check(conn, redirect_cookie);
    if (redirect_error != null) {
        log.warn("xcb_composite_redirect_window failed for {d}: error_code={d}, major_code={d}, minor_code={d}", .{
            window,
            redirect_error.*.error_code,
            redirect_error.*.major_code,
            redirect_error.*.minor_code,
        });
        std.c.free(redirect_error);
        // Continue anyway - window might already be redirected
    }

    // Get window geometry
    const geom_cookie = xcb.xcb_get_geometry(conn, window);
    const geom_reply = xcb.xcb_get_geometry_reply(conn, geom_cookie, null);
    if (geom_reply == null) {
        log.err("Failed to get geometry for window {d}", .{window});
        return X11Error.GeometryFetchFailed;
    }
    defer std.c.free(geom_reply);

    const width = geom_reply.*.width;
    const height = geom_reply.*.height;

    if (width == 0 or height == 0) {
        log.warn("Window {d} has zero size", .{window});
        return X11Error.ImageCaptureFailed;
    }

    // Get pixmap for window using Composite
    const pixmap = xcb.xcb_generate_id(conn);

    const name_cookie = xcb.xcb_composite_name_window_pixmap_checked(conn, window, pixmap);

    // Check if the name_window_pixmap operation succeeded
    const name_error = xcb.xcb_request_check(conn, name_cookie);
    if (name_error != null) {
        log.err("xcb_composite_name_window_pixmap failed: error_code={d}, major_code={d}, minor_code={d}", .{
            name_error.*.error_code,
            name_error.*.major_code,
            name_error.*.minor_code,
        });
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
    const image_reply = xcb.xcb_get_image_reply(conn, image_cookie, &error_ptr);
    if (image_reply == null) {
        if (error_ptr != null) {
            log.err("xcb_get_image error: error_code={d}, major_code={d}, minor_code={d}, sequence={d}", .{
                error_ptr.?.*.error_code,
                error_ptr.?.*.major_code,
                error_ptr.?.*.minor_code,
                error_ptr.?.*.sequence,
            });
            std.c.free(error_ptr);
        }

        // Try fallback: get image directly from window (may only capture visible parts)
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

        var fallback_error_ptr: ?*xcb.xcb_generic_error_t = null;
        const fallback_reply = xcb.xcb_get_image_reply(conn, fallback_cookie, &fallback_error_ptr);
        if (fallback_reply == null) {
            if (fallback_error_ptr != null) {
                std.c.free(fallback_error_ptr);
            }
            log.err("Failed to capture window {d}", .{window});
            return X11Error.ImageCaptureFailed;
        }

        // Use fallback reply
        defer std.c.free(fallback_reply);

        return captureFromImageReply(allocator, window, width, height, fallback_reply);
    }
    defer std.c.free(image_reply);

    return captureFromImageReply(allocator, window, width, height, image_reply);
}

fn captureFromImageReply(
    allocator: std.mem.Allocator,
    window: xcb.xcb_window_t,
    width: u16,
    height: u16,
    image_reply: *xcb.xcb_get_image_reply_t,
) X11Error!Thumbnail {
    const image_data_len = xcb.xcb_get_image_data_length(image_reply);
    const image_data: [*]const u8 = @ptrCast(xcb.xcb_get_image_data(image_reply));

    // Calculate thumbnail dimensions (target height: 256px)
    const target_height: u32 = 256;
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const thumb_height = target_height;
    const thumb_width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(thumb_height)) * aspect_ratio));

    // Allocate RGBA buffer for thumbnail
    const thumb_data = try allocator.alloc(u8, thumb_width * thumb_height * 4);
    errdefer allocator.free(thumb_data);

    // Get the depth/bpp information
    const depth = image_reply.*.depth;
    const bytes_per_pixel: u32 = if (depth == 24 or depth == 32) 4 else if (depth == 16) 2 else 1;

    // Scale the image (simple nearest-neighbor)
    var out_of_bounds_count: u32 = 0;
    var y: u32 = 0;
    while (y < thumb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < thumb_width) : (x += 1) {
            const src_x = (x * width) / thumb_width;
            const src_y = (y * height) / thumb_height;
            const src_idx = (src_y * width + src_x) * bytes_per_pixel;
            const dst_idx = (y * thumb_width + x) * 4;

            if (src_idx + bytes_per_pixel <= image_data_len) {
                if (bytes_per_pixel == 4) {
                    // BGRA to RGBA
                    thumb_data[dst_idx + 0] = image_data[src_idx + 2]; // R
                    thumb_data[dst_idx + 1] = image_data[src_idx + 1]; // G
                    thumb_data[dst_idx + 2] = image_data[src_idx + 0]; // B
                    thumb_data[dst_idx + 3] = 255; // A
                } else {
                    // Fallback: grayscale or other formats
                    const val = image_data[src_idx];
                    thumb_data[dst_idx + 0] = val;
                    thumb_data[dst_idx + 1] = val;
                    thumb_data[dst_idx + 2] = val;
                    thumb_data[dst_idx + 3] = 255;
                }
            } else {
                // Out of bounds - fill with transparent
                out_of_bounds_count += 1;
                thumb_data[dst_idx + 0] = 0;
                thumb_data[dst_idx + 1] = 0;
                thumb_data[dst_idx + 2] = 0;
                thumb_data[dst_idx + 3] = 0;
            }
        }
    }

    if (out_of_bounds_count > 0) {
        log.warn("Window {d}: {d} pixels were out of bounds during scaling", .{ window, out_of_bounds_count });
    }

    return Thumbnail{
        .data = thumb_data,
        .width = thumb_width,
        .height = thumb_height,
        .allocator = allocator,
    };
}

fn saveThumbnailPNG(thumbnail: Thumbnail, window_id: xcb.xcb_window_t) !void {
    var filename_buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrintZ(&filename_buf, "window_{d}.png", .{window_id});

    const result = stb.stbi_write_png(
        filename.ptr,
        @intCast(thumbnail.width),
        @intCast(thumbnail.height),
        4,
        thumbnail.data.ptr,
        @intCast(thumbnail.width * 4),
    );
    if (result == 0) {
        log.err("Failed to write PNG for window {d}", .{window_id});
        return error.PNGWriteFailed;
    }
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

    // Initialize Composite extension
    try initComposite(conn.?, root);

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

        // Capture and save thumbnail
        var thumbnail = captureWindowThumbnail(allocator, conn.?, window_id) catch |err| {
            log.warn("Failed to capture thumbnail for window {d}: {}", .{ window_id, err });
            continue;
        };
        defer thumbnail.deinit();

        try saveThumbnailPNG(thumbnail, window_id);
        try stdout.print("  Saved thumbnail: window_{d}.png ({d}x{d})\n", .{ window_id, thumbnail.width, thumbnail.height });
    }
}
