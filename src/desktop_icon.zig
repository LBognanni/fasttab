const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const IconResult = struct {
    width: i32,
    height: i32,
    pixels: []u8,

    pub fn deinit(self: *IconResult) void {
        c.stbi_image_free(self.pixels.ptr);
    }
};

const ICON_SIZES = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "48x48", "64x64", "128x128", "256x256", "512x512" };

pub fn getAppIcon(allocator: mem.Allocator, app_name: []const u8, target_size: u32) !IconResult {
    const icon_id = try findIconNameFromDesktop(allocator, app_name) orelse return error.IconNameNotFound;
    defer allocator.free(icon_id);

    if (fs.path.isAbsolute(icon_id)) {
        return try loadPng(icon_id);
    }

    const icon_path = try resolveIconPath(allocator, icon_id, target_size) orelse return error.IconFileNotFound;
    defer allocator.free(icon_path);

    return try loadPng(icon_path);
}

fn findIconNameFromDesktop(allocator: mem.Allocator, app_name: []const u8) !?[]const u8 {
    const home = std.posix.getenv("HOME") orelse "";
    const user_apps = try std.fs.path.join(allocator, &[_][]const u8{ home, ".local/share/applications" });
    defer allocator.free(user_apps);

    const search_paths = [_][]const u8{
        "/usr/share/applications",
        user_apps,
    };

    for (search_paths) |base| {
        if (!fs.path.isAbsolute(base)) continue;

        var dir = fs.openDirAbsolute(base, .{}) catch continue;
        defer dir.close();

        // Try both "obsidian.desktop" and "obsidian" (some apps differ)
        const desktop_file = if (mem.endsWith(u8, app_name, ".desktop"))
            try allocator.dupe(u8, app_name)
        else
            try std.fmt.allocPrint(allocator, "{s}.desktop", .{app_name});
        defer allocator.free(desktop_file);

        var file = dir.openFile(desktop_file, .{}) catch continue;
        defer file.close();

        var reader = std.io.bufferedReader(file.reader());
        var buf: [1024]u8 = undefined;
        while (try reader.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const trimmed = mem.trim(u8, line, " \r");
            if (mem.startsWith(u8, trimmed, "Icon=")) {
                return try allocator.dupe(u8, trimmed[5..]);
            }
        }
    }
    return null;
}

fn resolveIconPath(allocator: mem.Allocator, icon_id: []const u8, target_size: u32) !?[]const u8 {
    const icon_roots = [_][]const u8{
        "/usr/share/icons/hicolor",
        "/usr/share/pixmaps",
    };

    // Find the starting index in our standard sizes array
    var start_idx: usize = 0;
    const target_str = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ target_size, target_size });
    defer allocator.free(target_str);

    for (ICON_SIZES, 0..) |size_str, i| {
        if (mem.eql(u8, size_str, target_str)) {
            start_idx = i;
            break;
        }
    }

    // Strategy: Check requested size, then crawl UP for higher fidelity
    for (ICON_SIZES[start_idx..]) |size_dir| {
        for (icon_roots) |root| {
            const path = try std.fs.path.join(allocator, &[_][]const u8{ root, size_dir, "apps", try std.fmt.allocPrint(allocator, "{s}.png", .{icon_id}) });
            fs.accessAbsolute(path, .{}) catch {
                allocator.free(path);
                continue;
            };
            return path;
        }
    }

    // Last resort: check /usr/share/pixmaps directly (common for non-themed apps)
    const direct_pixmap = try std.fmt.allocPrint(allocator, "/usr/share/pixmaps/{s}.png", .{icon_id});
    fs.accessAbsolute(direct_pixmap, .{}) catch {
        allocator.free(direct_pixmap);
        return null;
    };
    return direct_pixmap;
}

fn loadPng(path: []const u8) !IconResult {
    var width: i32 = 0;
    var height: i32 = 0;
    var channels: i32 = 0;

    // We force 4 channels to ensure we get RGBA/ARGB consistently
    const data = c.stbi_load(path.ptr, &width, &height, &channels, 4);
    if (data == null) return error.StbLoadError;

    return IconResult{
        .width = width,
        .height = height,
        .pixels = data[0..@intCast(width * height * 4)],
    };
}
