//! Comptime observability. A `Tracer` is a type whose methods the transport calls
//! at every interesting event; the `Null` tracer's empty bodies optimize away
//! (zero cost when you don't want telemetry). Swap in `Counters` (or your own) via
//! `Config.tracer`. The `peer` argument is the connection's address/id for
//! per-connection attribution.

const std = @import("std");

pub const DropReason = enum {
    send_queue_full,
    inbox_full,
    reassembly_full,
    malformed,
    replay,
    too_old,
};

/// Comptime contract check for a `Config.tracer` type: the transport calls these hooks,
/// so a custom tracer must declare all of them (the `Null`/`Counters`/`Log` tracers are
/// ready-made examples to copy). Produces a clear error naming the missing method instead
/// of a confusing failure deep inside the send path. Zero runtime cost.
pub fn assertTracer(comptime T: type) void {
    inline for (.{ "onPacketSent", "onPacketRecv", "onAck", "onLoss", "onCongestion", "onRttUpdate", "onDrop", "onRetransmit", "onCwnd", "onHandshake" }) |m| {
        if (!@hasDecl(T, m)) @compileError("Config.tracer type '" ++ @typeName(T) ++ "' is missing the `" ++ m ++ "` hook (see trace.Null for the full shape)");
    }
}

/// The default: every hook compiles to nothing.
pub const Null = struct {
    pub fn onPacketSent(self: *Null, peer: u64, bytes: usize) void {
        _ = self;
        _ = peer;
        _ = bytes;
    }
    pub fn onPacketRecv(self: *Null, peer: u64, bytes: usize) void {
        _ = self;
        _ = peer;
        _ = bytes;
    }
    pub fn onAck(self: *Null, peer: u64, acked_bytes: usize) void {
        _ = self;
        _ = peer;
        _ = acked_bytes;
    }
    pub fn onLoss(self: *Null, peer: u64, pn: u16) void {
        _ = self;
        _ = peer;
        _ = pn;
    }
    pub fn onCongestion(self: *Null, peer: u64) void {
        _ = self;
        _ = peer;
    }
    pub fn onRttUpdate(self: *Null, peer: u64, rtt_ms: i64) void {
        _ = self;
        _ = peer;
        _ = rtt_ms;
    }
    pub fn onDrop(self: *Null, peer: u64, reason: DropReason) void {
        _ = self;
        _ = peer;
        _ = reason;
    }
    pub fn onRetransmit(self: *Null, peer: u64, pn: u64) void {
        _ = self;
        _ = peer;
        _ = pn;
    }
    pub fn onCwnd(self: *Null, peer: u64, cwnd: usize, in_flight: usize) void {
        _ = self;
        _ = peer;
        _ = cwnd;
        _ = in_flight;
    }
    pub fn onHandshake(self: *Null, peer: u64, state: u8) void {
        _ = self;
        _ = peer;
        _ = state;
    }
    pub fn onChannelDepth(self: *Null, peer: u64, ch: u8, depth: u32) void {
        _ = self;
        _ = peer;
        _ = ch;
        _ = depth;
    }
    pub fn onReassembly(self: *Null, peer: u64, active: u32) void {
        _ = self;
        _ = peer;
        _ = active;
    }
    pub fn onRollback(self: *Null, ticks: u32, entities: u32) void {
        _ = self;
        _ = ticks;
        _ = entities;
    }
};

/// A simple counting tracer for tests / live stats.
pub const Counters = struct {
    packets_sent: u64 = 0,
    packets_recv: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_recv: u64 = 0,
    acked_bytes: u64 = 0,
    losses: u64 = 0,
    congestion_events: u64 = 0,
    drops: u64 = 0,
    retransmits: u64 = 0,
    rollbacks: u64 = 0,
    rollback_ticks: u64 = 0,
    last_rtt_ms: i64 = 0,
    last_cwnd: usize = 0,
    last_in_flight: usize = 0,
    last_hs_state: u8 = 0,
    last_channel_depth: u32 = 0,
    last_reassembly_active: u32 = 0,

    pub fn onPacketSent(self: *Counters, peer: u64, bytes: usize) void {
        _ = peer;
        self.packets_sent += 1;
        self.bytes_sent += bytes;
    }
    pub fn onPacketRecv(self: *Counters, peer: u64, bytes: usize) void {
        _ = peer;
        self.packets_recv += 1;
        self.bytes_recv += bytes;
    }
    pub fn onAck(self: *Counters, peer: u64, acked_bytes: usize) void {
        _ = peer;
        self.acked_bytes += acked_bytes;
    }
    pub fn onLoss(self: *Counters, peer: u64, pn: u16) void {
        _ = peer;
        _ = pn;
        self.losses += 1;
    }
    pub fn onCongestion(self: *Counters, peer: u64) void {
        _ = peer;
        self.congestion_events += 1;
    }
    pub fn onRttUpdate(self: *Counters, peer: u64, rtt_ms: i64) void {
        _ = peer;
        self.last_rtt_ms = rtt_ms;
    }
    pub fn onDrop(self: *Counters, peer: u64, reason: DropReason) void {
        _ = peer;
        _ = reason;
        self.drops += 1;
    }
    pub fn onRetransmit(self: *Counters, peer: u64, pn: u64) void {
        _ = peer;
        _ = pn;
        self.retransmits += 1;
    }
    pub fn onCwnd(self: *Counters, peer: u64, cwnd: usize, in_flight: usize) void {
        _ = peer;
        self.last_cwnd = cwnd;
        self.last_in_flight = in_flight;
    }
    pub fn onHandshake(self: *Counters, peer: u64, state: u8) void {
        _ = peer;
        self.last_hs_state = state;
    }
    pub fn onChannelDepth(self: *Counters, peer: u64, ch: u8, depth: u32) void {
        _ = peer;
        _ = ch;
        self.last_channel_depth = depth;
    }
    pub fn onReassembly(self: *Counters, peer: u64, active: u32) void {
        _ = peer;
        self.last_reassembly_active = active;
    }
    pub fn onRollback(self: *Counters, ticks: u32, entities: u32) void {
        _ = entities;
        self.rollbacks += 1;
        self.rollback_ticks += ticks;
    }
};

