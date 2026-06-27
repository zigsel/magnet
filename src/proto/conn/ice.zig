//! ICE-lite NAT traversal (sans-IO, signaling-agnostic). The one capability the
//! transport otherwise lacks: establishing a peer-to-peer path through NATs without a
//! relay. Each agent gathers **candidates** (host = its local socket; srflx = its
//! public mapping as seen by a STUN server - the app supplies these, since STUN and
//! the signaling channel are app/transport-specific), exchanges them over the app's
//! signaling channel, forms prioritized candidate **pairs**, and runs **connectivity
//! checks** (a binding request/response keyed by a random transaction id) over the
//! connectionless datagram path (`Endpoint.sendUnconnected`). The controlling agent
//! **nominates** the highest-priority pair that answers; both ends then send data to
//! the nominated remote address. No relay, no libwebrtc - just the punch coordinator.
//!
//! Wire (a check datagram, carried connectionless): `[magic:u32]['q'|'p'][tx_id:u64]`
//! ('q' = binding request, 'p' = binding response echoing the request's tx_id).

const std = @import("std");

pub const magic: u32 = 0x6D_67_49_43; // "mgIC"
pub const Kind = enum(u8) { host = 0, srflx = 1, relay = 2 };

pub const Candidate = struct {
    addr: u64,
    kind: Kind = .host,

    /// RFC 8445 §5.1.2 priority: `2^24·type_pref + 2^8·local_pref + (256 − component)`.
    pub fn priority(self: Candidate, local_pref: u16) u32 {
        const type_pref: u32 = switch (self.kind) {
            .host => 126,
            .srflx => 100,
            .relay => 0,
        };
        return (type_pref << 24) | (@as(u32, local_pref) << 8) | 255;
    }
};

pub const check_request: u8 = 'q';
pub const check_response: u8 = 'p';
pub const wire_len = 4 + 1 + 8;

pub fn encodeCheck(buf: []u8, kind: u8, tx_id: u64) usize {
    std.mem.writeInt(u32, buf[0..4], magic, .little);
    buf[4] = kind;
    std.mem.writeInt(u64, buf[5..13], tx_id, .little);
    return wire_len;
}
pub const Check = struct { kind: u8, tx_id: u64 };
pub fn decodeCheck(bytes: []const u8) ?Check {
    if (bytes.len < wire_len) return null;
    if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return null;
    const k = bytes[4];
    if (k != check_request and k != check_response) return null;
    return .{ .kind = k, .tx_id = std.mem.readInt(u64, bytes[5..13], .little) };
}

/// A sans-IO connectivity-check agent over a fixed candidate budget.
pub fn Agent(comptime max_remote: usize) type {
    return struct {
        const Self = @This();
        const State = enum { waiting, in_progress, succeeded, failed };
        const Pair = struct {
            remote: Candidate,
            state: State = .waiting,
            tx_id: u64 = 0,
            sent_at: i64 = 0,
            prio: u32 = 0,
        };

        /// True for the side that nominates (typically the connection initiator).
        controlling: bool = false,
        /// Caller-seeded per-agent transaction-id stream (vary it per agent).
        tx_seed: u64 = 0x1234_5678,
        check_interval_ms: i64 = 50,

        pairs: [max_remote]Pair = undefined,
        npairs: usize = 0,
        nominated: ?u64 = null,

        /// Add a remote candidate (learned over signaling); pairs it with our path.
        /// `local_pref` ranks our local candidates (higher = preferred).
        pub fn addRemote(self: *Self, c: Candidate, local_pref: u16) void {
            if (self.npairs >= max_remote) return;
            self.pairs[self.npairs] = .{ .remote = c, .prio = c.priority(local_pref) };
            self.npairs += 1;
        }

        fn nextTx(self: *Self) u64 {
            self.tx_seed +%= 0x9E37_79B9_7F4A_7C15;
            return self.tx_seed;
        }

        pub const Probe = struct { to: u64, bytes_len: usize };

        /// Emit the next connectivity-check **request** (highest-priority pair that is
        /// waiting or due for a retry) into `buf`; null when nothing is due. The app
        /// sends `buf[0..len]` to `to` over the connectionless path.
        pub fn pollProbe(self: *Self, buf: []u8, now: i64) ?struct { to: u64, len: usize } {
            if (self.nominated != null) return null;
            var best: ?usize = null;
            var best_prio: u32 = 0;
            for (self.pairs[0..self.npairs], 0..) |p, i| {
                const due = p.state == .waiting or
                    (p.state == .in_progress and (now - p.sent_at) >= self.check_interval_ms);
                if (p.state == .succeeded or p.state == .failed or !due) continue;
                if (best == null or p.prio > best_prio) {
                    best = i;
                    best_prio = p.prio;
                }
            }
            const idx = best orelse return null;
            const p = &self.pairs[idx];
            p.tx_id = self.nextTx();
            p.state = .in_progress;
            p.sent_at = now;
            const len = encodeCheck(buf, check_request, p.tx_id);
            return .{ .to = p.remote.addr, .len = len };
        }

        /// A check datagram arrived from `from`. Returns response bytes to send back when
        /// it was a **request** (always answer a request - ICE connectivity is symmetric);
        /// processes a **response** by marking the matching pair succeeded. `out` ≥ wire_len.
        pub fn onCheck(self: *Self, from: u64, bytes: []const u8, out: []u8) ?usize {
            const c = decodeCheck(bytes) orelse return null;
            if (c.kind == check_request) {
                return encodeCheck(out, check_response, c.tx_id); // echo the tx_id
            }
            // a response: find the pair whose request we sent
            for (self.pairs[0..self.npairs]) |*p| {
                if (p.state == .in_progress and p.tx_id == c.tx_id and p.remote.addr == from) {
                    p.state = .succeeded;
                    // controlling agent nominates the best succeeded pair immediately
                    if (self.controlling) self.nominate();
                    return null;
                }
            }
            return null;
        }

        fn nominate(self: *Self) void {
            var best: ?u64 = null;
            var best_prio: u32 = 0;
            for (self.pairs[0..self.npairs]) |p| {
                if (p.state == .succeeded and (best == null or p.prio > best_prio)) {
                    best = p.remote.addr;
                    best_prio = p.prio;
                }
            }
            self.nominated = best;
        }

        /// The selected remote address once a pair has been nominated, else null.
        /// The controlled side nominates the best succeeded pair on demand.
        pub fn selected(self: *Self) ?u64 {
            if (self.nominated == null and !self.controlling) self.nominate();
            return self.nominated;
        }

        /// Earliest time a check is due again (for the driver's timer), or null if idle
        /// / already nominated.
        pub fn pollDeadline(self: *const Self, now: i64) ?i64 {
            if (self.nominated != null) return null;
            var earliest: ?i64 = null;
            for (self.pairs[0..self.npairs]) |p| {
                const at: i64 = switch (p.state) {
                    .waiting => now,
                    .in_progress => p.sent_at + self.check_interval_ms,
                    else => continue,
                };
                earliest = if (earliest) |e| @min(e, at) else at;
            }
            return earliest;
        }
    };
}

