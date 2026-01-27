const std = @import("std");
const nav = @import("navigation");

const testing = std.testing;

// moveSelectionRight tests

test "moveSelectionRight moves to next index" {
    try testing.expectEqual(@as(usize, 1), nav.moveSelectionRight(0, 5));
    try testing.expectEqual(@as(usize, 2), nav.moveSelectionRight(1, 5));
    try testing.expectEqual(@as(usize, 3), nav.moveSelectionRight(2, 5));
}

test "moveSelectionRight wraps at end" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionRight(4, 5));
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionRight(9, 10));
}

test "moveSelectionRight with single item stays at 0" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionRight(0, 1));
}

test "moveSelectionRight with zero count returns 0" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionRight(5, 0));
}

// moveSelectionLeft tests

test "moveSelectionLeft moves to previous index" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionLeft(1, 5));
    try testing.expectEqual(@as(usize, 1), nav.moveSelectionLeft(2, 5));
    try testing.expectEqual(@as(usize, 3), nav.moveSelectionLeft(4, 5));
}

test "moveSelectionLeft wraps at start" {
    try testing.expectEqual(@as(usize, 4), nav.moveSelectionLeft(0, 5));
    try testing.expectEqual(@as(usize, 9), nav.moveSelectionLeft(0, 10));
}

test "moveSelectionLeft with single item stays at 0" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionLeft(0, 1));
}

test "moveSelectionLeft with zero count returns 0" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionLeft(5, 0));
}

// moveSelectionDown tests

test "moveSelectionDown moves down by columns" {
    // Grid with 3 columns, 10 items
    // 0 1 2
    // 3 4 5
    // 6 7 8
    // 9
    try testing.expectEqual(@as(usize, 3), nav.moveSelectionDown(0, 3, 10));
    try testing.expectEqual(@as(usize, 4), nav.moveSelectionDown(1, 3, 10));
    try testing.expectEqual(@as(usize, 5), nav.moveSelectionDown(2, 3, 10));
}

test "moveSelectionDown clamps to last item in bottom row" {
    // From index 6, moving down with 3 columns would go to 9, which is clamped
    try testing.expectEqual(@as(usize, 9), nav.moveSelectionDown(6, 3, 10));

    // From index 7, moving down would go to 10, but max is 9
    try testing.expectEqual(@as(usize, 9), nav.moveSelectionDown(7, 3, 10));

    // From index 8, moving down would go to 11, but max is 9
    try testing.expectEqual(@as(usize, 9), nav.moveSelectionDown(8, 3, 10));
}

test "moveSelectionDown in last row stays at current if adding columns exceeds count" {
    // Already at last item
    try testing.expectEqual(@as(usize, 9), nav.moveSelectionDown(9, 3, 10));
}

test "moveSelectionDown with single column moves down one" {
    try testing.expectEqual(@as(usize, 1), nav.moveSelectionDown(0, 1, 5));
    try testing.expectEqual(@as(usize, 4), nav.moveSelectionDown(3, 1, 5));
    try testing.expectEqual(@as(usize, 4), nav.moveSelectionDown(4, 1, 5)); // Already at last
}

test "moveSelectionDown with zero count returns 0" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionDown(5, 3, 0));
}

test "moveSelectionDown with zero columns returns current" {
    try testing.expectEqual(@as(usize, 5), nav.moveSelectionDown(5, 0, 10));
}

// moveSelectionUp tests

test "moveSelectionUp moves up by columns" {
    // Grid with 3 columns
    // 0 1 2
    // 3 4 5
    // 6 7 8
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionUp(3, 3));
    try testing.expectEqual(@as(usize, 1), nav.moveSelectionUp(4, 3));
    try testing.expectEqual(@as(usize, 2), nav.moveSelectionUp(5, 3));
    try testing.expectEqual(@as(usize, 3), nav.moveSelectionUp(6, 3));
}

test "moveSelectionUp in first row stays at current position" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionUp(0, 3));
    try testing.expectEqual(@as(usize, 1), nav.moveSelectionUp(1, 3));
    try testing.expectEqual(@as(usize, 2), nav.moveSelectionUp(2, 3));
}

test "moveSelectionUp with single column moves up one" {
    try testing.expectEqual(@as(usize, 0), nav.moveSelectionUp(1, 1));
    try testing.expectEqual(@as(usize, 3), nav.moveSelectionUp(4, 1));
}

test "moveSelectionUp with zero columns returns current" {
    try testing.expectEqual(@as(usize, 5), nav.moveSelectionUp(5, 0));
}

// Combined grid navigation scenarios

test "full grid navigation cycle" {
    // 2x3 grid with 6 items
    // 0 1 2
    // 3 4 5
    const cols: usize = 3;
    const count: usize = 6;

    // Start at 0, move right twice
    var pos: usize = 0;
    pos = nav.moveSelectionRight(pos, count);
    try testing.expectEqual(@as(usize, 1), pos);
    pos = nav.moveSelectionRight(pos, count);
    try testing.expectEqual(@as(usize, 2), pos);

    // Move down
    pos = nav.moveSelectionDown(pos, cols, count);
    try testing.expectEqual(@as(usize, 5), pos);

    // Move left twice
    pos = nav.moveSelectionLeft(pos, count);
    try testing.expectEqual(@as(usize, 4), pos);
    pos = nav.moveSelectionLeft(pos, count);
    try testing.expectEqual(@as(usize, 3), pos);

    // Move up
    pos = nav.moveSelectionUp(pos, cols);
    try testing.expectEqual(@as(usize, 0), pos);
}

test "navigation with incomplete last row" {
    // Grid: 3 columns, 8 items
    // 0 1 2
    // 3 4 5
    // 6 7
    const cols: usize = 3;
    const count: usize = 8;

    // From position 4, move down should go to 7
    var pos: usize = 4;
    pos = nav.moveSelectionDown(pos, cols, count);
    try testing.expectEqual(@as(usize, 7), pos);

    // From position 5, move down should clamp to 7 (last item)
    pos = 5;
    pos = nav.moveSelectionDown(pos, cols, count);
    try testing.expectEqual(@as(usize, 7), pos);

    // From position 7, move up should go to 4
    pos = 7;
    pos = nav.moveSelectionUp(pos, cols);
    try testing.expectEqual(@as(usize, 4), pos);

    // From position 6, move up should go to 3
    pos = 6;
    pos = nav.moveSelectionUp(pos, cols);
    try testing.expectEqual(@as(usize, 3), pos);
}

test "wraparound in single row" {
    // Single row of 5 items
    const count: usize = 5;

    var pos: usize = 4;
    pos = nav.moveSelectionRight(pos, count);
    try testing.expectEqual(@as(usize, 0), pos);

    pos = nav.moveSelectionLeft(pos, count);
    try testing.expectEqual(@as(usize, 4), pos);
}

test "navigation with large grid" {
    // 10 columns, 50 items
    const cols: usize = 10;
    const count: usize = 50;

    // From 0, move right 9 times to reach end of first row
    var pos: usize = 0;
    for (0..9) |_| {
        pos = nav.moveSelectionRight(pos, count);
    }
    try testing.expectEqual(@as(usize, 9), pos);

    // Move down 4 times to reach last row
    for (0..4) |_| {
        pos = nav.moveSelectionDown(pos, cols, count);
    }
    try testing.expectEqual(@as(usize, 49), pos);

    // Move left should go to 48
    pos = nav.moveSelectionLeft(pos, count);
    try testing.expectEqual(@as(usize, 48), pos);
}