/// A bounded ring of the most recent events (structured, not text) - useful for a
/// live debug overlay or a post-mortem dump. Default-constructible, so it drops
/// straight into `Config.tracer`. Drop-oldest when full; never allocates.
pub const Event = struct {
    kind: enum { sent, recv, ack, loss, congestion, rtt, drop, retransmit, cwnd, handshake, channel_depth, reassembly, rollback },
    peer: u64,
    value: i64, // bytes / acked_bytes / pn / rtt_ms (per kind)
};

pub fn Log(comptime cap: usize) type {
    return struct {
        const Self = @This();
        events: [cap]Event = undefined,
        head: usize = 0,
        len: usize = 0,

        fn push(self: *Self, e: Event) void {
            const i = (self.head + self.len) % cap;
            if (self.len < cap) {
                self.events[i] = e;
                self.len += 1;
            } else {
                self.events[self.head] = e;
                self.head = (self.head + 1) % cap;
            }
        }
        /// The recorded events oldest→newest, written into `out` (capped at `cap`).
        pub fn drain(self: *const Self, out: []Event) usize {
            const n = @min(self.len, out.len);
            var k: usize = 0;
            while (k < n) : (k += 1) out[k] = self.events[(self.head + k) % cap];
            return n;
        }

        pub fn onPacketSent(self: *Self, peer: u64, bytes: usize) void {
            self.push(.{ .kind = .sent, .peer = peer, .value = @intCast(bytes) });
        }
        pub fn onPacketRecv(self: *Self, peer: u64, bytes: usize) void {
            self.push(.{ .kind = .recv, .peer = peer, .value = @intCast(bytes) });
        }
        pub fn onAck(self: *Self, peer: u64, acked_bytes: usize) void {
            self.push(.{ .kind = .ack, .peer = peer, .value = @intCast(acked_bytes) });
        }
        pub fn onLoss(self: *Self, peer: u64, pn: u16) void {
            self.push(.{ .kind = .loss, .peer = peer, .value = pn });
        }
        pub fn onCongestion(self: *Self, peer: u64) void {
            self.push(.{ .kind = .congestion, .peer = peer, .value = 0 });
        }
        pub fn onRttUpdate(self: *Self, peer: u64, rtt_ms: i64) void {
            self.push(.{ .kind = .rtt, .peer = peer, .value = rtt_ms });
        }
        pub fn onDrop(self: *Self, peer: u64, reason: DropReason) void {
            self.push(.{ .kind = .drop, .peer = peer, .value = @intFromEnum(reason) });
        }
        pub fn onRetransmit(self: *Self, peer: u64, pn: u64) void {
            self.push(.{ .kind = .retransmit, .peer = peer, .value = @intCast(pn) });
        }
        pub fn onCwnd(self: *Self, peer: u64, cwnd: usize, in_flight: usize) void {
            _ = in_flight;
            self.push(.{ .kind = .cwnd, .peer = peer, .value = @intCast(cwnd) });
        }
        pub fn onHandshake(self: *Self, peer: u64, state: u8) void {
            self.push(.{ .kind = .handshake, .peer = peer, .value = state });
        }
        pub fn onChannelDepth(self: *Self, peer: u64, ch: u8, depth: u32) void {
            _ = ch;
            self.push(.{ .kind = .channel_depth, .peer = peer, .value = depth });
        }
        pub fn onReassembly(self: *Self, peer: u64, active: u32) void {
            self.push(.{ .kind = .reassembly, .peer = peer, .value = active });
        }
        pub fn onRollback(self: *Self, ticks: u32, entities: u32) void {
            _ = entities;
            self.push(.{ .kind = .rollback, .peer = 0, .value = ticks });
        }
    };
}

