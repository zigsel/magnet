//! Fixed-capacity single-threaded ring buffer (power-of-two capacity).
//! Used for event queues and FIFO scratch. The cross-thread variant lives in
//! `spsc.zig` (added with the runtime drivers).

const std = @import("std");

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("Ring capacity must be a power of two");
    }
    return struct {
        const Self = @This();
        pub const cap = capacity;
        const mask = capacity - 1;

        buf: [capacity]T = undefined,
        head: usize = 0, // next read
        tail: usize = 0, // next write
        len_: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn len(self: *const Self) usize {
            return self.len_;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len_ == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len_ == capacity;
        }

        /// Push to the back. Returns false (no-op) if full.
        pub fn push(self: *Self, value: T) bool {
            if (self.len_ == capacity) return false;
            self.buf[self.tail & mask] = value;
            self.tail +%= 1;
            self.len_ += 1;
            return true;
        }

        /// Pop from the front.
        pub fn pop(self: *Self) ?T {
            if (self.len_ == 0) return null;
            const v = self.buf[self.head & mask];
            self.head +%= 1;
            self.len_ -= 1;
            return v;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.len_ == 0) return null;
            return self.buf[self.head & mask];
        }

        /// Overwrite the oldest entry when full (drop-oldest semantics).
        pub fn pushOverwrite(self: *Self, value: T) void {
            if (self.len_ == capacity) _ = self.pop();
            _ = self.push(value);
        }
    };
}

const testing = std.testing;

test "ring fifo order, full/empty" {
    var r = Ring(u32, 4).init();
    try testing.expect(r.isEmpty());
    try testing.expect(r.push(1));
    try testing.expect(r.push(2));
    try testing.expect(r.push(3));
    try testing.expect(r.push(4));
    try testing.expect(r.isFull());
    try testing.expect(!r.push(5)); // full
    try testing.expectEqual(@as(u32, 1), r.pop().?);
    try testing.expectEqual(@as(u32, 2), r.peek().?);
    try testing.expect(r.push(5));
    try testing.expectEqual(@as(u32, 2), r.pop().?);
    try testing.expectEqual(@as(u32, 3), r.pop().?);
    try testing.expectEqual(@as(u32, 4), r.pop().?);
    try testing.expectEqual(@as(u32, 5), r.pop().?);
    try testing.expect(r.pop() == null);
}

test "ring pushOverwrite drops oldest" {
    var r = Ring(u8, 2).init();
    r.pushOverwrite(1);
    r.pushOverwrite(2);
    r.pushOverwrite(3); // drops 1
    try testing.expectEqual(@as(u8, 2), r.pop().?);
    try testing.expectEqual(@as(u8, 3), r.pop().?);
    try testing.expect(r.isEmpty());
}
