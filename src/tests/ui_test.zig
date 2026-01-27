const std = @import("std");
const layout = @import("layout");

const testing = std.testing;
const LayoutItem = layout.LayoutItem;
const GridLayout = layout.GridLayout;

test "calculateItemWidth with square thumbnail" {
    // 100x100 thumbnail at target height 100 should give width 100
    const width = layout.calculateItemWidth(100, 100, 100);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateItemWidth with wide thumbnail" {
    // 200x100 thumbnail (2:1 aspect ratio) at target height 100 should give width 200
    const width = layout.calculateItemWidth(200, 100, 100);
    try testing.expectEqual(@as(u32, 200), width);
}

test "calculateItemWidth with tall thumbnail" {
    // 100x200 thumbnail (1:2 aspect ratio) at target height 100 should give width 50
    const width = layout.calculateItemWidth(100, 200, 100);
    try testing.expectEqual(@as(u32, 50), width);
}

test "calculateItemWidth with zero height returns target height" {
    const width = layout.calculateItemWidth(100, 0, 100);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateItemWidth with very small result returns 1" {
    // 1x1000 thumbnail at target height 10 would give 0.01, should return 1
    const width = layout.calculateItemWidth(1, 1000, 10);
    try testing.expectEqual(@as(u32, 1), width);
}

test "calculateGridLayoutGeneric with empty items" {
    var items: [0]LayoutItem = .{};
    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    try testing.expectEqual(@as(u32, 0), grid.columns);
    try testing.expectEqual(@as(u32, 0), grid.rows);
    try testing.expectEqual(@as(u32, 100), grid.item_height);
    try testing.expectEqual(@as(u32, layout.PADDING * 2), grid.total_width);
    try testing.expectEqual(@as(u32, layout.PADDING * 2), grid.total_height);
}

test "calculateGridLayoutGeneric with single item" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 160, .thumb_height = 100 },
    };
    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    try testing.expectEqual(@as(u32, 1), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
    try testing.expectEqual(@as(u32, 100), grid.item_height);

    // Verify display dimensions were set
    try testing.expectEqual(@as(u32, 160), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
}

test "calculateGridLayoutGeneric with multiple items in one row" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 160, .thumb_height = 100 },
        .{ .thumb_width = 160, .thumb_height = 100 },
        .{ .thumb_width = 160, .thumb_height = 100 },
    };
    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    // 3 items should fit in one row (3*160 + 2*12 + 2*16 = 536 < 1820)
    try testing.expectEqual(@as(u32, 3), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
}

test "calculateGridLayoutGeneric with items requiring multiple rows" {
    // Create 10 wide items that force multiple rows
    var items: [10]LayoutItem = undefined;
    for (&items) |*item| {
        item.* = .{ .thumb_width = 300, .thumb_height = 100 };
    }

    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    // Should have multiple rows since items are wide
    try testing.expect(grid.rows > 1);
    try testing.expect(grid.columns > 0);
    try testing.expect(grid.columns <= 10);
}

test "calculateGridLayoutGeneric with very wide items" {
    // Single very wide item
    var items = [_]LayoutItem{
        .{ .thumb_width = 1600, .thumb_height = 100 },
    };
    _ = layout.calculateGridLayoutGeneric(&items, 100);

    // Display width should be scaled to target height
    try testing.expectEqual(@as(u32, 1600), items[0].display_width);
}

test "calculateGridLayoutGeneric with tall thumbnails" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 200 }, // 1:2 aspect ratio
    };
    _ = layout.calculateGridLayoutGeneric(&items, 100);

    // Width should be halved due to aspect ratio
    try testing.expectEqual(@as(u32, 50), items[0].display_width);
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
}

test "calculateGridLayoutGeneric with mixed aspect ratios" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 160, .thumb_height = 100 }, // 16:10 (wide)
        .{ .thumb_width = 100, .thumb_height = 100 }, // 1:1 (square)
        .{ .thumb_width = 100, .thumb_height = 200 }, // 1:2 (tall)
    };
    _ = layout.calculateGridLayoutGeneric(&items, 100);

    try testing.expectEqual(@as(u32, 160), items[0].display_width); // wide
    try testing.expectEqual(@as(u32, 100), items[1].display_width); // square
    try testing.expectEqual(@as(u32, 50), items[2].display_width); // tall

    // All should have same display height
    try testing.expectEqual(@as(u32, 100), items[0].display_height);
    try testing.expectEqual(@as(u32, 100), items[1].display_height);
    try testing.expectEqual(@as(u32, 100), items[2].display_height);
}

test "calculateRowWidthGeneric with single item" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 150, .display_height = 100 },
    };

    const width = layout.calculateRowWidthGeneric(&items, 0, 1);
    try testing.expectEqual(@as(u32, 150), width);
}

test "calculateRowWidthGeneric with multiple items" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 100, .display_height = 100 },
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 150, .display_height = 100 },
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 200, .display_height = 100 },
    };

    // All 3 items: 100 + 12 + 150 + 12 + 200 = 474
    const width = layout.calculateRowWidthGeneric(&items, 0, 3);
    try testing.expectEqual(@as(u32, 100 + layout.SPACING + 150 + layout.SPACING + 200), width);
}

test "calculateRowWidthGeneric with partial row" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 100, .display_height = 100 },
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 150, .display_height = 100 },
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 200, .display_height = 100 },
    };

    // Only items 1 and 2 (index 1 and 2): 150 + 12 + 200 = 362
    const width = layout.calculateRowWidthGeneric(&items, 1, 2);
    try testing.expectEqual(@as(u32, 150 + layout.SPACING + 200), width);
}

test "calculateRowWidthGeneric with count exceeding items" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 100, .display_height = 100 },
    };

    // Request 5 items but only 1 exists
    const width = layout.calculateRowWidthGeneric(&items, 0, 5);
    try testing.expectEqual(@as(u32, 100), width);
}

test "calculateRowWidthGeneric with start beyond items" {
    var items = [_]LayoutItem{
        .{ .thumb_width = 100, .thumb_height = 100, .display_width = 100, .display_height = 100 },
    };

    // Start at index 5 but only 1 item exists
    const width = layout.calculateRowWidthGeneric(&items, 5, 1);
    try testing.expectEqual(@as(u32, 0), width);
}

test "grid layout respects MAX_GRID_WIDTH" {
    // Create many wide items that would exceed MAX_GRID_WIDTH if in one row
    var items: [20]LayoutItem = undefined;
    for (&items) |*item| {
        item.* = .{ .thumb_width = 200, .thumb_height = 100 };
    }

    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    // Total width should not exceed MAX_GRID_WIDTH
    try testing.expect(grid.total_width <= layout.MAX_GRID_WIDTH);
    // Should have multiple rows
    try testing.expect(grid.rows > 1);
}

test "grid layout with 50 items" {
    var items: [50]LayoutItem = undefined;
    for (&items) |*item| {
        item.* = .{ .thumb_width = 160, .thumb_height = 100 };
    }

    const grid = layout.calculateGridLayoutGeneric(&items, 100);

    // Basic sanity checks
    try testing.expect(grid.columns > 0);
    try testing.expect(grid.rows > 0);
    try testing.expect(grid.columns * grid.rows >= 50);
    try testing.expect(grid.total_width <= layout.MAX_GRID_WIDTH);
    try testing.expect(grid.total_height <= layout.MAX_GRID_HEIGHT);
}
