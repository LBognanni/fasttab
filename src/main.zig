const std = @import("std");
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
    @cInclude("xcb/xcb_image.h");
});
const stb = @cImport({
    @cInclude("stb_image_write.h");
});
const rl = @cImport({
    @cInclude("raylib.h");
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
    net_wm_window_type: xcb.xcb_atom_t,
    net_wm_window_type_normal: xcb.xcb_atom_t,
    net_wm_window_type_desktop: xcb.xcb_atom_t,
    net_wm_window_type_dock: xcb.xcb_atom_t,
    net_wm_window_type_dialog: xcb.xcb_atom_t,
    net_wm_window_type_utility: xcb.xcb_atom_t,
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
        .net_wm_window_type = try internAtom(conn, "_NET_WM_WINDOW_TYPE"),
        .net_wm_window_type_normal = try internAtom(conn, "_NET_WM_WINDOW_TYPE_NORMAL"),
        .net_wm_window_type_desktop = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DESKTOP"),
        .net_wm_window_type_dock = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK"),
        .net_wm_window_type_dialog = try internAtom(conn, "_NET_WM_WINDOW_TYPE_DIALOG"),
        .net_wm_window_type_utility = try internAtom(conn, "_NET_WM_WINDOW_TYPE_UTILITY"),
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

fn shouldShowWindow(
    conn: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    atoms: Atoms,
) bool {
    // Get _NET_WM_WINDOW_TYPE property
    const cookie = xcb.xcb_get_property(conn, 0, window, atoms.net_wm_window_type, xcb.XCB_ATOM_ATOM, 0, 32);
    const reply = xcb.xcb_get_property_reply(conn, cookie, null);
    if (reply == null) {
        // No window type set - treat as normal window
        return true;
    }
    defer std.c.free(reply);

    const len = xcb.xcb_get_property_value_length(reply);
    if (len == 0) {
        // No window type set - treat as normal window
        return true;
    }

    const data: [*]const xcb.xcb_atom_t = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    const count = @as(usize, @intCast(len)) / @sizeOf(xcb.xcb_atom_t);

    // Check each type - skip desktop, dock windows
    for (data[0..count]) |window_type| {
        if (window_type == atoms.net_wm_window_type_desktop) {
            return false; // Desktop background
        }
        if (window_type == atoms.net_wm_window_type_dock) {
            return false; // Panels, docks (plasmashell)
        }
        if (window_type == atoms.net_wm_window_type_normal or
            window_type == atoms.net_wm_window_type_dialog or
            window_type == atoms.net_wm_window_type_utility)
        {
            return true; // Normal application windows
        }
    }

    // Unknown type - show it
    return true;
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

const MousePosition = struct {
    x: i32,
    y: i32,
};

fn getMousePosition(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) MousePosition {
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

const Thumbnail = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Thumbnail) void {
        self.allocator.free(self.data);
    }
};

// Visual design constants from spec
const THUMBNAIL_HEIGHT: u32 = 100;
const SPACING: u32 = 12;
const PADDING: u32 = 16;
const CORNER_RADIUS: f32 = 12.0;
const ITEM_CORNER_RADIUS: f32 = 4.0;
const MAX_GRID_WIDTH: u32 = 1820;
const MAX_GRID_HEIGHT: u32 = 980;
const TITLE_FONT_SIZE: i32 = 14;
const TITLE_SPACING: u32 = 8;
const SELECTION_BORDER: u32 = 3;
const BACKGROUND_COLOR = rl.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 217 }; // #222222 @ 85%
const HIGHLIGHT_COLOR = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 255 }; // KDE accent blue #3daee9
const TITLE_COLOR = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

