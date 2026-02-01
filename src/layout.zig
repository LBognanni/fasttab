const std = @import("std");

// Visual design constants
pub const THUMBNAIL_HEIGHT: u32 = 120;
pub const SPACING: u32 = 12;
pub const PADDING: u32 = 16;
pub const MAX_GRID_WIDTH: u32 = 1720;
pub const MAX_GRID_HEIGHT: u32 = 980;
pub const TITLE_FONT_SIZE: i32 = 16;
pub const TITLE_SPACING: u32 = 8;

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
