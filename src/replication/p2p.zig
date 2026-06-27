//! Peer-to-peer rollback authority (`authority = .p2p_rollback`, GGPO-style).
//! Each peer advances the shared deterministic `step` every tick using its **own**
//! input plus a **prediction** of the remote input (repeat-last). When the real
//! remote input for a past tick arrives and differs from the prediction, the peer
//! **rolls back** to that tick and replays forward with the corrected inputs. Like
//! lockstep this needs hard cross-machine determinism (`step` in fixed-point), but it
//! hides latency behind prediction instead of waiting for the slowest peer.
//!
//! Modeled for 2 peers: input slot 0 = local, slot 1 = remote.

const std = @import("std");
const History = @import("history.zig").History;

pub fn P2p(
    comptime State: type,
    comptime Input: type,
    comptime step: fn (State, [2]Input) State,
    comptime cap: usize,
) type {
    return struct {
        const Self = @This();
        // inputs in GLOBAL player order (slot 0 = player 0, slot 1 = player 1), so
        // every peer computes the same state regardless of which player it is.
        const Slot = struct { in: [2]Input = undefined, confirmed: bool = false, used: bool = false };

        me: usize = 0, // this peer's global player index (0 or 1)
        states: History(State, cap) = .{}, // state AFTER each tick
        slots: [cap]Slot = [_]Slot{.{}} ** cap,
        tick: u32 = 0,
        present: State = undefined,
        rollbacks: u32 = 0,
        last_confirmed_remote: Input = undefined,
        have_remote: bool = false,

        pub fn init(self: *Self, me: usize, initial: State) void {
            self.* = .{ .me = me };
            self.present = initial;
            self.states.record(0, initial);
        }

        fn slot(self: *Self, t: u32) *Slot {
            return &self.slots[t % cap];
        }

        /// Advance one tick with this peer's local input, predicting the remote
        /// player's input as the last confirmed one (repeat-last). Inputs are placed
        /// in global order so all peers agree.
        pub fn advance(self: *Self, local: Input) State {
            self.tick += 1;
            const other = 1 - self.me;
            const remote_pred = if (self.have_remote) self.last_confirmed_remote else std.mem.zeroes(Input);
            const s = self.slot(self.tick);
            s.used = true;
            s.confirmed = false;
            s.in[self.me] = local;
            s.in[other] = remote_pred;
            self.present = step(self.present, s.in);
            self.states.record(self.tick, self.present);
            return self.present;
        }

        /// The real remote (player `1-me`) input for `t` arrived. If it differs from
        /// the prediction, roll back to `t` and replay to "now". Returns true on rollback.
        pub fn confirmRemote(self: *Self, t: u32, remote: Input) bool {
            if (t == 0 or t > self.tick) return false;
            const other = 1 - self.me;
            const s = self.slot(t);
            const was_correct = s.confirmed and std.meta.eql(s.in[other], remote);
            s.in[other] = remote;
            s.confirmed = true;
            self.last_confirmed_remote = remote;
            self.have_remote = true;
            if (was_correct) return false; // prediction held → no rollback

            self.rollbacks += 1;
            var st = self.states.get(t - 1) orelse return true;
            var carry = remote; // last known remote, carried into unconfirmed future ticks
            var k = t;
            while (k <= self.tick) : (k += 1) {
                const sk = self.slot(k);
                if (sk.confirmed) carry = sk.in[other] else sk.in[other] = carry; // re-predict
                st = step(st, sk.in);
                self.states.record(k, st);
            }
            self.present = st;
            return true;
        }
    };
}

const testing = std.testing;
const Fixed = @import("core").fixed.Fixed;
const Fixed16 = Fixed(i64, 16);

const GS = struct { x: [2]i64 }; // two players' positions, Q16.16
const In = struct { dir: i8 }; // -1/0/+1 movement
fn p2pStep(s: GS, in: [2]In) GS {
    var out = s;
    const step_amt = Fixed16.fromRatio(1, 4); // exact 0.25/tick
    inline for (0..2) |p| {
        const d: i64 = in[p].dir;
        out.x[p] = (Fixed16{ .raw = out.x[p] }).add(step_amt.scaleInt(d)).raw;
    }
    return out;
}
const TestP2p = P2p(GS, In, p2pStep, 256);

test "p2p converges to identical state despite predicted-then-corrected remote input" {
    const latency: u32 = 4;
    var a: TestP2p = undefined; // peer A is player 0
    a.init(0, .{ .x = .{ 0, 0 } });
    var b: TestP2p = undefined; // peer B is player 1
    b.init(1, .{ .x = .{ 0, 0 } });

    // ground-truth inputs each tick (what each player actually pressed)
    var p0: [200]In = undefined;
    var p1: [200]In = undefined;
    var prng = std.Random.DefaultPrng.init(0x6262);
    const rnd = prng.random();
    for (&p0, &p1) |*x, *y| {
        x.* = .{ .dir = rnd.intRangeAtMost(i8, -1, 1) };
        y.* = .{ .dir = rnd.intRangeAtMost(i8, -1, 1) };
    }

    var t: u32 = 1;
    while (t <= 150) : (t += 1) {
        _ = a.advance(p0[t]); // A advances with its own input, predicting player 1
        _ = b.advance(p1[t]); // B advances with its own input, predicting player 0
        // remote inputs arrive `latency` ticks late and are confirmed
        if (t > latency) {
            const past = t - latency;
            _ = a.confirmRemote(past, p1[past]); // A learns player 1's real input
            _ = b.confirmRemote(past, p0[past]); // B learns player 0's real input
        }
    }
    // drain the last in-flight confirmations
    var d: u32 = 0;
    while (d < latency) : (d += 1) {
        const past = 150 - latency + 1 + d;
        if (past >= 1 and past <= 150) {
            _ = a.confirmRemote(past, p1[past]);
            _ = b.confirmRemote(past, p0[past]);
        }
    }

    // ground truth: full deterministic sim over all real inputs (global player order)
    var gt = GS{ .x = .{ 0, 0 } };
    var g: u32 = 1;
    while (g <= 150) : (g += 1) gt = p2pStep(gt, .{ p0[g], p1[g] });

    try testing.expect(a.rollbacks > 0 and b.rollbacks > 0); // predictions were corrected
    // both peers converged to the authoritative (ground-truth) state, identically
    try testing.expectEqual(gt.x[0], a.present.x[0]);
    try testing.expectEqual(gt.x[1], a.present.x[1]);
    try testing.expectEqual(a.present.x[0], b.present.x[0]);
    try testing.expectEqual(a.present.x[1], b.present.x[1]);
}
