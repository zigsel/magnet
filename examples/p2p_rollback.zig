//! p2p_rollback - GGPO-style peer-to-peer. Each peer advances every tick on its own
//! input plus a *prediction* of the remote's (repeat-the-last). When the real remote
//! input arrives a few ticks late and differs, the peer rolls back to that tick and
//! replays. Both peers converge on the exact same state.

const std = @import("std");
const magnet = @import("magnet");

const Fixed = magnet.core.Fixed(i64, 16);
const Game = struct { x: [2]i64 }; // two players' positions, Q16.16
const Input = struct { dir: i8 }; // -1 / 0 / +1

fn step(s: Game, in: [2]Input) Game {
    var out = s;
    const quarter = Fixed.fromRatio(1, 4);
    inline for (0..2) |p| {
        out.x[p] = (Fixed{ .raw = out.x[p] }).add(quarter.scaleInt(in[p].dir)).raw;
    }
    return out;
}
const P2p = magnet.replication.P2p(Game, Input, step, 256);

pub fn main() void {
    var a: P2p = undefined;
    a.init(0, .{ .x = .{ 0, 0 } }); // peer A is player 0
    var b: P2p = undefined;
    b.init(1, .{ .x = .{ 0, 0 } }); // peer B is player 1

    var p0: [160]Input = undefined; // what each player actually pressed
    var p1: [160]Input = undefined;
    var rng = std.Random.DefaultPrng.init(0x6262);
    for (&p0, &p1) |*x, *y| {
        x.* = .{ .dir = rng.random().intRangeAtMost(i8, -1, 1) };
        y.* = .{ .dir = rng.random().intRangeAtMost(i8, -1, 1) };
    }

    const latency: u32 = 4;
    var t: u32 = 1;
    while (t <= 150) : (t += 1) {
        _ = a.advance(p0[t]); // A advances on its own input, predicting player 1
        _ = b.advance(p1[t]); // B likewise, predicting player 0
        if (t > latency) {
            _ = a.confirmRemote(t - latency, p1[t - latency]); // the truth arrives late
            _ = b.confirmRemote(t - latency, p0[t - latency]);
        }
    }
    for (0..latency) |i| { // drain the last in-flight confirmations
        const past = 150 - latency + 1 + @as(u32, @intCast(i));
        _ = a.confirmRemote(past, p1[past]);
        _ = b.confirmRemote(past, p0[past]);
    }

    std.debug.print("p2p_rollback: A rolled back {d}×, B {d}×; peers converged = {}\n", .{
        a.rollbacks, b.rollbacks, a.present.x[0] == b.present.x[0] and a.present.x[1] == b.present.x[1],
    });
}
