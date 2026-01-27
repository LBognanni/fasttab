const std = @import("std");

// SIMD-accelerated BGRA to RGBA conversion
// Processes 4 pixels (16 bytes) at a time using vector operations
pub fn convertBgraToRgbaSimd(src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len);
    std.debug.assert(src.len % 4 == 0);

    const pixel_count = src.len / 4;
    const simd_pixels = pixel_count / 4;
    const remaining_pixels = pixel_count % 4;

    // SIMD shuffle mask: BGRA -> RGBA
    const shuffle_mask = @Vector(16, i8){
        2,  1,  0,  3,
        6,  5,  4,  7,
        10, 9,  8,  11,
        14, 13, 12, 15,
    };

    const alpha_mask: @Vector(16, u8) = .{ 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    const alpha_select: @Vector(16, bool) = .{ false, false, false, true, false, false, false, true, false, false, false, true, false, false, false, true };

    var i: usize = 0;
    while (i < simd_pixels) : (i += 1) {
        const offset = i * 16;
        const src_vec: @Vector(16, u8) = src[offset..][0..16].*;
        const shuffled = @shuffle(u8, src_vec, undefined, shuffle_mask);
        const with_alpha = @select(u8, alpha_select, alpha_mask, shuffled);
        dst[offset..][0..16].* = with_alpha;
    }

    // Handle remaining pixels with scalar loop
    const simd_end = simd_pixels * 16;
    var j: usize = 0;
    while (j < remaining_pixels) : (j += 1) {
        const src_idx = simd_end + j * 4;
        const dst_idx = simd_end + j * 4;
        dst[dst_idx + 0] = src[src_idx + 2];
        dst[dst_idx + 1] = src[src_idx + 1];
        dst[dst_idx + 2] = src[src_idx + 0];
        dst[dst_idx + 3] = 255;
    }
}
