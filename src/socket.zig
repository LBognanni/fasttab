const std = @import("std");
const client = @import("client.zig");

const log = std.log.scoped(.fasttab_socket);

pub const SOCKET_PATH = client.SOCKET_PATH;

pub const SocketError = error{
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ReadFailed,
    InvalidCommand,
};

/// Parsed socket command
pub const Command = union(enum) {
    /// Show switcher with specified window IDs in order
    show: []const u32,
    /// Set selection to specified index
    index: usize,
    /// Hide the switcher window
    hide: void,
};

/// Unix socket server for receiving commands from CLI
pub const SocketServer = struct {
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the socket server
    pub fn init(allocator: std.mem.Allocator) !Self {
        // Remove existing socket file
        std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};

        const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(sock);

        var addr: std.posix.sockaddr.un = .{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };

        // Copy socket path
        const path_bytes = SOCKET_PATH;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);
        addr.path[path_bytes.len] = 0;

        std.posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
            return SocketError.BindFailed;
        };

        // Set permissions to user-only (0600)
        std.posix.fchmodat(std.posix.AT.FDCWD, SOCKET_PATH, 0o600, 0) catch |err| {
            log.warn("Failed to set socket permissions: {}", .{err});
        };

        std.posix.listen(sock, 5) catch {
            return SocketError.ListenFailed;
        };

        log.info("Socket server listening on {s}", .{SOCKET_PATH});

        return Self{
            .fd = sock,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        std.posix.close(self.fd);
        std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};
    }

    /// Get the file descriptor for polling
    pub fn getFd(self: *const Self) std.posix.fd_t {
        return self.fd;
    }

    /// Accept a connection and read a command (non-blocking)
    /// Returns null if no command available
    pub fn acceptAndRead(self: *Self) ?ParsedCommand {
        const client_fd = std.posix.accept(self.fd, null, null, 0) catch |err| {
            if (err == error.WouldBlock) {
                return null;
            }
            log.warn("Accept failed: {}", .{err});
            return null;
        };
        defer std.posix.close(client_fd);

        var buf: [4096]u8 = undefined;
        const n = std.posix.read(client_fd, &buf) catch |err| {
            log.warn("Read failed: {}", .{err});
            return null;
        };

        if (n == 0) {
            return null;
        }

        return self.parseCommand(buf[0..n]);
    }

    /// Parse a raw command string
    fn parseCommand(self: *Self, data: []const u8) ?ParsedCommand {
        // Trim whitespace/newlines
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) {
            return null;
        }

        // Parse command type
        if (std.mem.startsWith(u8, trimmed, "SHOW ")) {
            const ids_str = trimmed[5..];
            return self.parseShowCommand(ids_str);
        } else if (std.mem.startsWith(u8, trimmed, "INDEX ")) {
            const idx_str = trimmed[6..];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                log.warn("Invalid INDEX argument: {s}", .{idx_str});
                return null;
            };
            return ParsedCommand{ .command = .{ .index = idx } };
        } else if (std.mem.eql(u8, trimmed, "HIDE")) {
            return ParsedCommand{ .command = .{ .hide = {} } };
        }

        log.warn("Unknown command: {s}", .{trimmed});
        return null;
    }

    /// Parse SHOW command arguments (comma-separated window IDs)
    fn parseShowCommand(self: *Self, ids_str: []const u8) ?ParsedCommand {
        // Count commas to determine array size
        var count: usize = 1;
        for (ids_str) |c| {
            if (c == ',') count += 1;
        }

        const ids = self.allocator.alloc(u32, count) catch {
            log.err("Failed to allocate window ID array", .{});
            return null;
        };
        errdefer self.allocator.free(ids);

        var iter = std.mem.splitScalar(u8, ids_str, ',');
        var i: usize = 0;
        while (iter.next()) |id_str| {
            const trimmed_id = std.mem.trim(u8, id_str, " ");
            ids[i] = std.fmt.parseInt(u32, trimmed_id, 10) catch {
                log.warn("Invalid window ID: {s}", .{trimmed_id});
                self.allocator.free(ids);
                return null;
            };
            i += 1;
        }

        return ParsedCommand{
            .command = .{ .show = ids },
            .owned_ids = ids,
        };
    }
};

/// Parsed command with optional owned memory
pub const ParsedCommand = struct {
    command: Command,
    /// If command is .show, this holds the allocated array that must be freed
    owned_ids: ?[]const u32 = null,

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        if (self.owned_ids) |ids| {
            allocator.free(ids);
            self.owned_ids = null;
        }
    }
};
