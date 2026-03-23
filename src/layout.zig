const std = @import("std");

// Visual design constants
pub const THUMBNAIL_HEIGHT: u32 = 180;
pub const MAX_THUMBNAIL_WIDTH: u32 = 320;
pub const SPACING: u32 = 12;
pub const PADDING: u32 = 16;
pub const MAX_GRID_WIDTH: u32 = 1720;
pub const MAX_GRID_HEIGHT: u32 = 980;
pub const TITLE_FONT_SIZE: i32 = 16;
pub const TITLE_SPACING: u32 = 8;

pub const ThumbnailSize = struct {
    width: u32,
    height: u32,
};

pub const GridLayout = struct {
    columns: u32,
    rows: u32,
    item_height: u32,
    total_width: u32,
    total_height: u32,
};

/// Calculate display dimensions for a thumbnail, preserving aspect ratio
/// and constraining to fit within max_width x max_height.
/// Tall/narrow windows are constrained by max_height, wide/short windows by max_width.
pub fn calculateThumbnailSize(thumb_width: u32, thumb_height: u32, max_width: u32, max_height: u32) ThumbnailSize {
    if (thumb_width == 0 or thumb_height == 0) {
        return .{ .width = max_width, .height = max_height };
    }

    const aspect_ratio = @as(f32, @floatFromInt(thumb_width)) / @as(f32, @floatFromInt(thumb_height));

    // Start by fitting to max_height
    var width = @as(f32, @floatFromInt(max_height)) * aspect_ratio;
    var height = @as(f32, @floatFromInt(max_height));

    // If width exceeds max_width, constrain by max_width instead
    if (width > @as(f32, @floatFromInt(max_width))) {
        width = @as(f32, @floatFromInt(max_width));
        height = width / aspect_ratio;
    }

    const final_width = if (width < 1.0) 1 else @as(u32, @intFromFloat(width));
    const final_height = if (height < 1.0) 1 else @as(u32, @intFromFloat(height));

    return .{ .width = final_width, .height = final_height };
}
