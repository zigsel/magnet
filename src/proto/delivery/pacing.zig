//! Token-bucket pacer (integer): smooths sends to a target byte-rate so a large
//! cwnd doesn't translate into a single line-rate burst. Rate is driven by
//! cwnd/RTT; the bucket caps instantaneous bursts at `burst_bytes`.

const std = @import("std");

pub const Pacer = struct {
    rate_bps: u64 = 1 << 20, // bytes/sec
    burst_bytes: i64 = 16 * 1200,
    tokens: i64 = 0,
    last_ms: i64 = 0,
    started: bool = false,

    pub fn setRate(self: *Pacer, bps: u64) void {
        self.rate_bps = @max(bps, 1200);
    }

    /// Derive the pace rate from the congestion window and smoothed RTT
    /// (rate ≈ 1.25 · cwnd / RTT).
    pub fn setFromCwnd(self: *Pacer, cwnd: usize, srtt_ms: i64) void {
        const rtt = @max(srtt_ms, 1);
        const numer = @as(i64, @intCast(cwnd)) * 1000 * 5; // 1.25 · cwnd · 1000
        self.setRate(@intCast(@divTrunc(numer, 4 * rtt)));
    }

    pub fn refill(self: *Pacer, now: i64) void {
        if (!self.started) {
            self.started = true;
            self.last_ms = now;
            self.tokens = self.burst_bytes;
            return;
        }
        const dt = now - self.last_ms;
        if (dt <= 0) return;
        self.last_ms = now;
        self.tokens += @divTrunc(@as(i64, @intCast(self.rate_bps)) * dt, 1000);
        if (self.tokens > self.burst_bytes) self.tokens = self.burst_bytes; // cap the burst
    }

    pub fn canSend(self: *const Pacer) bool {
        return self.tokens > 0;
    }

    pub fn onSent(self: *Pacer, bytes: usize) void {
        self.tokens -= @intCast(bytes);
    }
};

const testing = std.testing;

test "idle does not accumulate beyond the burst cap" {
    var p = Pacer{ .rate_bps = 1_000_000, .burst_bytes = 2000 };
    p.refill(0); // starts full at burst
    try testing.expectEqual(@as(i64, 2000), p.tokens);
    p.refill(10_000); // 10s idle would be 10MB of tokens, but capped
    try testing.expectEqual(@as(i64, 2000), p.tokens);
}

test "tokens deplete on send and refill at rate" {
    var p = Pacer{ .rate_bps = 1000, .burst_bytes = 1000 }; // 1000 B/s
    p.refill(0);
    p.onSent(1000);
    try testing.expect(!p.canSend());
    p.refill(500); // +500 B over 500ms
    try testing.expect(p.canSend());
    try testing.expectEqual(@as(i64, 500), p.tokens);
}
