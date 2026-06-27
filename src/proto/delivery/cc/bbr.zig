//! BBR v1 congestion control (integer / fixed-point). Models the path as
//! BtlBw (bottleneck bandwidth, windowed-max of delivery-rate samples) × RTprop
//! (round-trip propagation, windowed-min RTT). cwnd = cwnd_gain · BDP, paced at
//! pacing_gain · BtlBw, through the STARTUP → DRAIN → PROBE_BW → PROBE_RTT machine.
//!
//! Loss-agnostic for cwnd (BBR's defining property - no standing-queue sawtooth).
//! Gains are num/den ratios so the whole thing is float-free. Standalone + tested;
//! comptime-pluggable selection into the connection lands with `Config`.

const std = @import("std");
const WindowedMax = @import("../bandwidth.zig").WindowedMax;

pub const Bbr = struct {
    pub const mss: usize = 1200;
    const min_cwnd: usize = 4 * mss;
    // startup gain = 2/ln2 ≈ 2.885
    const high_num: usize = 2885;
    const high_den: usize = 1000;

    pub const State = enum { startup, drain, probe_bw, probe_rtt };

    // PROBE_BW pacing-gain cycle (num/den): probe up, drain, then cruise ×6.
    const cycle_num = [8]u64{ 5, 3, 1, 1, 1, 1, 1, 1 };
    const cycle_den = [8]u64{ 4, 4, 1, 1, 1, 1, 1, 1 };

    state: State = .startup,
    bw_filter: WindowedMax(10) = .{},
    btlbw_bps: u64 = 0,
    rtprop_ms: i64 = std.math.maxInt(i64),
    rtprop_stamp: i64 = 0,
    cwnd: usize = min_cwnd,
    pacing_bps: u64 = 0,

    full_bw: u64 = 0,
    full_bw_count: u32 = 0,
    round_stamp: i64 = 0,

    cycle_idx: usize = 0,
    cycle_stamp: i64 = 0,

    probe_rtt_done_ms: i64 = 0,
    last_ack_ms: i64 = 0,
    started: bool = false,

    // send-rate tracking for the `min(send_rate, ack_rate)` delivery-rate sample
    // (avoids overestimating BtlBw when app-limited and acks bunch up).
    sent_acc: u64 = 0,
    sent_stamp: i64 = 0,
    send_rate_bps: u64 = 0,

    pub fn window(self: *const Bbr) usize {
        return self.cwnd;
    }

    /// Feed bytes handed to the network so BBR can bound its bandwidth estimate by the
    /// actual send rate (the session calls this when it emits a datagram).
    pub fn onSent(self: *Bbr, bytes: usize, now: i64) void {
        if (self.sent_stamp == 0) self.sent_stamp = now;
        self.sent_acc += bytes;
        const dt = now - self.sent_stamp;
        if (dt >= 100) { // recompute the windowed send rate ~10×/sec
            self.send_rate_bps = @intCast(@divTrunc(@as(i64, @intCast(self.sent_acc)) * 1000, dt));
            self.sent_acc = 0;
            self.sent_stamp = now;
        }
    }
    pub fn pacingRate(self: *const Bbr) u64 {
        return self.pacing_bps;
    }

    /// Loss does not drive cwnd in BBR v1 (that's the whole point).
    pub fn onLoss(self: *Bbr, now: i64, srtt_ms: i64) void {
        _ = self;
        _ = now;
        _ = srtt_ms;
    }

    /// `acked_bytes` newly acknowledged, the packet's `rtt_ms`, current
    /// `in_flight` bytes, and `now` (ms).
    pub fn onAck(self: *Bbr, acked_bytes: usize, rtt_ms: i64, in_flight: usize, now: i64) void {
        if (!self.started) {
            self.started = true;
            self.last_ack_ms = now;
            self.round_stamp = now;
            self.cycle_stamp = now;
            self.rtprop_ms = rtt_ms;
            self.rtprop_stamp = now;
        }

        // delivery-rate sample = min(send_rate, ack_rate) → windowed-max BtlBw.
        const interval = now - self.last_ack_ms;
        self.last_ack_ms = now;
        if (interval > 0) {
            var sample: u64 = @intCast(@divTrunc(@as(i64, @intCast(acked_bytes)) * 1000, interval)); // ack rate
            if (self.send_rate_bps > 0) sample = @min(sample, self.send_rate_bps); // cap by the send rate
            self.bw_filter.push(sample);
        }
        self.btlbw_bps = self.bw_filter.estimate();

        // windowed-min RTprop (10s window)
        if (rtt_ms < self.rtprop_ms or now - self.rtprop_stamp > 10_000) {
            self.rtprop_ms = rtt_ms;
            self.rtprop_stamp = now;
        }

        const bdp = self.bdpBytes();
        var pg_num: u64 = high_num;
        var pg_den: u64 = high_den;
        var cg_num: u64 = high_num;
        var cg_den: u64 = high_den;

        const new_round = (now - self.round_stamp) >= @max(self.rtprop_ms, 1);
        if (new_round) self.round_stamp = now;

        switch (self.state) {
            .startup => {
                if (new_round) {
                    if (self.btlbw_bps >= self.full_bw + self.full_bw / 4) {
                        self.full_bw = self.btlbw_bps;
                        self.full_bw_count = 0;
                    } else {
                        self.full_bw_count += 1;
                        if (self.full_bw_count >= 3) self.state = .drain; // pipe full
                    }
                }
            },
            .drain => {
                pg_num = high_den; // 1/2.885 - drain the startup queue
                pg_den = high_num;
                if (in_flight <= bdp) {
                    self.state = .probe_bw;
                    self.cycle_idx = 0;
                    self.cycle_stamp = now;
                }
            },
            .probe_bw => {
                pg_num = cycle_num[self.cycle_idx];
                pg_den = cycle_den[self.cycle_idx];
                cg_num = 2;
                cg_den = 1;
                if (now - self.cycle_stamp >= @max(self.rtprop_ms, 1)) {
                    self.cycle_idx = (self.cycle_idx + 1) % 8;
                    self.cycle_stamp = now;
                }
                // periodic PROBE_RTT to refresh the min-RTT estimate
                if (now - self.rtprop_stamp > 10_000) {
                    self.state = .probe_rtt;
                    self.probe_rtt_done_ms = now + 200;
                }
            },
            .probe_rtt => {
                cg_num = 1; // cwnd pinned to a few packets
                cg_den = 1;
                if (now >= self.probe_rtt_done_ms) {
                    self.rtprop_stamp = now;
                    self.state = if (self.full_bw > 0) .probe_bw else .startup;
                    self.cycle_stamp = now;
                }
            },
        }

        // cwnd = cwnd_gain · BDP ; pacing = pacing_gain · BtlBw
        if (self.state == .probe_rtt) {
            self.cwnd = min_cwnd;
        } else {
            self.cwnd = @max(bdp * cg_num / cg_den, min_cwnd);
        }
        self.pacing_bps = self.btlbw_bps * pg_num / pg_den;
    }

    fn bdpBytes(self: *const Bbr) usize {
        if (self.btlbw_bps == 0 or self.rtprop_ms <= 0 or self.rtprop_ms == std.math.maxInt(i64)) return min_cwnd;
        return @intCast(@divTrunc(self.btlbw_bps * @as(u64, @intCast(self.rtprop_ms)), 1000));
    }
};

