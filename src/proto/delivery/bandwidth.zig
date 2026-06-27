//! Bandwidth estimation: a windowed-max over recent delivery-rate samples
//! (`min(send_rate, ack_rate)` feeds it). This is the groundwork BBR will consume;
//! for NewReno/Fixed it is telemetry. (Simplification of quinn's 3-sample MinMax.)

const std = @import("std");

pub fn WindowedMax(comptime n: usize) type {
    return struct {
        const Self = @This();
        vals: [n]u64 = [_]u64{0} ** n,
        count: usize = 0,

        pub fn push(self: *Self, v: u64) void {
            self.vals[self.count % n] = v;
            self.count += 1;
        }
        pub fn estimate(self: *const Self) u64 {
            var m: u64 = 0;
            for (self.vals) |v| m = @max(m, v);
            return m;
        }
    };
}

/// Delivery-rate sample in bytes/sec from `bytes` acked over `elapsed_ms`.
pub fn sampleRate(bytes: usize, elapsed_ms: i64) u64 {
    if (elapsed_ms <= 0) return 0;
    return @intCast(@divTrunc(@as(i64, @intCast(bytes)) * 1000, elapsed_ms));
}

const testing = std.testing;

test "windowed max tracks the recent peak" {
    var w = WindowedMax(3){};
    w.push(100);
    w.push(500);
    w.push(200);
    try testing.expectEqual(@as(u64, 500), w.estimate());
    w.push(50); // evicts 100; window is {500,200,50}
    try testing.expectEqual(@as(u64, 500), w.estimate());
    w.push(60); // evicts 500; window is {200,50,60}
    try testing.expectEqual(@as(u64, 200), w.estimate());
}

test "rate sample" {
    try testing.expectEqual(@as(u64, 1000), sampleRate(100, 100)); // 100B / 0.1s
}
