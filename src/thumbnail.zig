const std = @import("std");
const x11 = @import("x11.zig");
const color = @import("color.zig");

const stb = @cImport({
    @cInclude("stb_image_resize2.h");
});

const log = std.log.scoped(.fasttab);

pub const Thumbnail = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Thumbnail) void {
        self.allocator.free(self.data);
    }
};

// Process raw capture into thumbnail
pub fn processRawCapture(capture: *const x11.RawCapture, allocator: std.mem.Allocator) !Thumbnail {
    const width = capture.width;
    const height = capture.height;
    const bytes_per_pixel: u32 = if (capture.depth == 24 or capture.depth == 32) 4 else if (capture.depth == 16) 2 else 1;

    // Calculate thumbnail dimensions (target height: 256px)
    const target_height: u32 = 256;
    const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const thumb_height = target_height;
    const thumb_width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(thumb_height)) * aspect_ratio));

    // Allocate output buffer for resized thumbnail
    const thumb_data = try allocator.alloc(u8, thumb_width * thumb_height * 4);
    defer allocator.free(thumb_data); // Always free - this is intermediate storage

    // Use stb_image_resize2 for high-quality scaling
    const result = stb.stbir_resize_uint8_linear(
        capture.data.ptr,
        @intCast(width),
        @intCast(height),
        @intCast(@as(u32, width) * 4),
        thumb_data.ptr,
        @intCast(thumb_width),
        @intCast(thumb_height),
        @intCast(thumb_width * 4),
        stb.STBIR_RGBA,
    );

    if (result == null) {
        return x11.X11Error.ImageCaptureFailed;
    }

    // Allocate buffer for RGBA conversion of destination image
    const pixel_count: usize = @as(usize, thumb_width) * @as(usize, thumb_height);
    const dest_rgba = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(dest_rgba);

    // Convert BGRA to RGBA using SIMD (if 32-bit depth)
    if (bytes_per_pixel == 4 and thumb_data.len >= pixel_count * 4) {
        color.convertBgraToRgbaSimd(thumb_data[0 .. pixel_count * 4], dest_rgba);
    } else {
        // Fallback for non-32bit formats
        var i: usize = 0;
        while (i < pixel_count) : (i += 1) {
            const src_idx = i * bytes_per_pixel;
            const dst_idx = i * 4;
            if (src_idx + bytes_per_pixel <= thumb_data.len) {
                if (bytes_per_pixel == 4) {
                    dest_rgba[dst_idx + 0] = thumb_data[src_idx + 2];
                    dest_rgba[dst_idx + 1] = thumb_data[src_idx + 1];
                    dest_rgba[dst_idx + 2] = thumb_data[src_idx + 0];
                    dest_rgba[dst_idx + 3] = 255;
                } else {
                    const val = thumb_data[src_idx];
                    dest_rgba[dst_idx + 0] = val;
                    dest_rgba[dst_idx + 1] = val;
                    dest_rgba[dst_idx + 2] = val;
                    dest_rgba[dst_idx + 3] = 255;
                }
            } else {
                @memset(dest_rgba[dst_idx..][0..4], 0);
            }
        }
    }

    return Thumbnail{
        .data = dest_rgba,
        .width = thumb_width,
        .height = thumb_height,
        .allocator = allocator,
    };
}

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
