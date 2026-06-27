//! Integer RTT estimator (QUIC RFC 9002 §5): latest / min / smoothed / variance,
//! plus the PTO base. Milliseconds, no floats - transport replay stays reproducible.

const std = @import("std");

pub const Rtt = struct {
    has: bool = false,
    latest_ms: i64 = 0,
    min_ms: i64 = 0,
    smoothed_ms: i64 = 0,
    var_ms: i64 = 0,

    pub fn sample(self: *Rtt, r_ms: i64) void {
        const r = if (r_ms < 0) 0 else r_ms;
        self.latest_ms = r;
        if (!self.has) {
            self.has = true;
            self.min_ms = r;
            self.smoothed_ms = r;
            self.var_ms = @divTrunc(r, 2);
            return;
        }
        self.min_ms = @min(self.min_ms, r);
        const d = @as(i64, @intCast(@abs(self.smoothed_ms - r)));
        self.var_ms = @divTrunc(3 * self.var_ms + d, 4);
        self.smoothed_ms = @divTrunc(7 * self.smoothed_ms + r, 8);
    }

    /// Probe-timeout base = smoothed + max(4·var, 1ms).
    pub fn pto(self: *const Rtt) i64 {
        if (!self.has) return 200;
        return self.smoothed_ms + @max(4 * self.var_ms, 1);
    }
};

const testing = std.testing;

test "rtt converges toward a steady sample" {
    var rtt = Rtt{};
    var i: usize = 0;
    while (i < 50) : (i += 1) rtt.sample(100);
    try testing.expect(rtt.smoothed_ms >= 95 and rtt.smoothed_ms <= 105);
    try testing.expectEqual(@as(i64, 100), rtt.min_ms);
    try testing.expect(rtt.pto() >= rtt.smoothed_ms);
}

test "rtt tracks min across a spike" {
    var rtt = Rtt{};
    rtt.sample(80);
    rtt.sample(300);
    rtt.sample(85);
    try testing.expectEqual(@as(i64, 80), rtt.min_ms);
}
