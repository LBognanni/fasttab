const std = @import("std");

// Visual design constants
pub const THUMBNAIL_HEIGHT: u32 = 100;
pub const SPACING: u32 = 12;
pub const PADDING: u32 = 16;
pub const MAX_GRID_WIDTH: u32 = 1820;
pub const MAX_GRID_HEIGHT: u32 = 980;
pub const TITLE_FONT_SIZE: i32 = 14;
pub const TITLE_SPACING: u32 = 8;

// Pure layout item for testing (no raylib dependencies)
pub const LayoutItem = struct {
    thumb_width: u32,
    thumb_height: u32,
    display_width: u32 = 0,
    display_height: u32 = 0,
};

pub const GridLayout = struct {
    columns: u32,
    rows: u32,
    item_height: u32,
    total_width: u32,
    total_height: u32,
};

pub fn calculateItemWidth(thumb_width: u32, thumb_height: u32, target_height: u32) u32 {
    if (thumb_height == 0) return target_height;
    const aspect_ratio = @as(f32, @floatFromInt(thumb_width)) / @as(f32, @floatFromInt(thumb_height));
    const width = @as(f32, @floatFromInt(target_height)) * aspect_ratio;
    if (width < 1.0) return 1;
    return @intFromFloat(width);
}

pub fn calculateGridLayoutGeneric(items: []LayoutItem, target_height: u32) GridLayout {
    if (items.len == 0) {
        return GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = target_height,
            .total_width = PADDING * 2,
            .total_height = PADDING * 2,
        };
    }

    var total_item_width: u32 = 0;
    for (items) |*item| {
        item.display_height = target_height;
        item.display_width = calculateItemWidth(item.thumb_width, item.thumb_height, target_height);
        total_item_width += item.display_width;
    }

    const item_full_height = target_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    var best_columns: u32 = 1;
    var best_rows: u32 = @intCast(items.len);

    var cols: u32 = 1;
    while (cols <= items.len) : (cols += 1) {
        const rows = (items.len + cols - 1) / cols;

        const avg_width = total_item_width / @as(u32, @intCast(items.len));
        const estimated_width = PADDING * 2 + cols * avg_width + (cols - 1) * SPACING;
        const estimated_height = PADDING * 2 + @as(u32, @intCast(rows)) * item_full_height + (@as(u32, @intCast(rows)) - 1) * SPACING;

        if (estimated_width <= MAX_GRID_WIDTH and estimated_height <= MAX_GRID_HEIGHT) {
            best_columns = cols;
            best_rows = @intCast(rows);
        } else if (estimated_width > MAX_GRID_WIDTH) {
            break;
        }
    }

    var max_row_width: u32 = 0;
    var row_start: u32 = 0;
    while (row_start < items.len) {
        const items_in_row = @min(best_columns, @as(u32, @intCast(items.len)) - row_start);
        const row_width = calculateRowWidthGeneric(items, row_start, items_in_row);
        if (row_width > max_row_width) {
            max_row_width = row_width;
        }
        row_start += best_columns;
    }
    const total_width = PADDING * 2 + max_row_width;
    const total_height = PADDING * 2 + best_rows * item_full_height + (best_rows - 1) * SPACING;

    return GridLayout{
        .columns = best_columns,
        .rows = best_rows,
        .item_height = target_height,
        .total_width = total_width,
        .total_height = total_height,
    };
}

pub fn calculateRowWidthGeneric(items: []const LayoutItem, start_idx: u32, count: u32) u32 {
    var width: u32 = 0;
    const end = @min(start_idx + count, @as(u32, @intCast(items.len)));
    var i = start_idx;
    while (i < end) : (i += 1) {
        width += items[i].display_width;
        if (i < end - 1) {
            width += SPACING;
        }
    }
    return width;
}