// Item holding window data for rendering
const WindowItem = struct {
    id: xcb.xcb_window_t,
    title: []const u8,
    thumbnail: Thumbnail,
    texture: rl.Texture2D,
    // Scaled dimensions for display
    display_width: u32,
    display_height: u32,
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

// Grid layout calculation
const GridLayout = struct {
    columns: u32,
    rows: u32,
    item_height: u32, // Scaled thumbnail height for display
    total_width: u32,
    total_height: u32,
};

fn calculateItemWidth(thumb_width: u32, thumb_height: u32, target_height: u32) u32 {
    if (thumb_height == 0) return target_height; // Fallback for invalid thumbnails
    const aspect_ratio = @as(f32, @floatFromInt(thumb_width)) / @as(f32, @floatFromInt(thumb_height));
    const width = @as(f32, @floatFromInt(target_height)) * aspect_ratio;
    if (width < 1.0) return 1;
    return @intFromFloat(width);
}

fn calculateGridLayout(items: []WindowItem, target_height: u32) GridLayout {
    if (items.len == 0) {
        return GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = target_height,
            .total_width = PADDING * 2,
            .total_height = PADDING * 2,
        };
    }

    // Calculate display dimensions for each item at target height
    var max_item_width: u32 = 0;
    var total_item_width: u32 = 0;
    for (items) |*item| {
        item.display_height = target_height;
        item.display_width = calculateItemWidth(item.thumbnail.width, item.thumbnail.height, target_height);
        if (item.display_width > max_item_width) {
            max_item_width = item.display_width;
        }
        total_item_width += item.display_width;
    }

    // Item height includes thumbnail + spacing + title
    const item_full_height = target_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    // Try to find optimal column count that fits within MAX_GRID_WIDTH
    var best_columns: u32 = 1;
    var best_rows: u32 = @intCast(items.len);

    // Try different column counts
    var cols: u32 = 1;
    while (cols <= items.len) : (cols += 1) {
        const rows = (items.len + cols - 1) / cols;

        // Estimate width: use average item width * columns + spacing + padding
        const avg_width = total_item_width / @as(u32, @intCast(items.len));
        const estimated_width = PADDING * 2 + cols * avg_width + (cols - 1) * SPACING;
        const estimated_height = PADDING * 2 + @as(u32, @intCast(rows)) * item_full_height + (@as(u32, @intCast(rows)) - 1) * SPACING;

        if (estimated_width <= MAX_GRID_WIDTH and estimated_height <= MAX_GRID_HEIGHT) {
            best_columns = cols;
            best_rows = @intCast(rows);
        } else if (estimated_width > MAX_GRID_WIDTH) {
            break;
        }
    }

    // Calculate actual dimensions - find max row width across all rows
    var max_row_width: u32 = 0;
    var row_start: u32 = 0;
    while (row_start < items.len) {
        const items_in_row = @min(best_columns, @as(u32, @intCast(items.len)) - row_start);
        const row_width = calculateRowWidth(items, row_start, items_in_row);
        if (row_width > max_row_width) {
            max_row_width = row_width;
        }
        row_start += best_columns;
    }
    const total_width = PADDING * 2 + max_row_width;
    const total_height = PADDING * 2 + best_rows * item_full_height + (best_rows - 1) * SPACING;

    return GridLayout{
        .columns = best_columns,
        .rows = best_rows,
        .item_height = target_height,
        .total_width = total_width,
        .total_height = total_height,
    };
}

fn calculateRowWidth(items: []WindowItem, start_idx: u32, count: u32) u32 {
    var width: u32 = 0;
    const end = @min(start_idx + count, @as(u32, @intCast(items.len)));
    var i = start_idx;
    while (i < end) : (i += 1) {
        width += items[i].display_width;
        if (i < end - 1) {
            width += SPACING;
        }
    }
    return width;
}

fn loadTextureFromThumbnail(thumbnail: *const Thumbnail) rl.Texture2D {
    const image = rl.Image{
        .data = thumbnail.data.ptr,
        .width = @intCast(thumbnail.width),
        .height = @intCast(thumbnail.height),
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        .mipmaps = 1,
    };
    const texture = rl.LoadTextureFromImage(image);
    // Enable bilinear filtering for smooth thumbnail scaling
    rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_BILINEAR);
    return texture;
}

// Try to load a system font with bilinear filtering for smooth rendering
fn loadSystemFont(size: i32) rl.Font {
    // Try common Linux font paths
    const font_paths = [_][*c]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
    };

    for (font_paths) |path| {
        const font = rl.LoadFontEx(path, size, null, 0);
        if (font.texture.id != 0) {
            // Enable bilinear filtering for smooth font rendering
            rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
            return font;
        }
    }

    // Fall back to default font
    return rl.GetFontDefault();
}

