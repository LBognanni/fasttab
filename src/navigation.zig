/// Pure navigation functions for grid selection movement.
/// These functions handle index calculations without any UI dependencies.
/// Move selection right with wrap-around
pub fn moveSelectionRight(current: usize, count: usize) usize {
    if (count == 0) return 0;
    return (current + 1) % count;
}

/// Move selection left with wrap-around
pub fn moveSelectionLeft(current: usize, count: usize) usize {
    if (count == 0) return 0;
    if (current == 0) return count - 1;
    return current - 1;
}

/// Move selection down by one row (columns items), clamped to last item
pub fn moveSelectionDown(current: usize, columns: usize, count: usize) usize {
    if (count == 0) return 0;
    if (columns == 0) return current;
    return @min(current + columns, count - 1);
}

/// Move selection up by one row (columns items), stays at current if in top row
pub fn moveSelectionUp(current: usize, columns: usize) usize {
    if (columns == 0) return current;
    if (current >= columns) return current - columns;
    return current;
}