const testing = std.testing;

// Feed `n` acks for a link delivering `bw` bytes/sec with `rtt` ms RTT.
fn drive(bbr: *Bbr, bw: u64, rtt: i64, now: *i64, n: usize) void {
    const interval: i64 = 10; // ms per ack
    const acked: usize = @intCast(@divTrunc(bw * @as(u64, @intCast(interval)), 1000));
    const bdp: usize = @intCast(@divTrunc(bw * @as(u64, @intCast(rtt)), 1000));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        now.* += interval;
        bbr.onAck(acked, rtt, bdp, now.*); // in_flight = BDP so DRAIN can exit
    }
}

test "bbr reaches PROBE_BW and sizes cwnd to ~cwnd_gain·BDP" {
    var bbr = Bbr{};
    var now: i64 = 0;
    const bw: u64 = 1_000_000; // 1 MB/s
    const rtt: i64 = 50;
    drive(&bbr, bw, rtt, &now, 300);

    const bdp: usize = @intCast(bw * @as(u64, @intCast(rtt)) / 1000); // 50_000
    try testing.expectEqual(Bbr.State.probe_bw, bbr.state);
    // BtlBw learned (within 20%)
    try testing.expect(bbr.btlbw_bps >= bw * 8 / 10 and bbr.btlbw_bps <= bw * 12 / 10);
    // cwnd ≈ 2·BDP in PROBE_BW
    try testing.expect(bbr.window() >= bdp * 3 / 2 and bbr.window() <= bdp * 5 / 2);
    // pacing roughly tracks BtlBw (within the cycle gains)
    try testing.expect(bbr.pacingRate() >= bw / 2);
}

test "bbr leaves STARTUP after the bandwidth plateaus" {
    var bbr = Bbr{};
    var now: i64 = 0;
    try testing.expectEqual(Bbr.State.startup, bbr.state);
    drive(&bbr, 1_000_000, 50, &now, 40); // constant bw → pipe fills → leaves startup
    try testing.expect(bbr.state != .startup);
}

test "bbr ignores loss for cwnd (no sawtooth)" {
    var bbr = Bbr{};
    var now: i64 = 0;
    drive(&bbr, 1_000_000, 50, &now, 300);
    const before = bbr.window();
    bbr.onLoss(now, 50);
    try testing.expectEqual(before, bbr.window());
}

test "bbr bounds the delivery-rate sample by the send rate (min(send,ack))" {
    var bbr = Bbr{};
    // establish a send rate of ~500 KB/s (50000 bytes over 100ms). Off t=0 so the
    // `sent_stamp == 0` "unset" sentinel doesn't collide with a real timestamp.
    bbr.onSent(50_000, 1000);
    bbr.onSent(0, 1100); // dt=100ms → send_rate = 500_000 B/s
    try testing.expectEqual(@as(u64, 500_000), bbr.send_rate_bps);
    // first ack establishes the ack-interval clock (no sample yet)
    bbr.onAck(0, 50, 0, 1100);
    // a HIGH ack-rate (50000 B over 10ms = 5 MB/s, e.g. bunched acks)…
    bbr.onAck(50_000, 50, 50_000, 1110);
    // …is capped by the send rate, so BtlBw doesn't balloon to 5 MB/s
    try testing.expect(bbr.btlbw_bps <= 600_000);
    try testing.expect(bbr.btlbw_bps >= 400_000);
}
