const std = @import("std");
const color = @import("color");

const testing = std.testing;

test "single pixel BGRA to RGBA conversion" {
    // BGRA: Blue=0x11, Green=0x22, Red=0x33, Alpha=0x44
    const src = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    var dst: [4]u8 = undefined;

    color.convertBgraToRgbaSimd(&src, &dst);

    // Expected RGBA: Red=0x33, Green=0x22, Blue=0x11, Alpha=255 (forced)
    try testing.expectEqual(@as(u8, 0x33), dst[0]); // R
    try testing.expectEqual(@as(u8, 0x22), dst[1]); // G
    try testing.expectEqual(@as(u8, 0x11), dst[2]); // B
    try testing.expectEqual(@as(u8, 255), dst[3]); // A (always 255)
}

test "4 pixels SIMD path (16 bytes)" {
    // 4 pixels = 16 bytes, triggers SIMD path
    const src = [16]u8{
        0x11, 0x22, 0x33, 0x44, // Pixel 0: BGRA
        0x55, 0x66, 0x77, 0x88, // Pixel 1: BGRA
        0x99, 0xAA, 0xBB, 0xCC, // Pixel 2: BGRA
        0xDD, 0xEE, 0xFF, 0x00, // Pixel 3: BGRA
    };
    var dst: [16]u8 = undefined;

    color.convertBgraToRgbaSimd(&src, &dst);

    // Pixel 0: R=0x33, G=0x22, B=0x11, A=255
    try testing.expectEqual(@as(u8, 0x33), dst[0]);
    try testing.expectEqual(@as(u8, 0x22), dst[1]);
    try testing.expectEqual(@as(u8, 0x11), dst[2]);
    try testing.expectEqual(@as(u8, 255), dst[3]);

    // Pixel 1: R=0x77, G=0x66, B=0x55, A=255
    try testing.expectEqual(@as(u8, 0x77), dst[4]);
    try testing.expectEqual(@as(u8, 0x66), dst[5]);
    try testing.expectEqual(@as(u8, 0x55), dst[6]);
    try testing.expectEqual(@as(u8, 255), dst[7]);

    // Pixel 2: R=0xBB, G=0xAA, B=0x99, A=255
    try testing.expectEqual(@as(u8, 0xBB), dst[8]);
    try testing.expectEqual(@as(u8, 0xAA), dst[9]);
    try testing.expectEqual(@as(u8, 0x99), dst[10]);
    try testing.expectEqual(@as(u8, 255), dst[11]);

    // Pixel 3: R=0xFF, G=0xEE, B=0xDD, A=255
    try testing.expectEqual(@as(u8, 0xFF), dst[12]);
    try testing.expectEqual(@as(u8, 0xEE), dst[13]);
    try testing.expectEqual(@as(u8, 0xDD), dst[14]);
    try testing.expectEqual(@as(u8, 255), dst[15]);
}

test "5 pixels non-aligned (SIMD + scalar remainder)" {
    // 5 pixels = 20 bytes: 4 SIMD + 1 scalar
    var src: [20]u8 = undefined;
    var dst: [20]u8 = undefined;

    // Fill with test pattern
    for (0..5) |i| {
        const offset = i * 4;
        src[offset + 0] = @intCast(i * 10); // B
        src[offset + 1] = @intCast(i * 10 + 1); // G
        src[offset + 2] = @intCast(i * 10 + 2); // R
        src[offset + 3] = @intCast(i * 10 + 3); // A (will be replaced with 255)
    }

    color.convertBgraToRgbaSimd(&src, &dst);

    // Verify all 5 pixels
    for (0..5) |i| {
        const offset = i * 4;
        try testing.expectEqual(@as(u8, @intCast(i * 10 + 2)), dst[offset + 0]); // R
        try testing.expectEqual(@as(u8, @intCast(i * 10 + 1)), dst[offset + 1]); // G
        try testing.expectEqual(@as(u8, @intCast(i * 10)), dst[offset + 2]); // B
        try testing.expectEqual(@as(u8, 255), dst[offset + 3]); // A
    }
}

