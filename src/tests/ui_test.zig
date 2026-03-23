const std = @import("std");
const ui = @import("ui");

const testing = std.testing;
const DisplayWindow = ui.DisplayWindow;
const GridLayout = ui.GridLayout;

const MAX_W = ui.MAX_THUMBNAIL_WIDTH;
const MAX_H = ui.THUMBNAIL_HEIGHT;

fn testWindow(source_width: u32, source_height: u32) DisplayWindow {
    return testWindowWithDisplay(source_width, source_height, 0, 0);
}

fn testWindowWithDisplay(source_width: u32, source_height: u32, display_width: u32, display_height: u32) DisplayWindow {
    return .{
        .id = 0,
        .title = "",
        .thumbnail_texture = std.mem.zeroes(ui.rl.Texture2D),
        .icon_texture = null,
        .icon_id = "",
        .title_version = 0,
        .thumbnail_version = 0,
        .source_width = source_width,
        .source_height = source_height,
        .display_width = display_width,
        .display_height = display_height,
        .thumbnail_ready = true,
        .cached_snapshot = null,
    };
}

// --- calculateThumbnailSize tests ---

test "calculateThumbnailSize fits to max_height for tall window" {
    const size = ui.calculateThumbnailSize(100, 200, MAX_W, MAX_H);
    // 1:2 aspect ratio, height-constrained: w = MAX_H * 0.5, h = MAX_H
    const expected_w: u32 = @intFromFloat(@as(f32, @floatFromInt(MAX_H)) * 0.5);
    try testing.expectEqual(expected_w, size.width);
    try testing.expectEqual(MAX_H, size.height);
}

test "calculateThumbnailSize fits to max_width for wide window" {
    // 4:1 aspect ratio — will exceed max_width when fit to max_height
    const size = ui.calculateThumbnailSize(400, 100, MAX_W, MAX_H);
    try testing.expectEqual(MAX_W, size.width);
    // height = MAX_W / 4.0, truncated to integer
    const expected_h: u32 = @intFromFloat(@as(f32, @floatFromInt(MAX_W)) / 4.0);
    try testing.expectEqual(expected_h, size.height);
}

test "calculateThumbnailSize with square thumbnail" {
    // 1:1 aspect ratio, height-fit: w = MAX_H.
    // With 16:9 ratio MAX_W > MAX_H, so square is height-constrained.
    const size = ui.calculateThumbnailSize(100, 100, MAX_W, MAX_H);
    try testing.expect(size.width <= MAX_W);
    try testing.expectEqual(MAX_H, size.height);
    // Square aspect ratio preserved: width should equal height
    try testing.expectEqual(size.width, size.height);
}

test "calculateThumbnailSize with narrow window fits height" {
    // Very narrow: 30:200 aspect (0.15), height-fit width is small
    const size = ui.calculateThumbnailSize(30, 200, MAX_W, MAX_H);
    const expected_w: u32 = @intFromFloat(@as(f32, @floatFromInt(MAX_H)) * (30.0 / 200.0));
    try testing.expectEqual(expected_w, size.width);
    try testing.expectEqual(MAX_H, size.height);
}

test "calculateThumbnailSize with zero dimensions returns max" {
    const size = ui.calculateThumbnailSize(0, 0, MAX_W, MAX_H);
    try testing.expectEqual(MAX_W, size.width);
    try testing.expectEqual(MAX_H, size.height);
}

test "calculateThumbnailSize with 16:9 source fits exactly" {
    // A 16:9 source window should fit snugly within the bounding box
    const size = ui.calculateThumbnailSize(1920, 1080, MAX_W, MAX_H);
    // Allow ±1 for integer truncation
    try testing.expect(size.width >= MAX_W - 1 and size.width <= MAX_W);
    try testing.expect(size.height >= MAX_H - 1 and size.height <= MAX_H);
}

test "calculateThumbnailSize preserves aspect ratio" {
    const size = ui.calculateThumbnailSize(300, 200, MAX_W, MAX_H);
    const source_ratio = 300.0 / 200.0;
    const result_ratio = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));
    // Allow small error from integer truncation
    try testing.expect(@abs(source_ratio - result_ratio) < 0.05);
}

test "calculateThumbnailSize never exceeds bounds" {
    // Test a variety of aspect ratios
    const cases = [_][2]u32{
        .{ 100, 100 },
        .{ 1920, 1080 },
        .{ 1080, 1920 },
        .{ 3840, 1080 },
        .{ 100, 2000 },
        .{ 1, 1000 },
        .{ 5000, 1 },
    };
    for (cases) |case| {
        const size = ui.calculateThumbnailSize(case[0], case[1], MAX_W, MAX_H);
        try testing.expect(size.width <= MAX_W);
        try testing.expect(size.height <= MAX_H);
        try testing.expect(size.width >= 1);
        try testing.expect(size.height >= 1);
    }
}

// --- calculateGridLayout tests ---

test "calculateGridLayout with empty items" {
    var items: [0]DisplayWindow = .{};
    const grid = ui.calculateGridLayout(&items, MAX_H);

    try testing.expectEqual(@as(u32, 0), grid.columns);
    try testing.expectEqual(@as(u32, 0), grid.rows);
    try testing.expectEqual(MAX_H, grid.item_height);
    try testing.expectEqual(ui.PADDING * 2, grid.total_width);
    try testing.expectEqual(ui.PADDING * 2, grid.total_height);
}

test "calculateGridLayout with single item" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
    };
    const grid = ui.calculateGridLayout(&items, MAX_H);

    try testing.expectEqual(@as(u32, 1), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
    try testing.expectEqual(MAX_H, grid.item_height);

    // Display size must respect bounds and preserve aspect ratio
    try testing.expect(items[0].display_width <= MAX_W);
    try testing.expect(items[0].display_height <= MAX_H);
    try testing.expect(items[0].display_width >= 1);
    try testing.expect(items[0].display_height >= 1);
}