/// Compose two tracers - every hook fans out to both (e.g. `Counters` + `Log`).
/// Nest for three or more: `Multi(Counters, Multi(Log(64), MyTracer))`.
pub fn Multi(comptime A: type, comptime B: type) type {
    return struct {
        const Self = @This();
        a: A = .{},
        b: B = .{},
        pub fn onPacketSent(self: *Self, peer: u64, bytes: usize) void {
            self.a.onPacketSent(peer, bytes);
            self.b.onPacketSent(peer, bytes);
        }
        pub fn onPacketRecv(self: *Self, peer: u64, bytes: usize) void {
            self.a.onPacketRecv(peer, bytes);
            self.b.onPacketRecv(peer, bytes);
        }
        pub fn onAck(self: *Self, peer: u64, acked_bytes: usize) void {
            self.a.onAck(peer, acked_bytes);
            self.b.onAck(peer, acked_bytes);
        }
        pub fn onLoss(self: *Self, peer: u64, pn: u16) void {
            self.a.onLoss(peer, pn);
            self.b.onLoss(peer, pn);
        }
        pub fn onCongestion(self: *Self, peer: u64) void {
            self.a.onCongestion(peer);
            self.b.onCongestion(peer);
        }
        pub fn onRttUpdate(self: *Self, peer: u64, rtt_ms: i64) void {
            self.a.onRttUpdate(peer, rtt_ms);
            self.b.onRttUpdate(peer, rtt_ms);
        }
        pub fn onDrop(self: *Self, peer: u64, reason: DropReason) void {
            self.a.onDrop(peer, reason);
            self.b.onDrop(peer, reason);
        }
        pub fn onRetransmit(self: *Self, peer: u64, pn: u64) void {
            self.a.onRetransmit(peer, pn);
            self.b.onRetransmit(peer, pn);
        }
        pub fn onCwnd(self: *Self, peer: u64, cwnd: usize, in_flight: usize) void {
            self.a.onCwnd(peer, cwnd, in_flight);
            self.b.onCwnd(peer, cwnd, in_flight);
        }
        pub fn onHandshake(self: *Self, peer: u64, state: u8) void {
            self.a.onHandshake(peer, state);
            self.b.onHandshake(peer, state);
        }
        pub fn onChannelDepth(self: *Self, peer: u64, ch: u8, depth: u32) void {
            self.a.onChannelDepth(peer, ch, depth);
            self.b.onChannelDepth(peer, ch, depth);
        }
        pub fn onReassembly(self: *Self, peer: u64, active: u32) void {
            self.a.onReassembly(peer, active);
            self.b.onReassembly(peer, active);
        }
        pub fn onRollback(self: *Self, ticks: u32, entities: u32) void {
            self.a.onRollback(ticks, entities);
            self.b.onRollback(ticks, entities);
        }
    };
}

test "null tracer is zero-sized and callable" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Null));
    var n = Null{};
    n.onLoss(1, 2); // compiles to nothing
}

test "counters accumulate" {
    var c = Counters{};
    c.onPacketSent(1, 100);
    c.onPacketSent(1, 50);
    c.onLoss(1, 7);
    c.onAck(1, 120);
    c.onRttUpdate(1, 88);
    try std.testing.expectEqual(@as(u64, 2), c.packets_sent);
    try std.testing.expectEqual(@as(u64, 150), c.bytes_sent);
    try std.testing.expectEqual(@as(u64, 1), c.losses);
    try std.testing.expectEqual(@as(u64, 120), c.acked_bytes);
    try std.testing.expectEqual(@as(i64, 88), c.last_rtt_ms);
}

test "log ring keeps recent events oldest→newest, drops oldest when full" {
    var lg = Log(3){};
    lg.onPacketSent(1, 10);
    lg.onAck(1, 20);
    lg.onLoss(1, 5);
    lg.onCongestion(1); // overflows: drops the first (sent)
    var buf: [3]Event = undefined;
    const n = lg.drain(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(buf[0].kind == .ack);
    try std.testing.expect(buf[1].kind == .loss);
    try std.testing.expect(buf[2].kind == .congestion);
}

test "multi fans every hook out to both tracers" {
    const T = Multi(Counters, Log(8));
    var t = T{};
    t.onPacketSent(1, 100);
    t.onLoss(1, 9);
    try std.testing.expectEqual(@as(u64, 1), t.a.packets_sent);
    try std.testing.expectEqual(@as(u64, 1), t.a.losses);
    var buf: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), t.b.drain(&buf));
}

test "null tracer composes in Multi at zero added size over the other" {
    try std.testing.expectEqual(@sizeOf(Counters), @sizeOf(Multi(Counters, Null)));
}
