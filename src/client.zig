const std = @import("std");

const log = std.log.scoped(.fasttab_client);

/// Socket path for daemon communication
pub const SOCKET_PATH = "/tmp/fasttab.sock";

pub const ClientError = error{
    SocketNotFound,
    ConnectionFailed,
    SendFailed,
    InvalidResponse,
};

/// Send SHOW command with window IDs to the daemon
pub fn sendShow(ids: []const u8) ClientError!void {
    var buf: [4096]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "SHOW {s}\n", .{ids}) catch return ClientError.SendFailed;
    try sendCommand(cmd);
}

/// Send INDEX command to set selection
pub fn sendIndex(n: []const u8) ClientError!void {
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "INDEX {s}\n", .{n}) catch return ClientError.SendFailed;
    try sendCommand(cmd);
}

/// Send HIDE command to hide the switcher window
pub fn sendHide() ClientError!void {
    try sendCommand("HIDE\n");
}

/// Send a raw command to the daemon
fn sendCommand(cmd: []const u8) ClientError!void {
    const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
        return ClientError.ConnectionFailed;
    };
    defer std.posix.close(sock);

    var addr: std.posix.sockaddr.un = .{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };

    // Copy socket path
    const path_bytes = SOCKET_PATH;
    @memcpy(addr.path[0..path_bytes.len], path_bytes);
    addr.path[path_bytes.len] = 0;

    std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        return ClientError.SocketNotFound;
    };

    _ = std.posix.write(sock, cmd) catch {
        return ClientError.SendFailed;
    };
}
