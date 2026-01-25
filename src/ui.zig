const std = @import("std");
const thumbnail = @import("thumbnail.zig");
const x11 = @import("x11.zig");

pub const rl = @cImport({
    @cInclude("raylib.h");
});

// Visual design constants
pub const THUMBNAIL_HEIGHT: u32 = 100;
pub const SPACING: u32 = 12;
pub const PADDING: u32 = 16;
pub const CORNER_RADIUS: f32 = 12.0;
pub const ITEM_CORNER_RADIUS: f32 = 4.0;
pub const MAX_GRID_WIDTH: u32 = 1820;
pub const MAX_GRID_HEIGHT: u32 = 980;
pub const TITLE_FONT_SIZE: i32 = 14;
pub const TITLE_SPACING: u32 = 8;
pub const SELECTION_BORDER: u32 = 3;
pub const BACKGROUND_COLOR = rl.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 217 };
pub const HIGHLIGHT_COLOR = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 255 };
pub const TITLE_COLOR = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

// Item holding window data for rendering
pub const WindowItem = struct {
    id: x11.xcb.xcb_window_t,
    title: []const u8,
    thumbnail: thumbnail.Thumbnail,
    texture: rl.Texture2D,
    display_width: u32,
    display_height: u32,
};

pub const GridLayout = struct {
    columns: u32,
    rows: u32,
    item_height: u32,
    total_width: u32,
    total_height: u32,
};

fn calculateItemWidth(thumb_width: u32, thumb_height: u32, target_height: u32) u32 {
    if (thumb_height == 0) return target_height;
    const aspect_ratio = @as(f32, @floatFromInt(thumb_width)) / @as(f32, @floatFromInt(thumb_height));
    const width = @as(f32, @floatFromInt(target_height)) * aspect_ratio;
    if (width < 1.0) return 1;
    return @intFromFloat(width);
}

pub fn calculateGridLayout(items: []WindowItem, target_height: u32) GridLayout {
    if (items.len == 0) {
        return GridLayout{
            .columns = 0,
            .rows = 0,
            .item_height = target_height,
            .total_width = PADDING * 2,
            .total_height = PADDING * 2,
        };
    }

    var max_item_width: u32 = 0;
    var total_item_width: u32 = 0;
    for (items) |*item| {
        item.display_height = target_height;
        item.display_width = calculateItemWidth(item.thumbnail.width, item.thumbnail.height, target_height);
        if (item.display_width > max_item_width) {
            max_item_width = item.display_width;
        }
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
        const row_width = calculateRowWidth(items, row_start, items_in_row);
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

pub fn calculateRowWidth(items: []WindowItem, start_idx: u32, count: u32) u32 {
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

pub fn loadTextureFromThumbnail(thumb: *const thumbnail.Thumbnail) rl.Texture2D {
    const image = rl.Image{
        .data = thumb.data.ptr,
        .width = @intCast(thumb.width),
        .height = @intCast(thumb.height),
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        .mipmaps = 1,
    };
    const texture = rl.LoadTextureFromImage(image);
    rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_BILINEAR);
    return texture;
}

pub fn loadSystemFont(size: i32) rl.Font {
    const font_paths = [_][*c]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
    };

    for (font_paths) |path| {
        const font = rl.LoadFontEx(path, size, null, 0);
        if (font.texture.id != 0) {
            rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
            return font;
        }
    }

    return rl.GetFontDefault();
}

fn drawTruncatedText(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color) void {
    const spacing: f32 = 0;
    var text_buf: [256]u8 = undefined;
    const ellipsis = "...";

    const len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..len], text[0..len]);
    text_buf[len] = 0;

    const text_ptr: [*c]const u8 = &text_buf;
    const text_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);

    if (text_size.x <= max_width) {
        const text_x = x + (max_width - text_size.x) / 2.0;
        rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = text_x, .y = y }, font_size, spacing, color);
        return;
    }

    const ellipsis_size = rl.MeasureTextEx(font, ellipsis, font_size, spacing);
    const available_width = max_width - ellipsis_size.x;

    var fit_len: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const saved_char = text_buf[i + 1];
        text_buf[i + 1] = 0;
        const partial_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
        text_buf[i + 1] = saved_char;
        if (partial_size.x > available_width) break;
        fit_len = i + 1;
    }

    if (fit_len > 0) {
        @memcpy(text_buf[fit_len .. fit_len + 3], ellipsis);
        text_buf[fit_len + 3] = 0;
    } else {
        @memcpy(text_buf[0..3], ellipsis);
        text_buf[3] = 0;
    }

    const final_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);
    const text_x = x + (max_width - final_size.x) / 2.0;
    rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = text_x, .y = y }, font_size, spacing, color);
}

pub fn renderSwitcher(items: []WindowItem, selected_index: usize, font: rl.Font) void {
    if (items.len == 0) return;

    var layout = calculateGridLayout(items, THUMBNAIL_HEIGHT);

    var current_height = THUMBNAIL_HEIGHT;
    while (layout.total_height > MAX_GRID_HEIGHT and current_height > 60) {
        current_height -= 10;
        layout = calculateGridLayout(items, current_height);
    }

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    const bg_rect = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(layout.total_width),
        .height = @floatFromInt(layout.total_height),
    };
    rl.DrawRectangleRounded(bg_rect, CORNER_RADIUS / @as(f32, @floatFromInt(@max(layout.total_width, layout.total_height))), 16, BACKGROUND_COLOR);

    var item_idx: usize = 0;
    var row: u32 = 0;
    while (row < layout.rows and item_idx < items.len) : (row += 1) {
        const items_in_row = @min(layout.columns, @as(u32, @intCast(items.len)) - @as(u32, @intCast(item_idx)));

        const row_width = calculateRowWidth(items, @intCast(item_idx), items_in_row);
        var x: f32 = @floatFromInt(PADDING + (layout.total_width - 2 * PADDING - row_width) / 2);
        const y: f32 = @floatFromInt(PADDING + row * (item_full_height + SPACING));

        var col: u32 = 0;
        while (col < items_in_row) : (col += 1) {
            const item = &items[item_idx];
            const is_selected = item_idx == selected_index;

            if (is_selected) {
                const highlight_rect = rl.Rectangle{
                    .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                    .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                    .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
                };
                rl.DrawRectangleRounded(highlight_rect, ITEM_CORNER_RADIUS / @as(f32, @floatFromInt(@max(item.display_width, item_full_height))), 8, HIGHLIGHT_COLOR);
            }

            const dest_rect = rl.Rectangle{
                .x = x,
                .y = y,
                .width = @floatFromInt(item.display_width),
                .height = @floatFromInt(item.display_height),
            };
            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.texture.width),
                .height = @floatFromInt(item.texture.height),
            };
            rl.DrawTexturePro(item.texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);

            const title_y = y + @as(f32, @floatFromInt(item.display_height + TITLE_SPACING));
            drawTruncatedText(font, item.title, x, title_y, @floatFromInt(TITLE_FONT_SIZE), @floatFromInt(item.display_width), TITLE_COLOR);

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
}
