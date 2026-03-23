const std = @import("std");
const thumbnail = @import("thumbnail.zig");
const x11 = @import("x11.zig");
const layout_module = @import("layout.zig");

pub const rl = @cImport({
    @cInclude("raylib.h");
});

// Re-export constants from layout module
pub const THUMBNAIL_HEIGHT = layout_module.THUMBNAIL_HEIGHT;
pub const SPACING = layout_module.SPACING;
pub const PADDING = layout_module.PADDING;
pub const MAX_GRID_WIDTH = layout_module.MAX_GRID_WIDTH;
pub const MAX_GRID_HEIGHT = layout_module.MAX_GRID_HEIGHT;
pub const TITLE_FONT_SIZE = layout_module.TITLE_FONT_SIZE;
pub const TITLE_SPACING = layout_module.TITLE_SPACING;

// UI-only constants
pub const SELECTION_BORDER: u32 = 3;
pub const BACKGROUND_COLOR = rl.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 217 };
pub const HIGHLIGHT_COLOR = rl.Color{ .r = 0x2d, .g = 0x8e, .b = 0xc9, .a = 128 };
pub const HIGHLIGHT_COLOR_LINES = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 255 };
pub const HIGHLIGHT_COLOR_LESS = rl.Color{ .r = 0x2d, .g = 0x8e, .b = 0xc9, .a = 64 };
pub const HIGHLIGHT_COLOR_LESS_LINES = rl.Color{ .r = 0x3d, .g = 0xae, .b = 0xe9, .a = 128 };
pub const TITLE_COLOR = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const ROUNDNESS: f32 = 0.08;

// Icon overlay constants
pub const ICON_HEIGHT_RATIO: f32 = 0.25;
pub const ICON_BOTTOM_OVERHANG: f32 = 0.05;

// Downsample shader for high-quality thumbnail scaling (embedded at compile time)
pub const DownsampleShader = struct {
    shader: rl.Shader,
    source_size_loc: c_int,
    dest_size_loc: c_int,

    // Embed shader source at compile time
    const vs_source = @embedFile("shaders/downsample.vs");
    const fs_source = @embedFile("shaders/downsample.fs");

    pub fn load() ?DownsampleShader {
        const shader = rl.LoadShaderFromMemory(vs_source, fs_source);
        if (shader.id == 0) {
            std.log.warn("Failed to load downsample shader, falling back to bilinear", .{});
            return null;
        }

        return DownsampleShader{
            .shader = shader,
            .source_size_loc = rl.GetShaderLocation(shader, "sourceSize"),
            .dest_size_loc = rl.GetShaderLocation(shader, "destSize"),
        };
    }

    pub fn unload(self: *DownsampleShader) void {
        rl.UnloadShader(self.shader);
    }

    pub fn begin(self: *const DownsampleShader, source_w: f32, source_h: f32, dest_w: f32, dest_h: f32) void {
        const source_size = [2]f32{ source_w, source_h };
        const dest_size = [2]f32{ dest_w, dest_h };
        rl.SetShaderValue(self.shader, self.source_size_loc, &source_size, rl.SHADER_UNIFORM_VEC2);
        rl.SetShaderValue(self.shader, self.dest_size_loc, &dest_size, rl.SHADER_UNIFORM_VEC2);
        rl.BeginShaderMode(self.shader);
    }

    pub fn end(_: *const DownsampleShader) void {
        rl.EndShaderMode();
    }
};

// Item holding window data for rendering
pub const DisplayWindow = struct {
    id: x11.xcb.xcb_window_t,
    title: []const u8, // owned
    thumbnail_texture: rl.Texture2D, // GPU handle
    icon_texture: ?rl.Texture2D, // non-owning copy from icon_texture_cache
    icon_id: []const u8, // owned (WM_CLASS)
    title_version: u32,
    thumbnail_version: u32,
    source_width: u32, // original thumbnail width (for layout)
    source_height: u32, // original thumbnail height (for layout)
    display_width: u32,
    display_height: u32,
    thumbnail_ready: bool,
    cached_snapshot: ?rl.RenderTexture2D,
};

// Re-export GridLayout from layout module
pub const GridLayout = layout_module.GridLayout;

// Re-export pure layout functions
pub const calculateThumbnailSize = layout_module.calculateThumbnailSize;
pub const ThumbnailSize = layout_module.ThumbnailSize;
pub const MAX_THUMBNAIL_WIDTH = layout_module.MAX_THUMBNAIL_WIDTH;

