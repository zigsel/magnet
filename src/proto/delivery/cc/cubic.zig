//! CUBIC congestion control (RFC 8312), integer / fixed-point - no floats, so it
//! is safe on the deterministic transport path. Works in segments internally;
//! cwnd is in bytes. K is computed in milliseconds via an integer cube root.
//!
//! Standalone + tested here; wiring it (and BBR) into the connection as a
//! comptime-selectable controller lands with the `Config` work. The
//! connection currently embeds NewReno.

const std = @import("std");

/// Integer cube root: floor(x^(1/3)).
fn icbrt(x: u64) u64 {
    if (x == 0) return 0;
    var lo: u64 = 0;
    var hi: u64 = 2_100_000; // (2.1e6)^3 ≈ 9.26e18 < maxInt(u64)
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (@as(u128, mid) * mid * mid <= x) lo = mid else hi = mid - 1;
    }
    return lo;
}

pub const Cubic = struct {
    pub const mss: usize = 1200;
    pub const init_cwnd: usize = 10 * mss;
    const max_cwnd: usize = 1 << 26;

    cwnd: usize = init_cwnd,
    ssthresh: usize = std.math.maxInt(usize),
    w_max_seg: usize = 0, // cwnd (in segments) at last loss
    origin_seg: usize = 0,
    epoch_ms: i64 = 0,
    k_ms: i64 = 0,
    has_epoch: bool = false,
    congestion_events: u32 = 0,
    last_loss_ms: i64 = 0,
    has_loss: bool = false,

    pub fn window(self: *const Cubic) usize {
        return self.cwnd;
    }

    pub fn onAck(self: *Cubic, acked_bytes: usize, now: i64) void {
        if (self.cwnd < self.ssthresh) {
            self.cwnd += acked_bytes; // slow start
            return;
        }
        if (!self.has_epoch) {
            self.has_epoch = true;
            self.epoch_ms = now;
            const w_now_seg = self.cwnd / mss;
            if (self.w_max_seg > w_now_seg) {
                self.origin_seg = self.w_max_seg;
                // K = cbrt(w_max·(1-beta)/C) seconds, beta=0.7 C=0.4 → w_max·0.75;
                // K_ms = cbrt(w_max·0.75 · 1e9).
                const y = self.w_max_seg * 3 / 4;
                self.k_ms = @intCast(icbrt(@as(u64, y) * 1_000_000_000));
            } else {
                self.origin_seg = w_now_seg;
                self.k_ms = 0;
            }
        }
        // target = origin + C·(t-K)^3  [segments], C=0.4 → ·4/1e10 with t,K in ms
        const d: i64 = (now - self.epoch_ms) - self.k_ms;
        const cube: i128 = @as(i128, d) * d * d;
        const delta_seg: i128 = @divTrunc(cube * 4, 10_000_000_000);
        const target_seg: i128 = @as(i128, @intCast(self.origin_seg)) + delta_seg;
        const target: usize = if (target_seg < 1) mss else @as(usize, @intCast(target_seg)) * mss;

        if (self.cwnd < target) {
            self.cwnd += @max(1, (target - self.cwnd) * acked_bytes / self.cwnd);
        } else {
            self.cwnd += @max(1, mss * acked_bytes / (self.cwnd * 100)); // gentle probe above origin
        }
        if (self.cwnd > max_cwnd) self.cwnd = max_cwnd;
    }

    pub fn onLoss(self: *Cubic, now: i64, srtt_ms: i64) void {
        if (self.has_loss and now - self.last_loss_ms < @max(srtt_ms, 1)) return;
        self.has_loss = true;
        self.last_loss_ms = now;
        self.w_max_seg = self.cwnd / mss;
        self.cwnd = @max(self.cwnd * 7 / 10, 2 * mss); // beta = 0.7
        self.ssthresh = self.cwnd;
        self.has_epoch = false; // recompute the epoch on the next ack
        self.congestion_events += 1;
    }

    /// Persistent congestion (RFC 9002 §7.6): collapse to the minimum window.
    pub fn onPersistentCongestion(self: *Cubic) void {
        self.w_max_seg = self.cwnd / mss;
        self.ssthresh = @max(self.cwnd / 2, 2 * mss);
        self.cwnd = 2 * mss;
        self.has_epoch = false;
    }
};

const testing = std.testing;

test "icbrt" {
    try testing.expectEqual(@as(u64, 0), icbrt(0));
    try testing.expectEqual(@as(u64, 2), icbrt(8));
    try testing.expectEqual(@as(u64, 2), icbrt(26)); // floor
    try testing.expectEqual(@as(u64, 10), icbrt(1000));
    try testing.expectEqual(@as(u64, 1000), icbrt(1_000_000_000));
}

test "slow start then loss reduces by beta (0.7)" {
    var cc = Cubic{};
    const start = cc.window();
    cc.onAck(Cubic.mss, 0);
    try testing.expectEqual(start + Cubic.mss, cc.window()); // slow start += acked
    cc.cwnd = 100 * Cubic.mss;
    cc.ssthresh = 50 * Cubic.mss; // now in congestion avoidance
    cc.onLoss(1000, 50);
    try testing.expectEqual(@as(usize, 70 * Cubic.mss), cc.window());
    try testing.expectEqual(@as(u32, 1), cc.congestion_events);
}

test "cubic grows back toward w_max after a loss" {
    var cc = Cubic{};
    cc.cwnd = 100 * Cubic.mss;
    cc.ssthresh = 50 * Cubic.mss;
    cc.onLoss(1000, 50); // -> 70*mss, w_max = 100*mss
    const after_loss = cc.window();
    var now: i64 = 1000;
    var i: usize = 0;
    while (i < 600) : (i += 1) { // ~3s of acks: concave approach (K ≈ 4.2s for w_max=100)
        now += 5;
        cc.onAck(Cubic.mss, now);
    }
    try testing.expect(cc.window() > after_loss); // recovered upward
    try testing.expect(cc.window() >= 80 * Cubic.mss); // concavely approaching w_max (100)
    try testing.expect(cc.window() <= 110 * Cubic.mss); // not yet overshooting into convex probe
}
