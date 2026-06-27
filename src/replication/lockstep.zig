//! Lockstep authority (`authority = .lockstep`). The deterministic command-frame
//! model (RTS): **only inputs are on the wire** (reliable-ordered), no entity state.
//! Every peer collects all peers' inputs for tick T and advances the *same*
//! deterministic `step` only once they are all present - so every peer computes an
//! identical world. Determinism is a hard cross-machine requirement here, so `step`
//! must use fixed-point (`core/fixed.zig`), never `f64`. Latency shows up as input
//! delay (you wait for the slowest peer), which is why RTS uses a generous delay.

const std = @import("std");

pub fn Lockstep(
    comptime State: type,
    comptime Input: type,
    comptime step: fn (State, [*]const Input, usize) State,
    comptime n_peers: usize,
    comptime cap: usize,
) type {
    return struct {
        const Self = @This();
        const Frame = struct {
            tick: u32 = 0,
            have: [n_peers]bool = [_]bool{false} ** n_peers,
            in: [n_peers]Input = undefined,
            count: usize = 0,
        };

        frames: [cap]Frame = [_]Frame{.{}} ** cap,
        confirmed: u32 = 0, // last fully-simulated tick
        state: State,

        pub fn init(initial: State) Self {
            return .{ .state = initial };
        }

        fn frame(self: *Self, tick: u32) *Frame {
            const f = &self.frames[tick % cap];
            if (f.tick != tick or !anyHave(f)) {
                f.* = .{ .tick = tick };
            }
            return f;
        }
        fn anyHave(f: *const Frame) bool {
            return f.count > 0;
        }

        /// Submit `peer`'s input for `tick` (delivered reliably/ordered).
        pub fn submit(self: *Self, peer: usize, tick: u32, input: Input) void {
            const f = self.frame(tick);
            if (!f.have[peer]) {
                f.have[peer] = true;
                f.in[peer] = input;
                f.count += 1;
            }
        }

        /// Are all peers' inputs present for `tick`?
        pub fn ready(self: *Self, tick: u32) bool {
            const f = &self.frames[tick % cap];
            return f.tick == tick and f.count == n_peers;
        }

        /// Advance one tick if the next command-frame is complete. Returns true if it
        /// stepped (and `state` now reflects `confirmed`).
        pub fn advance(self: *Self) bool {
            const next = self.confirmed + 1;
            if (!self.ready(next)) return false;
            const f = &self.frames[next % cap];
            self.state = step(self.state, &f.in, n_peers);
            self.confirmed = next;
            return true;
        }

        /// Advance as many complete frames as are available; returns how many.
        pub fn advanceAll(self: *Self) usize {
            var k: usize = 0;
            while (self.advance()) k += 1;
            return k;
        }
    };
}

const testing = std.testing;
const Fixed = @import("core").fixed.Fixed;
const Fixed16 = Fixed(i64, 16);

// Deterministic command-frame sim: each peer's unit moves by an exact 1/3 per "move"
// input. Fixed-point makes the 1/3 accumulation bit-identical across machines.
const Units = struct { pos: [2]i64 }; // Q16.16 raw
const Cmd = struct { move: bool };
fn rtsStep(s: Units, in: [*]const Cmd, n: usize) Units {
    var out = s;
    const third = Fixed16.fromRatio(1, 3);
    var p: usize = 0;
    while (p < n) : (p += 1) {
        if (in[p].move) out.pos[p] = (Fixed16{ .raw = out.pos[p] }).add(third).raw;
    }
    return out;
}
const TestLockstep = Lockstep(Units, Cmd, rtsStep, 2, 64);

test "lockstep advances only when all peers' inputs are present" {
    var ls = TestLockstep.init(.{ .pos = .{ 0, 0 } });
    ls.submit(0, 1, .{ .move = true });
    try testing.expect(!ls.advance()); // peer 1 missing → stall
    ls.submit(1, 1, .{ .move = false });
    try testing.expect(ls.advance()); // complete frame → step
    try testing.expectEqual(@as(u32, 1), ls.confirmed);
}

test "two peers fed identical inputs reach a bit-identical state (determinism)" {
    var a = TestLockstep.init(.{ .pos = .{ 0, 0 } });
    var b = TestLockstep.init(.{ .pos = .{ 0, 0 } });
    var t: u32 = 1;
    while (t <= 30) : (t += 1) {
        // both peers exchange both inputs (reliable-ordered); peer 0 moves, peer 1 idles
        for ([_]*TestLockstep{ &a, &b }) |ls| {
            ls.submit(0, t, .{ .move = true });
            ls.submit(1, t, .{ .move = (t % 2 == 0) });
        }
        try testing.expectEqual(@as(usize, 1), a.advanceAll());
        try testing.expectEqual(@as(usize, 1), b.advanceAll());
    }
    try testing.expectEqual(a.confirmed, b.confirmed);
    try testing.expectEqual(a.state.pos[0], b.state.pos[0]); // identical fixed-point state
    try testing.expectEqual(a.state.pos[1], b.state.pos[1]);
    // peer 0 moved 30 × 1/3 = exactly 10.0 (no float drift)
    try testing.expectEqual(@as(i64, 10), (Fixed16{ .raw = a.state.pos[0] }).toIntRound());
}