pub fn calculateGridLayout(items: []DisplayWindow, target_height: u32) GridLayout {
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
        const size = calculateThumbnailSize(item.source_width, item.source_height, MAX_THUMBNAIL_WIDTH, target_height);
        item.display_width = size.width;
        item.display_height = size.height;
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

pub fn calculateBestLayout(items: []DisplayWindow) GridLayout {
    var layout = calculateGridLayout(items, THUMBNAIL_HEIGHT);
    var current_height: u32 = THUMBNAIL_HEIGHT;
    while (layout.total_height > MAX_GRID_HEIGHT and current_height > 60) {
        current_height -= 10;
        layout = calculateGridLayout(items, current_height);
    }
    return layout;
}

pub fn calculateRowWidth(items: []DisplayWindow, start_idx: u32, count: u32) u32 {
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

pub fn getItemAtPosition(items: []DisplayWindow, layout: GridLayout, mouse_pos: rl.Vector2) ?usize {
    if (items.len == 0) return null;

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

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

            const hit_rect = rl.Rectangle{
                .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
            };

            if (rl.CheckCollisionPointRec(mouse_pos, hit_rect)) {
                return item_idx;
            }

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
    return null;
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
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
        "/usr/share/fonts/noto/NotoEmoji-Regular.ttf",
        "/usr/share/fonts/truetype/ancient-scripts/Symbola.ttf",
        "/usr/share/fonts/gd-s2/Symbola.ttf",
    };

    // Load curated list of characters to support most languages + Emojis
    var codepoints: [16384]c_int = undefined;
    var count: usize = 0;

    const ranges = [_][2]c_int{
        .{ 0x0020, 0x007E }, // Basic Latin
        .{ 0x00A0, 0x00FF }, // Latin-1 Supplement
        .{ 0x0100, 0x017F }, // Latin Extended-A
        .{ 0x0180, 0x024F }, // Latin Extended-B
        .{ 0x0250, 0x02AF }, // IPA Extensions
        .{ 0x0300, 0x036F }, // Combining Diacritical Marks
        .{ 0x0370, 0x03FF }, // Greek and Coptic
        .{ 0x0400, 0x04FF }, // Cyrillic
        .{ 0x0500, 0x052F }, // Cyrillic Supplement
        .{ 0x1E00, 0x1EFF }, // Latin Extended Additional
        .{ 0x2000, 0x20CF }, // General Punctuation & Currency
        .{ 0x2100, 0x218F }, // Letterlike Symbols & Number Forms
        .{ 0x2190, 0x21FF }, // Arrows
        .{ 0x2200, 0x22FF }, // Mathematical Operators
        .{ 0x2300, 0x23FF }, // Miscellaneous Technical
        .{ 0x2460, 0x24FF }, // Enclosed Alphanumerics
        .{ 0x2500, 0x257F }, // Box Drawing
        .{ 0x2600, 0x26FF }, // Miscellaneous Symbols
        .{ 0x2700, 0x27BF }, // Dingbats
        .{ 0xE000, 0xF8FF }, // Private Use Area (Nerd Fonts)
        .{ 0x1F600, 0x1F64F }, // Emoticons
    };

    for (ranges) |range| {
        var c = range[0];
        while (c <= range[1]) : (c += 1) {
            if (count < codepoints.len) {
                codepoints[count] = c;
                count += 1;
            }
        }
    }

    for (font_paths) |path| {
        const font = rl.LoadFontEx(path, size, &codepoints[0], @intCast(count));
        if (font.texture.id != 0) {
            rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
            return font;
        }
    }

    return rl.GetFontDefault();
}

fn drawTruncatedText(font: rl.Font, text: []const u8, x: f32, y: f32, font_size: f32, max_width: f32, color: rl.Color) void {
    const spacing: f32 = 1;
    var text_buf: [256]u8 = undefined;
    const ellipsis = "...";

    const len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..len], text[0..len]);
    text_buf[len] = 0;

    const text_ptr: [*c]const u8 = &text_buf;
    const text_size = rl.MeasureTextEx(font, text_ptr, font_size, spacing);

    if (text_size.x <= max_width) {
        const text_x = x + (max_width - text_size.x) / 2.0;
        rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = @floor(text_x), .y = @floor(y) }, font_size, spacing, color);
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
    rl.DrawTextEx(font, text_ptr, rl.Vector2{ .x = @floor(text_x), .y = @floor(y) }, font_size, spacing, color);
}