test "calculateGridLayout with multiple items in one row" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
        testWindow(160, 100),
        testWindow(160, 100),
    };
    const grid = ui.calculateGridLayout(&items, MAX_H);

    // 3 items with moderate width should fit in one row
    try testing.expectEqual(@as(u32, 3), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
}

test "calculateGridLayout with items requiring multiple rows" {
    // Use enough items that they can't all fit in one row.
    // Each wide item gets clamped to MAX_W. We need:
    // N * MAX_W + (N-1) * SPACING + 2 * PADDING > MAX_GRID_WIDTH
    const items_needed = (ui.MAX_GRID_WIDTH + ui.SPACING) / (MAX_W + ui.SPACING) + 2;
    var items: [50]DisplayWindow = undefined;
    const count = @min(items_needed, 50);
    for (items[0..count]) |*item| {
        item.* = testWindow(300, 100);
    }

    const grid = ui.calculateGridLayout(items[0..count], MAX_H);

    try testing.expect(grid.rows > 1);
    try testing.expect(grid.columns > 0);
    try testing.expect(grid.columns <= count);
}

test "calculateGridLayout with very wide items" {
    var items = [_]DisplayWindow{
        testWindow(1600, 100),
    };
    _ = ui.calculateGridLayout(&items, MAX_H);

    // Very wide source gets clamped to MAX_W
    try testing.expectEqual(MAX_W, items[0].display_width);
    // Height is reduced proportionally
    try testing.expect(items[0].display_height < MAX_H);
    try testing.expect(items[0].display_height >= 1);
}

test "calculateGridLayout with tall thumbnails" {
    var items = [_]DisplayWindow{
        testWindow(100, 200),
    };
    _ = ui.calculateGridLayout(&items, MAX_H);

    // 1:2 aspect ratio, height-constrained: width = MAX_H / 2
    const expected_w: u32 = @intFromFloat(@as(f32, @floatFromInt(MAX_H)) * 0.5);
    try testing.expectEqual(expected_w, items[0].display_width);
    try testing.expectEqual(MAX_H, items[0].display_height);
}

test "calculateGridLayout with mixed aspect ratios" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
        testWindow(100, 100),
        testWindow(100, 200),
    };
    _ = ui.calculateGridLayout(&items, MAX_H);

    // All items must respect bounds
    for (items) |item| {
        try testing.expect(item.display_width <= MAX_W);
        try testing.expect(item.display_height <= MAX_H);
        try testing.expect(item.display_width >= 1);
        try testing.expect(item.display_height >= 1);
    }

    // Wider source windows should produce wider display widths
    try testing.expect(items[0].display_width > items[2].display_width);
    // Tall source (1:2) is height-constrained, so display_height == MAX_H
    try testing.expectEqual(MAX_H, items[2].display_height);
}

// --- calculateRowWidth tests ---

test "calculateRowWidth with single item" {
    var items = [_]DisplayWindow{
        testWindowWithDisplay(100, 100, 150, 100),
    };

    const width = ui.calculateRowWidth(&items, 0, 1);
    try testing.expectEqual(@as(u32, 150), width);
}

test "calculateRowWidth with multiple items" {
    var items = [_]DisplayWindow{
        testWindowWithDisplay(100, 100, 100, 100),
        testWindowWithDisplay(100, 100, 150, 100),
        testWindowWithDisplay(100, 100, 200, 100),
    };

    const width = ui.calculateRowWidth(&items, 0, 3);
    try testing.expectEqual(@as(u32, 100 + ui.SPACING + 150 + ui.SPACING + 200), width);
}

test "calculateRowWidth with partial row" {
    var items = [_]DisplayWindow{
        testWindowWithDisplay(100, 100, 100, 100),
        testWindowWithDisplay(100, 100, 150, 100),
        testWindowWithDisplay(100, 100, 200, 100),
    };

    const width = ui.calculateRowWidth(&items, 1, 2);
    try testing.expectEqual(@as(u32, 150 + ui.SPACING + 200), width);
}

test "calculateRowWidth with count exceeding items" {
    var items = [_]DisplayWindow{
        testWindowWithDisplay(100, 100, 100, 100),
    };

    const width = ui.calculateRowWidth(&items, 0, 5);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateRowWidth with start beyond items" {
    var items = [_]DisplayWindow{
        testWindowWithDisplay(100, 100, 100, 100),
    };

    const width = ui.calculateRowWidth(&items, 5, 1);
    try testing.expectEqual(@as(u32, 0), width);
}

// --- grid layout constraint tests ---

test "grid layout respects MAX_GRID_WIDTH" {
    var items: [30]DisplayWindow = undefined;
    for (&items) |*item| {
        item.* = testWindow(200, 100);
    }

    const grid = ui.calculateGridLayout(&items, MAX_H);

    try testing.expect(grid.total_width <= ui.MAX_GRID_WIDTH);
    try testing.expect(grid.rows > 1);
}

test "grid layout with 50 items" {
    var items: [50]DisplayWindow = undefined;
    for (&items) |*item| {
        item.* = testWindow(160, 100);
    }

    // Use a small target height to ensure 50 items can fit within grid bounds
    const grid = ui.calculateGridLayout(&items, 60);

    try testing.expect(grid.columns > 0);
    try testing.expect(grid.rows > 0);
    try testing.expect(grid.columns * grid.rows >= 50);
    try testing.expect(grid.total_width <= ui.MAX_GRID_WIDTH);
    try testing.expect(grid.total_height <= ui.MAX_GRID_HEIGHT);
}
