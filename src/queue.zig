const std = @import("std");

/// Thread-safe queue for passing results between worker and main thread.
/// Generic version for testing without X11 dependencies.
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        pending_result: ?T = null,
        should_stop: bool = false,

        const Self = @This();

        pub fn push(self: *Self, result: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.pending_result) |*old| {
                if (@hasDecl(T, "deinit")) {
                    old.deinit();
                }
            }
            self.pending_result = result;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.pending_result) |result| {
                self.pending_result = null;
                return result;
            }
            return null;
        }

        pub fn requestStop(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.should_stop = true;
        }

        pub fn shouldStop(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.should_stop;
        }

        /// Clean up any pending result that was never consumed
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pending_result) |*result| {
                if (@hasDecl(T, "deinit")) {
                    result.deinit();
                }
                self.pending_result = null;
            }
        }

        /// Wait for a result with timeout. Returns null if timeout expires or stop requested.
        pub fn popBlocking(self: *Self, timeout_ms: u64) ?T {
            const start = std.time.milliTimestamp();

            while (true) {
                // Check for result
                if (self.pop()) |result| {
                    return result;
                }

                // Check for stop request
                if (self.shouldStop()) {
                    return null;
                }

                // Check timeout
                const elapsed = std.time.milliTimestamp() - start;
                if (elapsed >= @as(i64, @intCast(timeout_ms))) {
                    return null;
                }

                // Sleep briefly before retrying
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
    };
}