test "large array (100 pixels)" {
    const pixel_count = 100;
    var src: [pixel_count * 4]u8 = undefined;
    var dst: [pixel_count * 4]u8 = undefined;

    // Fill with test pattern
    for (0..pixel_count) |i| {
        const offset = i * 4;
        src[offset + 0] = @intCast(i % 256); // B
        src[offset + 1] = @intCast((i + 50) % 256); // G
        src[offset + 2] = @intCast((i + 100) % 256); // R
        src[offset + 3] = @intCast((i + 150) % 256); // A (ignored)
    }

    color.convertBgraToRgbaSimd(&src, &dst);

    // Verify all pixels
    for (0..pixel_count) |i| {
        const offset = i * 4;
        try testing.expectEqual(@as(u8, @intCast((i + 100) % 256)), dst[offset + 0]); // R
        try testing.expectEqual(@as(u8, @intCast((i + 50) % 256)), dst[offset + 1]); // G
        try testing.expectEqual(@as(u8, @intCast(i % 256)), dst[offset + 2]); // B
        try testing.expectEqual(@as(u8, 255), dst[offset + 3]); // A always 255
    }
}

test "alpha channel always set to 255 regardless of input" {
    // Test with various alpha values including 0
    const test_alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };

    for (test_alphas) |alpha| {
        const src = [4]u8{ 0x00, 0x00, 0x00, alpha };
        var dst: [4]u8 = undefined;

        color.convertBgraToRgbaSimd(&src, &dst);

        try testing.expectEqual(@as(u8, 255), dst[3]);
    }
}

test "8 pixels (2x SIMD iterations)" {
    // 8 pixels = 32 bytes = 2 SIMD iterations
    var src: [32]u8 = undefined;
    var dst: [32]u8 = undefined;

    // Fill with known pattern
    for (0..8) |i| {
        const offset = i * 4;
        src[offset + 0] = @intCast(0xB0 + i); // B
        src[offset + 1] = @intCast(0x60 + i); // G
        src[offset + 2] = @intCast(0x90 + i); // R
        src[offset + 3] = @intCast(i); // A
    }

    color.convertBgraToRgbaSimd(&src, &dst);

    // Verify all 8 pixels
    for (0..8) |i| {
        const offset = i * 4;
        try testing.expectEqual(@as(u8, @intCast(0x90 + i)), dst[offset + 0]); // R
        try testing.expectEqual(@as(u8, @intCast(0x60 + i)), dst[offset + 1]); // G
        try testing.expectEqual(@as(u8, @intCast(0xB0 + i)), dst[offset + 2]); // B
        try testing.expectEqual(@as(u8, 255), dst[offset + 3]); // A
    }
}

test "2 pixels (scalar only, no SIMD)" {
    // 2 pixels = 8 bytes, less than 16 so scalar path only
    const src = [8]u8{
        0xAA, 0xBB, 0xCC, 0xDD, // Pixel 0: BGRA
        0x11, 0x22, 0x33, 0x44, // Pixel 1: BGRA
    };
    var dst: [8]u8 = undefined;

    color.convertBgraToRgbaSimd(&src, &dst);

    // Pixel 0: R=0xCC, G=0xBB, B=0xAA, A=255
    try testing.expectEqual(@as(u8, 0xCC), dst[0]);
    try testing.expectEqual(@as(u8, 0xBB), dst[1]);
    try testing.expectEqual(@as(u8, 0xAA), dst[2]);
    try testing.expectEqual(@as(u8, 255), dst[3]);

    // Pixel 1: R=0x33, G=0x22, B=0x11, A=255
    try testing.expectEqual(@as(u8, 0x33), dst[4]);
    try testing.expectEqual(@as(u8, 0x22), dst[5]);
    try testing.expectEqual(@as(u8, 0x11), dst[6]);
    try testing.expectEqual(@as(u8, 255), dst[7]);
}

test "3 pixels (scalar only)" {
    // 3 pixels = 12 bytes, less than 16 so scalar path only
    var src: [12]u8 = undefined;
    var dst: [12]u8 = undefined;

    // Fill with pattern
    for (0..3) |i| {
        const offset = i * 4;
        src[offset + 0] = @intCast(i + 1); // B
        src[offset + 1] = @intCast(i + 2); // G
        src[offset + 2] = @intCast(i + 3); // R
        src[offset + 3] = 0; // A (will be 255)
    }

    color.convertBgraToRgbaSimd(&src, &dst);

    for (0..3) |i| {
        const offset = i * 4;
        try testing.expectEqual(@as(u8, @intCast(i + 3)), dst[offset + 0]); // R
        try testing.expectEqual(@as(u8, @intCast(i + 2)), dst[offset + 1]); // G
        try testing.expectEqual(@as(u8, @intCast(i + 1)), dst[offset + 2]); // B
        try testing.expectEqual(@as(u8, 255), dst[offset + 3]); // A
    }
}
