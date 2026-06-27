//! RACK-style loss detection (QUIC RFC 9002 §6.1): a sent packet below the
//! largest acked is lost if it is ≥ `packet_threshold` behind, OR it was sent
//! longer than `(num/den) · max(smoothed, latest) RTT` ago. Generic over the
//! packet-number width; thresholds come from `Config.delivery`.

const seq = @import("core").seq;
const Rtt = @import("rtt.zig").Rtt;

pub const default_packet_threshold: u16 = 3;

pub fn isLost(
    comptime Seq: type,
    pn: Seq,
    largest_acked: Seq,
    sent_time: i64,
    now: i64,
    rtt: *const Rtt,
    packet_threshold: u16,
    time_num: i64,
    time_den: i64,
) bool {
    // packet threshold: largest_acked ≥ pn + packet_threshold
    if (seq.greaterThan(Seq, largest_acked, pn +% (packet_threshold - 1))) return true;
    // time threshold
    const base = @max(rtt.smoothed_ms, rtt.latest_ms);
    const thresh = @max(@divTrunc(time_num * base, time_den), 1);
    return (now - sent_time) >= thresh;
}

const std = @import("std");
const testing = std.testing;

test "packet threshold marks old packets lost" {
    var rtt = Rtt{};
    rtt.sample(50);
    // pn 10, largest 13 (3 ahead) -> lost by packet threshold even if just sent
    try testing.expect(isLost(u16, 10, 13, 1000, 1000, &rtt, 3, 9, 8));
    // pn 10, largest 11 (1 ahead), just sent -> not lost
    try testing.expect(!isLost(u16, 10, 11, 1000, 1000, &rtt, 3, 9, 8));
}

test "time threshold marks stale packets lost" {
    var rtt = Rtt{};
    rtt.sample(50); // 9/8*50 ≈ 56ms threshold
    try testing.expect(isLost(u16, 10, 11, 0, 100, &rtt, 3, 9, 8)); // sent 100ms ago
    try testing.expect(!isLost(u16, 10, 11, 0, 30, &rtt, 3, 9, 8)); // sent 30ms ago
}

test "u32 packet numbers and a tighter packet threshold" {
    var rtt = Rtt{};
    rtt.sample(50);
    try testing.expect(isLost(u32, 1_000_000, 1_000_001, 1000, 1000, &rtt, 1, 9, 8)); // threshold 1
    try testing.expect(!isLost(u32, 1_000_000, 1_000_000, 1000, 1000, &rtt, 2, 9, 8));
}
