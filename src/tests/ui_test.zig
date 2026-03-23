const std = @import("std");
const ui = @import("ui");

const testing = std.testing;
const DisplayWindow = ui.DisplayWindow;
const GridLayout = ui.GridLayout;

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
    // 100:200 aspect ratio (0.5), max_width=214, max_height=100
    // height-fit: w=50, h=100. w<214, stays.
    const size = ui.calculateThumbnailSize(100, 200, 214, 100);
    try testing.expectEqual(@as(u32, 50), size.width);
    try testing.expectEqual(@as(u32, 100), size.height);
}

test "calculateThumbnailSize fits to max_width for wide window" {
    // 400:100 aspect ratio (4.0), max_width=214, max_height=100
    // height-fit: w=400, h=100. w>214, so width-fit: w=214, h=53.
    const size = ui.calculateThumbnailSize(400, 100, 214, 100);
    try testing.expectEqual(@as(u32, 214), size.width);
    try testing.expectEqual(@as(u32, 53), size.height);
}

test "calculateThumbnailSize with square thumbnail fits height" {
    // 100:100 aspect ratio (1.0), max_width=214, max_height=100
    // height-fit: w=100, h=100. w<214, stays.
    const size = ui.calculateThumbnailSize(100, 100, 214, 100);
    try testing.expectEqual(@as(u32, 100), size.width);
    try testing.expectEqual(@as(u32, 100), size.height);
}

test "calculateThumbnailSize with narrow window fits height" {
    // 30:200 aspect ratio (0.15), max_width=214, max_height=100
    // height-fit: w=15, h=100. w<214, stays.
    const size = ui.calculateThumbnailSize(30, 200, 214, 100);
    try testing.expectEqual(@as(u32, 15), size.width);
    try testing.expectEqual(@as(u32, 100), size.height);
}

test "calculateThumbnailSize with zero dimensions returns max" {
    const size = ui.calculateThumbnailSize(0, 0, 214, 100);
    try testing.expectEqual(@as(u32, 214), size.width);
    try testing.expectEqual(@as(u32, 100), size.height);
}

test "calculateThumbnailSize exactly at max_width" {
    // 428:200 aspect ratio (2.14), max_width=214, max_height=100
    // height-fit: w=100*2.14=214, h=100. Due to float rounding, may
    // trigger width constraint: w=214, h=214/2.14≈99.
    const size = ui.calculateThumbnailSize(428, 200, 214, 100);
    try testing.expectEqual(@as(u32, 214), size.width);
    try testing.expect(size.height >= 99 and size.height <= 100);
}

test "calculateGridLayout with empty items" {
    var items: [0]DisplayWindow = .{};
    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expectEqual(@as(u32, 0), grid.columns);
    try testing.expectEqual(@as(u32, 0), grid.rows);
    try testing.expectEqual(@as(u32, 100), grid.item_height);
    try testing.expectEqual(@as(u32, ui.PADDING * 2), grid.total_width);
    try testing.expectEqual(@as(u32, ui.PADDING * 2), grid.total_height);
}

test "calculateGridLayout with single item" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
    };
    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expectEqual(@as(u32, 1), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
    try testing.expectEqual(@as(u32, 100), grid.item_height);

    // 160:100 aspect ratio, w=160 < MAX_THUMBNAIL_WIDTH (214), no width constraint
    try testing.expectEqual(@as(u32, 160), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
}

test "calculateGridLayout with multiple items in one row" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
        testWindow(160, 100),
        testWindow(160, 100),
    };
    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expectEqual(@as(u32, 3), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
}

test "calculateGridLayout with items requiring multiple rows" {
    // With MAX_THUMBNAIL_WIDTH=214, 300:100 windows get clamped to w=214.
    // 214px * N + 12px * (N-1) + 32px > 1720 => N > 7.5 => N=8 to force rows>1
    var items: [10]DisplayWindow = undefined;
    for (&items) |*item| {
        item.* = testWindow(300, 100);
    }

    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expect(grid.rows > 1);
    try testing.expect(grid.columns > 0);
    try testing.expect(grid.columns <= 10);
}

test "calculateGridLayout with very wide items" {
    var items = [_]DisplayWindow{
        testWindow(1600, 100),
    };
    _ = ui.calculateGridLayout(&items, 100);

    // 1600:100 aspect ratio, constrained by MAX_THUMBNAIL_WIDTH (214): w=214, h=13
    try testing.expectEqual(@as(u32, 214), items[0].display_width);
    try testing.expectEqual(@as(u32, 13), items[0].display_height);
}

test "calculateGridLayout with tall thumbnails" {
    var items = [_]DisplayWindow{
        testWindow(100, 200),
    };
    _ = ui.calculateGridLayout(&items, 100);

    // 100:200 aspect ratio (0.5), height-fit: w=50, h=100. w<68, so no width constraint.
    try testing.expectEqual(@as(u32, 50), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
}

test "calculateGridLayout with mixed aspect ratios" {
    var items = [_]DisplayWindow{
        testWindow(160, 100),
        testWindow(100, 100),
        testWindow(100, 200),
    };
    _ = ui.calculateGridLayout(&items, 100);

    // 160:100 -> w=160 < 214, no width constraint
    try testing.expectEqual(@as(u32, 160), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
    // 100:100 -> w=100 < 214, no width constraint
    try testing.expectEqual(@as(u32, 100), items[1].display_width);
    try testing.expectEqual(@as(u32, 100), items[1].display_height);
    // 100:200 -> height-fit: w=50, h=100 (w<214, no width constraint)
    try testing.expectEqual(@as(u32, 50), items[2].display_width);
    try testing.expectEqual(@as(u32, 100), items[2].display_height);
}

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

test "grid layout respects MAX_GRID_WIDTH" {
    var items: [20]DisplayWindow = undefined;
    for (&items) |*item| {
        item.* = testWindow(200, 100);
    }

    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expect(grid.total_width <= ui.MAX_GRID_WIDTH);
    try testing.expect(grid.rows > 1);
}

test "grid layout with 50 items" {
    var items: [50]DisplayWindow = undefined;
    for (&items) |*item| {
        item.* = testWindow(160, 100);
    }

    const grid = ui.calculateGridLayout(&items, 100);

    try testing.expect(grid.columns > 0);
    try testing.expect(grid.rows > 0);
    try testing.expect(grid.columns * grid.rows >= 50);
    try testing.expect(grid.total_width <= ui.MAX_GRID_WIDTH);
    try testing.expect(grid.total_height <= ui.MAX_GRID_HEIGHT);
}
