//! Path-MTU discovery via DF-padded probes (RakNet-style: send don't-fragment
//! probes at candidate sizes, raise the MTU when one is acked, stop on loss or a
//! black hole). No ICMP dependence - NAT/firewall robust.

const std = @import("std");

pub const Mtu = struct {
    pub const base: u16 = 1200;
    // Candidate sizes to probe upward from `base` (index 0 == base, already known good).
    const candidates = [_]u16{ 1200, 1400, 1500 };

    current: u16 = base,
    next_idx: usize = 1, // next candidate to probe
    probing: bool = false,
    probe_size: u16 = 0,
    done: bool = false,

    pub fn init() Mtu {
        return .{};
    }

    pub fn mtu(self: *const Mtu) u16 {
        return self.current;
    }

    /// The next probe size to send as a DF-padded packet, or null if none pending.
    pub fn nextProbe(self: *Mtu) ?u16 {
        if (self.done or self.probing or self.next_idx >= candidates.len) return null;
        self.probing = true;
        self.probe_size = candidates[self.next_idx];
        return self.probe_size;
    }

    /// A probe of `probe_size` was acknowledged → that size works; raise the MTU.
    pub fn onProbeAck(self: *Mtu) void {
        if (!self.probing) return;
        self.current = self.probe_size;
        self.probing = false;
        self.next_idx += 1;
        if (self.next_idx >= candidates.len) self.done = true;
    }

    /// A probe was lost (too big for the path) → stop probing larger.
    pub fn onProbeLoss(self: *Mtu) void {
        self.probing = false;
        self.done = true;
    }

    /// Black-hole detected (large packets suddenly failing on an established path)
    /// → fall back to the safe base and stop.
    pub fn onBlackHole(self: *Mtu) void {
        self.current = base;
        self.done = true;
        self.probing = false;
    }
};

const testing = std.testing;

test "probes upward on acks until exhausted" {
    var m = Mtu.init();
    try testing.expectEqual(@as(u16, 1200), m.mtu());
    try testing.expectEqual(@as(u16, 1400), m.nextProbe().?);
    try testing.expect(m.nextProbe() == null); // already probing; one at a time
    m.onProbeAck();
    try testing.expectEqual(@as(u16, 1400), m.mtu());
    try testing.expectEqual(@as(u16, 1500), m.nextProbe().?);
    m.onProbeAck();
    try testing.expectEqual(@as(u16, 1500), m.mtu());
    try testing.expect(m.nextProbe() == null); // done
    try testing.expect(m.done);
}

test "probe loss stops at the last good size" {
    var m = Mtu.init();
    _ = m.nextProbe(); // probe 1400
    m.onProbeLoss();
    try testing.expectEqual(@as(u16, 1200), m.mtu()); // stayed at base
    try testing.expect(m.nextProbe() == null);
}

test "black hole falls back to base" {
    var m = Mtu.init();
    _ = m.nextProbe();
    m.onProbeAck(); // raised to 1400
    try testing.expectEqual(@as(u16, 1400), m.mtu());
    m.onBlackHole();
    try testing.expectEqual(@as(u16, 1200), m.mtu());
}
