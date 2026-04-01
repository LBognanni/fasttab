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

/// Returns an owned copy of the XDG data home directory path.
fn xdgDataHome(allocator: mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |v| return allocator.dupe(u8, v);
    const home = std.posix.getenv("HOME") orelse "";
    return fs.path.join(allocator, &.{ home, ".local/share" });
}

fn findIconNameFromDesktop(allocator: mem.Allocator, app_name: []const u8) !?[]const u8 {
    const data_home = try xdgDataHome(allocator);
    defer allocator.free(data_home);

    // Build search dirs per XDG Base Directory spec:
    // $XDG_DATA_HOME/applications, then each $XDG_DATA_DIRS entry/applications
    var search_dirs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (search_dirs.items) |dir| allocator.free(dir);
        search_dirs.deinit();
    }

    try search_dirs.append(try fs.path.join(allocator, &.{ data_home, "applications" }));

    const xdg_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = mem.splitScalar(u8, xdg_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try search_dirs.append(try fs.path.join(allocator, &.{ dir, "applications" }));
    }

    const desktop_file = if (mem.endsWith(u8, app_name, ".desktop"))
        try allocator.dupe(u8, app_name)
    else
        try std.fmt.allocPrint(allocator, "{s}.desktop", .{app_name});
    defer allocator.free(desktop_file);

    // Pass 1: exact filename match
    for (search_dirs.items) |base| {
        if (!fs.path.isAbsolute(base)) continue;

        var dir = fs.openDirAbsolute(base, .{}) catch continue;
        defer dir.close();

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

    // Pass 2: scan all .desktop files for StartupWMClass= match.
    // Handles apps like JetBrains Toolbox that append UUIDs to desktop filenames.
    for (search_dirs.items) |base| {
        if (!fs.path.isAbsolute(base)) continue;
        var dir = fs.openDirAbsolute(base, .{ .iterate = true }) catch continue;
        defer dir.close();
        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            if (!mem.endsWith(u8, entry.name, ".desktop")) continue;
            if (try scanDesktopForWMClass(allocator, dir, entry.name, app_name)) |icon| {
                return icon;
            }
        }
    }

    return null;
}

/// Read a single .desktop file and return the Icon= value if StartupWMClass= matches wm_class.
/// Returns null if the file doesn't match or can't be read.
fn scanDesktopForWMClass(allocator: mem.Allocator, dir: fs.Dir, filename: []const u8, wm_class: []const u8) !?[]const u8 {
    var file = dir.openFile(filename, .{}) catch return null;
    defer file.close();

    var icon_val: ?[]const u8 = null;
    errdefer if (icon_val) |v| allocator.free(v);

    var wm_class_matches = false;
    var reader = std.io.bufferedReader(file.reader());
    var buf: [1024]u8 = undefined;
    while (reader.reader().readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
        const t = mem.trim(u8, line, " \r");
        if (icon_val == null and mem.startsWith(u8, t, "Icon="))
            icon_val = try allocator.dupe(u8, t[5..]);
        if (mem.startsWith(u8, t, "StartupWMClass=") and mem.eql(u8, t[15..], wm_class))
            wm_class_matches = true;
    }

    if (wm_class_matches) return icon_val;
    if (icon_val) |v| allocator.free(v);
    return null;
}

fn resolveIconPath(allocator: mem.Allocator, icon_id: []const u8, target_size: u32) !?[]const u8 {
    const data_home = try xdgDataHome(allocator);
    defer allocator.free(data_home);

    // Build hicolor roots per XDG spec:
    // $XDG_DATA_HOME/icons/hicolor, then each $XDG_DATA_DIRS entry/icons/hicolor
    var hicolor_roots = std.ArrayList([]const u8).init(allocator);
    defer {
        for (hicolor_roots.items) |dir| allocator.free(dir);
        hicolor_roots.deinit();
    }

    try hicolor_roots.append(try fs.path.join(allocator, &.{ data_home, "icons/hicolor" }));

    const xdg_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = mem.splitScalar(u8, xdg_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try hicolor_roots.append(try fs.path.join(allocator, &.{ dir, "icons/hicolor" }));
    }

    // Find starting index for target size
    var start_idx: usize = 0;
    const target_str = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ target_size, target_size });
    defer allocator.free(target_str);
    for (ICON_SIZES, 0..) |size_str, i| {
        if (mem.eql(u8, size_str, target_str)) {
            start_idx = i;
            break;
        }
    }

    const icon_filename = try std.fmt.allocPrint(allocator, "{s}.png", .{icon_id});
    defer allocator.free(icon_filename);

    // Strategy: Check requested size, then crawl UP for higher fidelity
    for (ICON_SIZES[start_idx..]) |size_dir| {
        for (hicolor_roots.items) |root| {
            const path = try fs.path.join(allocator, &.{ root, size_dir, "apps", icon_filename });
            fs.accessAbsolute(path, .{}) catch {
                allocator.free(path);
                continue;
            };
            return path;
        }
    }

    // Last resort: check pixmaps in each XDG data dir (common for non-themed apps)
    var it2 = mem.splitScalar(u8, xdg_dirs, ':');
    while (it2.next()) |dir| {
        if (dir.len == 0) continue;
        const path = try fs.path.join(allocator, &.{ dir, "pixmaps", icon_filename });
        fs.accessAbsolute(path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }

    return null;
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
