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
        .is_glx = false,
    };
}

test "calculateItemWidth with square thumbnail" {
    const width = ui.calculateItemWidth(100, 100, 100);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateItemWidth with wide thumbnail" {
    const width = ui.calculateItemWidth(200, 100, 100);
    try testing.expectEqual(@as(u32, 200), width);
}

test "calculateItemWidth with tall thumbnail" {
    const width = ui.calculateItemWidth(100, 200, 100);
    try testing.expectEqual(@as(u32, 50), width);
}

test "calculateItemWidth with zero height returns target height" {
    const width = ui.calculateItemWidth(100, 0, 100);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateItemWidth with very small result returns 1" {
    const width = ui.calculateItemWidth(1, 1000, 10);
    try testing.expectEqual(@as(u32, 1), width);
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

    try testing.expectEqual(@as(u32, 1600), items[0].display_width);
}

test "calculateGridLayout with tall thumbnails" {
    var items = [_]DisplayWindow{
        testWindow(100, 200),
    };
    _ = ui.calculateGridLayout(&items, 100);

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

    try testing.expectEqual(@as(u32, 160), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[1].display_width);
    try testing.expectEqual(@as(u32, 50), items[2].display_width);

    try testing.expectEqual(@as(u32, 100), items[0].display_height);
    try testing.expectEqual(@as(u32, 100), items[1].display_height);
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
