//! Fixed-rate controller: a constant congestion window that never adapts. For
//! deterministic/lab use and as the simplest `Controller` implementation.

const std = @import("std");

pub const Fixed = struct {
    cwnd: usize = 64 * 1200,

    pub fn window(self: *const Fixed) usize {
        return self.cwnd;
    }
    pub fn onAck(self: *Fixed, acked_bytes: usize, now: i64) void {
        _ = self;
        _ = acked_bytes;
        _ = now;
    }
    pub fn onLoss(self: *Fixed, now: i64, srtt_ms: i64) void {
        _ = self;
        _ = now;
        _ = srtt_ms;
    }
};

test "fixed window is constant" {
    var cc = Fixed{ .cwnd = 9000 };
    cc.onAck(1200, 0);
    cc.onLoss(1000, 50);
    try std.testing.expectEqual(@as(usize, 9000), cc.window());
}