// Truncate text to fit within max_width, adding ellipsis if needed
fn drawTruncatedText(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color) void {
    const spacing: f32 = 0;
    var text_buf: [256]u8 = undefined;
    const ellipsis = "...";

    // Ensure null-terminated string
    const len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..len], text[0..len]);
    text_buf[len] = 0;

    const text_ptr: [*c]const u8 = &text_buf;
    const text_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);

    if (text_size.x <= max_width) {
        // Text fits, draw centered
        const text_x = x + (max_width - text_size.x) / 2.0;
        rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = text_x, .y = y }, font_size, spacing, color);
        return;
    }

    // Text too long, truncate with ellipsis
    const ellipsis_size = rl.MeasureTextEx(font, ellipsis, font_size, spacing);
    const available_width = max_width - ellipsis_size.x;

    // Find how many characters fit
    var fit_len: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const saved_char = text_buf[i + 1];
        text_buf[i + 1] = 0; // Temporarily null-terminate at this position
        const partial_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
        text_buf[i + 1] = saved_char; // Restore
        if (partial_size.x > available_width) break;
        fit_len = i + 1;
    }

    // Build truncated string with ellipsis
    if (fit_len > 0) {
        @memcpy(text_buf[fit_len .. fit_len + 3], ellipsis);
        text_buf[fit_len + 3] = 0;
    } else {
        @memcpy(text_buf[0..3], ellipsis);
        text_buf[3] = 0;
    }

    const final_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
    const text_x = x + (max_width - final_size.x) / 2.0;
    rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = text_x, .y = y }, font_size, spacing, color);
}

