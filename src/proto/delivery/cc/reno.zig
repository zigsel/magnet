//! NewReno congestion control (integer): slow-start, ABC-style additive increase,
//! multiplicative decrease on a congestion event (≤ once per RTT). The default
//! controller. cwnd/ssthresh are in bytes.

const std = @import("std");

pub const Reno = struct {
    pub const mss: usize = 1200;
    pub const init_cwnd: usize = 10 * mss;
    const max_cwnd: usize = 1 << 26;

    cwnd: usize = init_cwnd,
    ssthresh: usize = std.math.maxInt(usize),
    congestion_events: u32 = 0,
    last_loss_ms: i64 = 0,
    has_loss: bool = false,

    pub fn window(self: *const Reno) usize {
        return self.cwnd;
    }

    pub fn onAck(self: *Reno, acked_bytes: usize, now: i64) void {
        _ = now;
        if (self.cwnd < self.ssthresh) {
            self.cwnd += acked_bytes; // slow start: exponential
        } else {
            // congestion avoidance: ~1 MSS per RTT
            self.cwnd += @max(1, mss * acked_bytes / self.cwnd);
        }
        if (self.cwnd > max_cwnd) self.cwnd = max_cwnd;
    }

    /// Congestion event (loss). Throttled to once per RTT so a burst of losses in
    /// one round only halves cwnd once.
    pub fn onLoss(self: *Reno, now: i64, srtt_ms: i64) void {
        if (self.has_loss and now - self.last_loss_ms < @max(srtt_ms, 1)) return;
        self.has_loss = true;
        self.last_loss_ms = now;
        self.ssthresh = @max(self.cwnd / 2, 2 * mss);
        self.cwnd = self.ssthresh;
        self.congestion_events += 1;
    }

    /// Persistent congestion (RFC 9002 §7.6): a whole window's worth of packets lost
    /// with no acks in between ⇒ collapse to the minimum window (the path went dark).
    pub fn onPersistentCongestion(self: *Reno) void {
        self.ssthresh = @max(self.cwnd / 2, 2 * mss);
        self.cwnd = 2 * mss;
    }

    pub const Snapshot = struct { cwnd: usize, ssthresh: usize };
    pub fn snapshot(self: *const Reno) Snapshot {
        return .{ .cwnd = self.cwnd, .ssthresh = self.ssthresh };
    }
    pub fn restore(self: *Reno, s: Snapshot) void {
        self.cwnd = s.cwnd;
        self.ssthresh = s.ssthresh;
    }
};

const testing = std.testing;

test "slow start grows exponentially then loss halves" {
    var cc = Reno{};
    const start = cc.window();
    cc.onAck(Reno.mss, 0);
    cc.onAck(Reno.mss, 0);
    try testing.expect(cc.window() == start + 2 * Reno.mss); // slow start: += acked
    const before = cc.window();
    cc.onLoss(1000, 100);
    try testing.expectEqual(@max(before / 2, 2 * Reno.mss), cc.window());
    try testing.expectEqual(@as(u32, 1), cc.congestion_events);
}

test "loss is throttled to once per RTT" {
    var cc = Reno{};
    cc.onLoss(1000, 100);
    cc.onLoss(1050, 100); // within an RTT -> ignored
    try testing.expectEqual(@as(u32, 1), cc.congestion_events);
    cc.onLoss(1200, 100); // new RTT -> counts
    try testing.expectEqual(@as(u32, 2), cc.congestion_events);
}

test "persistent congestion collapses to the minimum window" {
    var cc = Reno{};
    cc.onAck(Reno.mss * 50, 0); // grow cwnd
    try testing.expect(cc.window() > 2 * Reno.mss);
    cc.onPersistentCongestion();
    try testing.expectEqual(@as(usize, 2 * Reno.mss), cc.window());
}

test "snapshot/restore (spurious-loss recovery)" {
    var cc = Reno{};
    cc.onAck(Reno.mss * 5, 0);
    const snap = cc.snapshot();
    cc.onLoss(1000, 50);
    try testing.expect(cc.window() < snap.cwnd);
    cc.restore(snap);
    try testing.expectEqual(snap.cwnd, cc.window());
}