pub fn renderSwitcher(items: []DisplayWindow, layout: GridLayout, selected_index: usize, mouseover_index: ?usize, font: rl.Font, downsample_shader: ?*const DownsampleShader) void {
    if (items.len == 0) return;

    const item_full_height = layout.item_height + TITLE_SPACING + @as(u32, @intCast(TITLE_FONT_SIZE));

    const bg_rect = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(layout.total_width),
        .height = @floatFromInt(layout.total_height),
    };
    rl.DrawRectangleRounded(bg_rect, ROUNDNESS, 16, BACKGROUND_COLOR);

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
                rl.DrawRectangleRounded(highlight_rect, ROUNDNESS, 5, HIGHLIGHT_COLOR);
                rl.DrawRectangleRoundedLinesEx(highlight_rect, ROUNDNESS, 5, 2, HIGHLIGHT_COLOR_LINES);
            } else if (mouseover_index) |mi| {
                if (item_idx == mi) {
                    const highlight_rect = rl.Rectangle{
                        .x = x - @as(f32, @floatFromInt(SELECTION_BORDER)),
                        .y = y - @as(f32, @floatFromInt(SELECTION_BORDER)),
                        .width = @as(f32, @floatFromInt(item.display_width + 2 * SELECTION_BORDER)),
                        .height = @as(f32, @floatFromInt(item_full_height + 2 * SELECTION_BORDER)),
                    };
                    rl.DrawRectangleRounded(highlight_rect, ROUNDNESS, 5, HIGHLIGHT_COLOR_LESS);
                    rl.DrawRectangleRoundedLinesEx(highlight_rect, ROUNDNESS, 5, 2, HIGHLIGHT_COLOR_LESS_LINES);
                }
            }

            // Vertically center thumbnail within the item_height cell area.
            // For items shorter than item_height (wide/short windows constrained
            // by MAX_THUMBNAIL_WIDTH), this centers the preview in the cell.
            const thumb_y = y + @as(f32, @floatFromInt((layout.item_height - item.display_height) / 2));

            const dest_rect = rl.Rectangle{
                .x = x,
                .y = thumb_y,
                .width = @floatFromInt(item.display_width),
                .height = @floatFromInt(item.display_height),
            };

            const source_rect = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(item.thumbnail_texture.width),
                .height = @floatFromInt(item.thumbnail_texture.height),
            };

            if (item.thumbnail_ready) {
                // Use downsample shader for high-quality scaling if available
                if (downsample_shader) |shader| {
                    shader.begin(source_rect.width, source_rect.height, dest_rect.width, dest_rect.height);
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                    shader.end();
                } else {
                    rl.DrawTexturePro(item.thumbnail_texture, source_rect, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            } else if (item.cached_snapshot) |snapshot| {
                // Show cached snapshot of last-known thumbnail while reacquiring.
                // Negate height to flip Y — raylib RenderTextures are rendered bottom-up.
                const snap_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(snapshot.texture.width),
                    .height = -@as(f32, @floatFromInt(snapshot.texture.height)),
                };
                rl.DrawTexturePro(snapshot.texture, snap_src, dest_rect, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            } else {
                const fallback_bg = rl.Color{ .r = 0x18, .g = 0x18, .b = 0x18, .a = 230 };
                rl.DrawRectangleRounded(dest_rect, 0.06, 6, fallback_bg);

                if (item.icon_texture) |icon_tex| {
                    const thumb_h: f32 = @floatFromInt(item.display_height);
                    const thumb_w: f32 = @floatFromInt(item.display_width);
                    const icon_size = thumb_h * 0.55;
                    const icon_x = x + (thumb_w - icon_size) / 2.0;
                    const icon_y = thumb_y + (thumb_h - icon_size) / 2.0;
                    const icon_src = rl.Rectangle{
                        .x = 0,
                        .y = 0,
                        .width = @floatFromInt(icon_tex.width),
                        .height = @floatFromInt(icon_tex.height),
                    };
                    const icon_dst = rl.Rectangle{
                        .x = icon_x,
                        .y = icon_y,
                        .width = icon_size,
                        .height = icon_size,
                    };
                    rl.DrawTexturePro(icon_tex, icon_src, icon_dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                }
            }

            // Draw icon overlay at bottom-center of grid cell (when live texture or cached snapshot is shown).
            // Uses item_height (not display_height) so the icon stays a consistent size
            // even for wide/short windows that have a smaller display_height.
            if ((item.thumbnail_ready or item.cached_snapshot != null) and item.icon_texture != null) {
                const icon_tex = item.icon_texture.?;
                const cell_h: f32 = @floatFromInt(layout.item_height);
                const thumb_w: f32 = @floatFromInt(item.display_width);
                const icon_size = cell_h * ICON_HEIGHT_RATIO;
                const icon_x = x + (thumb_w - icon_size) / 2.0;
                const icon_y = y + cell_h - icon_size + (cell_h * ICON_BOTTOM_OVERHANG);
                const icon_src = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(icon_tex.width),
                    .height = @floatFromInt(icon_tex.height),
                };
                const icon_dst = rl.Rectangle{
                    .x = icon_x,
                    .y = icon_y,
                    .width = icon_size,
                    .height = icon_size,
                };
                rl.DrawTexturePro(icon_tex, icon_src, icon_dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
            }

            // Title is always positioned at the bottom of the cell
            const title_y = y + @as(f32, @floatFromInt(layout.item_height + TITLE_SPACING));
            drawTruncatedText(font, item.title, x, title_y, @floatFromInt(TITLE_FONT_SIZE), @floatFromInt(item.display_width), TITLE_COLOR);

            x += @as(f32, @floatFromInt(item.display_width + SPACING));
            item_idx += 1;
        }
    }
}