fn renderSwitcher(items: []WindowItem, selected_index: usize, font: rl.Font) void {
    if (items.len == 0) return;

    // Calculate layout
    var layout = calculateGridLayout(items, THUMBNAIL_HEIGHT);

    // If it doesn't fit, try smaller thumbnail heights
    var current_height = THUMBNAIL_HEIGHT;
    while (layout.total_height > MAX_GRID_HEIGHT and current_height > 60) {
        current_height -= 10;
        layout = calculateGridLayout(items, current_height);
    }

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    // Draw background
    const bg_rect = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(layout.total_width),
        .height = @floatFromInt(layout.total_height),
    };
    rl.DrawRectangleRounded(bg_rect, CORNER_RADIUS / @as(f32, @floatFromInt(@max(layout.total_width, layout.total_height))), 16, BACKGROUND_COLOR);

    // Draw items in grid
    var item_idx: usize = 0;
    var row: u32 = 0;
    while (row < layout.rows and item_idx < items.len) : (row += 1) {
        // Calculate how many items in this row
        const items_in_row = @min(layout.columns, @as(u32, @intCast(items.len)) - @as(u32, @intCast(item_idx)));

        // Calculate row width for centering
        const row_width = calculateRowWidth(items, @intCast(item_idx), items_in_row);
        var x: f32 = @floatFromInt(PADDING + (layout.total_width - 2 * PADDING - row_width) / 2);
        const y: f32 = @floatFromInt(PADDING + row * (item_full_height + SPACING));

        var col: u32 = 0;
        while (col < items_in_row) : (col += 1) {
            const item = &items[item_idx];
            const is_selected = item_idx == selected_index;

            // Draw selection highlight
            if (is_selected) {
                const highlight_rect = rl.Rectangle{
                    .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                    .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
                };
                rl.DrawRectangleRounded(highlight_rect, ITEM_CORNER_RADIUS / @as(f32, @floatFromInt(@max(item.display_width, item_full_height))), 8, HIGHLIGHT_COLOR);
            }

            // Draw thumbnail (scaled)
            const dest_rect = rl.Rectangle{
                .x = x,
                .y = y,
                .width = @floatFromInt(item.display_width),
                .height = @floatFromInt(item.display_height),
            };
            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.texture.width),
                .height = @floatFromInt(item.texture.height),
            };
            rl.DrawTexturePro(item.texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);

            // Draw title (truncated with ellipsis if too long)
            const title_y = y + @as(f32, @floatFromInt(item.display_height + TITLE_SPACING));
            drawTruncatedText(font, item.title, x, title_y, @floatFromInt(TITLE_FONT_SIZE), @floatFromInt(item.display_width), TITLE_COLOR);

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
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

    // Capture thumbnails for all windows
    var items = std.ArrayList(WindowItem).init(allocator);
    defer {
        for (items.items) |*item| {
            // Note: textures are unloaded manually before CloseWindow()
            item.thumbnail.deinit();
            if (!std.mem.eql(u8, item.title, "(unknown)")) {
                allocator.free(item.title);
            }
        }
        items.deinit();
    }

    try stdout.print("Scanning {d} windows...\n", .{windows.len});

    for (windows) |window_id| {
        // Filter out desktop, dock, and other non-application windows
        if (!shouldShowWindow(conn.?, window_id, atoms)) {
            continue;
        }

        const title = getWindowTitle(allocator, conn.?, window_id, atoms);
        errdefer if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);

        var thumbnail = captureWindowThumbnail(allocator, conn.?, window_id) catch |err| {
            log.warn("Failed to capture thumbnail for window {d}: {}", .{ window_id, err });
            if (!std.mem.eql(u8, title, "(unknown)")) allocator.free(title);
            continue;
        };
        errdefer thumbnail.deinit();

        try stdout.print("  Captured: {s} ({d}x{d})\n", .{ title, thumbnail.width, thumbnail.height });

        try items.append(WindowItem{
            .id = window_id,
            .title = title,
            .thumbnail = thumbnail,
            .texture = undefined, // Will be set after raylib init
            .display_width = 0,
            .display_height = 0,
        });
    }

    if (items.items.len == 0) {
        try stdout.print("No windows could be captured.\n", .{});
        return;
    }

    // Calculate initial layout to determine window size
    const layout = calculateGridLayout(items.items, THUMBNAIL_HEIGHT);

    try stdout.print("Grid layout: {d} cols x {d} rows, window size: {d}x{d}\n", .{
        layout.columns,
        layout.rows,
        layout.total_width,
        layout.total_height,
    });

    // Get mouse position BEFORE initializing raylib (to find correct monitor)
    const mouse_pos = getMousePosition(conn.?, root);

    // Initialize raylib
    rl.SetConfigFlags(rl.FLAG_WINDOW_UNDECORATED | rl.FLAG_WINDOW_TRANSPARENT | rl.FLAG_WINDOW_TOPMOST);
    rl.SetTraceLogLevel(rl.LOG_WARNING); // Reduce log noise
    rl.InitWindow(@intCast(layout.total_width), @intCast(layout.total_height), "FastTab");

    rl.SetTargetFPS(60);

    // Load system font for better text rendering
    const font = loadSystemFont(TITLE_FONT_SIZE * 2); // Load at 2x for better quality

    // Load textures from thumbnails (must be done after InitWindow)
    for (items.items) |*item| {
        item.texture = loadTextureFromThumbnail(&item.thumbnail);
    }

    // Find monitor containing mouse cursor and center window on it
    const monitor_count = rl.GetMonitorCount();
    var target_monitor: i32 = 0;
    var mon_x: i32 = 0;
    var mon_y: i32 = 0;
    var mon_width: i32 = 1920;
    var mon_height: i32 = 1080;

    var m: i32 = 0;
    while (m < monitor_count) : (m += 1) {
        const mx = rl.GetMonitorPosition(m).x;
        const my = rl.GetMonitorPosition(m).y;
        const mw = rl.GetMonitorWidth(m);
        const mh = rl.GetMonitorHeight(m);

        // Check if mouse is within this monitor
        if (mouse_pos.x >= @as(i32, @intFromFloat(mx)) and
            mouse_pos.x < @as(i32, @intFromFloat(mx)) + mw and
            mouse_pos.y >= @as(i32, @intFromFloat(my)) and
            mouse_pos.y < @as(i32, @intFromFloat(my)) + mh)
        {
            target_monitor = m;
            mon_x = @intFromFloat(mx);
            mon_y = @intFromFloat(my);
            mon_width = mw;
            mon_height = mh;
            break;
        }
    }

    // Center window on the target monitor
    const win_x = mon_x + @divTrunc(mon_width - @as(i32, @intCast(layout.total_width)), 2);
    const win_y = mon_y + @divTrunc(mon_height - @as(i32, @intCast(layout.total_height)), 2);
    rl.SetWindowPosition(win_x, win_y);

    try stdout.print("Mouse at ({d}, {d}), using monitor {d}\n", .{ mouse_pos.x, mouse_pos.y, target_monitor });
    try stdout.print("Displaying {d} windows in switcher. Press ESC or close window to exit.\n", .{items.items.len});

    var selected_index: usize = 0;

    // Main render loop
    while (!rl.WindowShouldClose()) {
        // Handle keyboard input for selection
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_TAB)) {
            selected_index = (selected_index + 1) % items.items.len;
        }
        if (rl.IsKeyPressed(rl.KEY_LEFT)) {
            if (selected_index == 0) {
                selected_index = items.items.len - 1;
            } else {
                selected_index -= 1;
            }
        }
        if (rl.IsKeyPressed(rl.KEY_DOWN)) {
            const cols = layout.columns;
            selected_index = @min(selected_index + cols, items.items.len - 1);
        }
        if (rl.IsKeyPressed(rl.KEY_UP)) {
            const cols = layout.columns;
            if (selected_index >= cols) {
                selected_index -= cols;
            }
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }); // Transparent
        renderSwitcher(items.items, selected_index, font);
        rl.EndDrawing();
    }

    // Unload resources BEFORE closing window (must happen while GL context is valid)
    for (items.items) |*item| {
        rl.UnloadTexture(item.texture);
    }
    rl.UnloadFont(font);

    rl.CloseWindow();
    try stdout.print("Switcher closed.\n", .{});
}
