//! Lock-free single-producer / single-consumer queue - the ONLY cross-thread
//! structure in magnet. Used to hand `send` intents and `receive` results across
//! an app↔net thread boundary when the topology separates them. Bounded,
//! allocation-free; the only atomics in the library live here.
//!
//! Correctness rests on: the producer owns `tail`, the consumer owns `head`,
//! each publishes with release and observes the other with acquire.

const std = @import("std");

pub fn Spsc(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("Spsc capacity must be a power of two");
    }
    return struct {
        const Self = @This();
        pub const cap = capacity;
        const mask = capacity - 1;

        buf: [capacity]T = undefined,
        // Monotonically increasing counters (indices are `& mask`). 64-bit on
        // 64-bit targets means no practical wrap. Cache-line separated to avoid
        // false sharing between producer and consumer.
        head: usize align(64) = 0, // consumer-owned (next to read)
        tail: usize align(64) = 0, // producer-owned (next to write)

        pub fn init() Self {
            return .{};
        }

        /// Producer side. Returns false if full.
        pub fn push(self: *Self, value: T) bool {
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            const head = @atomicLoad(usize, &self.head, .acquire);
            if (tail -% head >= capacity) return false;
            self.buf[tail & mask] = value;
            @atomicStore(usize, &self.tail, tail +% 1, .release);
            return true;
        }

        /// Consumer side.
        pub fn pop(self: *Self) ?T {
            const head = @atomicLoad(usize, &self.head, .monotonic);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            if (head == tail) return null;
            const v = self.buf[head & mask];
            @atomicStore(usize, &self.head, head +% 1, .release);
            return v;
        }

        pub fn isEmpty(self: *Self) bool {
            return @atomicLoad(usize, &self.head, .acquire) == @atomicLoad(usize, &self.tail, .acquire);
        }

        pub fn len(self: *Self) usize {
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            const head = @atomicLoad(usize, &self.head, .acquire);
            return tail -% head;
        }
    };
}

const testing = std.testing;

test "spsc single-threaded fifo, full/empty" {
    var q = Spsc(u32, 4).init();
    try testing.expect(q.isEmpty());
    try testing.expect(q.push(1));
    try testing.expect(q.push(2));
    try testing.expect(q.push(3));
    try testing.expect(q.push(4));
    try testing.expect(!q.push(5)); // full
    try testing.expectEqual(@as(usize, 4), q.len());
    try testing.expectEqual(@as(u32, 1), q.pop().?);
    try testing.expect(q.push(5));
    try testing.expectEqual(@as(u32, 2), q.pop().?);
    try testing.expectEqual(@as(u32, 3), q.pop().?);
    try testing.expectEqual(@as(u32, 4), q.pop().?);
    try testing.expectEqual(@as(u32, 5), q.pop().?);
    try testing.expect(q.pop() == null);
}

const StressQ = Spsc(u32, 1024);
const stress_n: u32 = 200_000;

fn stressProducer(q: *StressQ) void {
    var i: u32 = 0;
    while (i < stress_n) : (i += 1) {
        while (!q.push(i)) {} // spin on full
    }
}

test "spsc threaded stress preserves order and count" {
    var q = StressQ.init();
    const t = try std.Thread.spawn(.{}, stressProducer, .{&q});
    var expect: u32 = 0;
    var sum: u64 = 0;
    while (expect < stress_n) {
        if (q.pop()) |v| {
            try testing.expectEqual(expect, v); // strict FIFO across threads
            sum +%= v;
            expect += 1;
        }
    }
    t.join();
    // 0 + 1 + ... + (n-1)
    const n: u64 = stress_n;
    try testing.expectEqual((n * (n - 1)) / 2, sum);
}
