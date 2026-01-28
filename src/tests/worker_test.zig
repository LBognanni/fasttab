const std = @import("std");
const queue = @import("queue");

const testing = std.testing;

// Test result type (simple struct for testing)
const TestResult = struct {
    value: u32,
    freed: bool = false,

    pub fn deinit(self: *TestResult) void {
        self.freed = true;
    }
};

// Use u32 as window ID type for testing
const TestQueue = queue.Queue(TestResult);

test "pop on empty queue returns null" {
    var q = TestQueue{};
    defer q.deinit();

    const result = q.pop();
    try testing.expectEqual(@as(?TestResult, null), result);
}

test "push then pop returns the pushed value" {
    var q = TestQueue{};
    defer q.deinit();

    q.push(TestResult{ .value = 42 });
    const result = q.pop();

    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 42), result.?.value);
}

test "pop removes item from queue" {
    var q = TestQueue{};
    defer q.deinit();

    q.push(TestResult{ .value = 42 });
    _ = q.pop();
    const second_pop = q.pop();

    try testing.expectEqual(@as(?TestResult, null), second_pop);
}

test "double push single pop returns latest value" {
    var q = TestQueue{};
    defer q.deinit();

    q.push(TestResult{ .value = 1 });
    q.push(TestResult{ .value = 2 });

    const result = q.pop();
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 2), result.?.value);
}

test "requestStop sets stop flag" {
    var q = TestQueue{};
    defer q.deinit();

    try testing.expectEqual(false, q.shouldStop());

    q.requestStop();

    try testing.expectEqual(true, q.shouldStop());
}

test "shouldStop initially returns false" {
    var q = TestQueue{};
    defer q.deinit();

    try testing.expectEqual(false, q.shouldStop());
}

test "popBlocking returns null on timeout" {
    var q = TestQueue{};
    defer q.deinit();

    const start = std.time.milliTimestamp();
    const result = q.popBlocking(50);
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expectEqual(@as(?TestResult, null), result);
    try testing.expect(elapsed >= 50);
}

test "popBlocking returns null when stop requested" {
    var q = TestQueue{};
    defer q.deinit();

    q.requestStop();
    const result = q.popBlocking(1000);

    try testing.expectEqual(@as(?TestResult, null), result);
}

test "popBlocking returns result when available" {
    var q = TestQueue{};
    defer q.deinit();

    q.push(TestResult{ .value = 99 });
    const result = q.popBlocking(100);

    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 99), result.?.value);
}

test "deinit cleans up pending result" {
    var q = TestQueue{};

    q.push(TestResult{ .value = 42 });
    // deinit should clean up the pending result
    q.deinit();

    // After deinit, pop should return null
    const result = q.pop();
    try testing.expectEqual(@as(?TestResult, null), result);
}

test "multiple operations in sequence" {
    var q = TestQueue{};
    defer q.deinit();

    // Push, pop, push, pop sequence
    q.push(TestResult{ .value = 1 });
    const r1 = q.pop();
    try testing.expectEqual(@as(u32, 1), r1.?.value);

    q.push(TestResult{ .value = 2 });
    q.push(TestResult{ .value = 3 }); // Overwrites 2
    const r2 = q.pop();
    try testing.expectEqual(@as(u32, 3), r2.?.value);

    const r3 = q.pop();
    try testing.expectEqual(@as(?TestResult, null), r3);
}

// Test with a type that doesn't have deinit
const SimpleResult = struct {
    value: u32,
};

const SimpleQueue = queue.Queue(SimpleResult);

test "queue works with type without deinit" {
    var q = SimpleQueue{};
    defer q.deinit();

    q.push(SimpleResult{ .value = 100 });
    const result = q.pop();

    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 100), result.?.value);
}

test "queue with type without deinit handles overwrite" {
    var q = SimpleQueue{};
    defer q.deinit();

    q.push(SimpleResult{ .value = 1 });
    q.push(SimpleResult{ .value = 2 }); // Should not crash even without deinit

    const result = q.pop();
    try testing.expectEqual(@as(u32, 2), result.?.value);
}