const testing = std.testing;

test "check datagram encode/decode roundtrip; rejects foreign magic" {
    var buf: [wire_len]u8 = undefined;
    _ = encodeCheck(&buf, check_request, 0xDEAD_BEEF);
    const c = decodeCheck(&buf).?;
    try testing.expectEqual(check_request, c.kind);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), c.tx_id);
    try testing.expect(decodeCheck(&[_]u8{ 0, 0, 0, 0, 'q', 0, 0, 0, 0, 0, 0, 0, 0 }) == null);
}

test "srflx outranks host in candidate-pair priority" {
    const host = Candidate{ .addr = 1, .kind = .host };
    const srflx = Candidate{ .addr = 2, .kind = .srflx };
    try testing.expect(host.priority(10) > srflx.priority(10)); // host type-pref 126 > 100
}

// Two agents punch through a modeled NAT: their host candidates can't reach each other
// (private addresses), but their srflx (public-mapping) candidates can. The check
// exchange must discover and nominate the working srflx↔srflx pair on both ends.
test "two agents converge on the working srflx pair through a NAT" {
    const A = Agent(8);
    var a = A{ .controlling = true, .tx_seed = 0xA };
    var b = A{ .controlling = false, .tx_seed = 0xB };

    // public (srflx) mappings that actually route; private (host) ones that don't.
    const a_pub: u64 = 0xAAAA;
    const b_pub: u64 = 0xBBBB;
    const a_host: u64 = 0x000A; // unreachable across the NAT
    const b_host: u64 = 0x000B;

    a.addRemote(.{ .addr = b_host, .kind = .host }, 100);
    a.addRemote(.{ .addr = b_pub, .kind = .srflx }, 100);
    b.addRemote(.{ .addr = a_host, .kind = .host }, 100);
    b.addRemote(.{ .addr = a_pub, .kind = .srflx }, 100);

    // model: a datagram from X to Y arrives only if both are public mappings.
    const routes = struct {
        fn deliver(to: u64) bool {
            return to == a_pub or to == b_pub;
        }
        // the source address the peer sees (its public mapping) for a given agent.
        fn srcOf(is_a: bool) u64 {
            return if (is_a) a_pub else b_pub;
        }
    };

    var pbuf: [64]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 200 and (a.selected() == null or b.selected() == null)) : (step += 1) {
        // A → B
        if (a.pollProbe(&pbuf, now)) |pr| {
            if (routes.deliver(pr.to)) {
                if (b.onCheck(routes.srcOf(true), pbuf[0..pr.len], &rbuf)) |rlen| {
                    // B's response goes back to A's public mapping
                    if (routes.deliver(routes.srcOf(true))) _ = a.onCheck(b_pub, rbuf[0..rlen], &pbuf);
                }
            }
        }
        // B → A
        if (b.pollProbe(&pbuf, now)) |pr| {
            if (routes.deliver(pr.to)) {
                if (a.onCheck(routes.srcOf(false), pbuf[0..pr.len], &rbuf)) |rlen| {
                    if (routes.deliver(routes.srcOf(false))) _ = b.onCheck(a_pub, rbuf[0..rlen], &pbuf);
                }
            }
        }
        now += 25;
    }

    try testing.expectEqual(@as(?u64, b_pub), a.selected()); // A nominated B's public mapping
    try testing.expectEqual(@as(?u64, a_pub), b.selected()); // and vice versa
}
