const std = @import("std");
const x11 = @import("x11.zig");

const stb = @cImport({
    @cInclude("stb_image_resize2.h");
});

pub const Thumbnail = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Thumbnail) void {
        self.allocator.free(self.data);
    }
};

pub const ICON_SIZE: u32 = 64;

/// Process an ARGB u32 icon (from _NET_WM_ICON) into an RGBA thumbnail resized to ICON_SIZE x ICON_SIZE.
pub fn processIconArgb(icon_data: []const u32, src_width: u32, src_height: u32, allocator: std.mem.Allocator) !Thumbnail {
    const pixel_count: usize = @as(usize, src_width) * @as(usize, src_height);

    // Convert ARGB u32 to RGBA u8
    const src_rgba = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(src_rgba);

    for (0..pixel_count) |i| {
        const argb = icon_data[i];
        const a: u8 = @truncate(argb >> 24);
        const r: u8 = @truncate(argb >> 16);
        const g: u8 = @truncate(argb >> 8);
        const b: u8 = @truncate(argb);
        src_rgba[i * 4 + 0] = r;
        src_rgba[i * 4 + 1] = g;
        src_rgba[i * 4 + 2] = b;
        src_rgba[i * 4 + 3] = a;
    }

    // Resize to ICON_SIZE x ICON_SIZE
    const out_data = try allocator.alloc(u8, ICON_SIZE * ICON_SIZE * 4);
    errdefer allocator.free(out_data);

    const result = stb.stbir_resize_uint8_linear(
        src_rgba.ptr,
        @intCast(src_width),
        @intCast(src_height),
        @intCast(src_width * 4),
        out_data.ptr,
        @intCast(ICON_SIZE),
        @intCast(ICON_SIZE),
        @intCast(ICON_SIZE * 4),
        stb.STBIR_RGBA,
    );

    if (result == null) {
        return x11.X11Error.ImageCaptureFailed;
    }

    return Thumbnail{
        .data = out_data,
        .width = ICON_SIZE,
        .height = ICON_SIZE,
        .allocator = allocator,
    };
}
