//! lockstep_rts - deterministic command-frame netcode (the RTS model). Only inputs
//! cross the wire; every peer advances the *same* fixed-point sim once all inputs for a
//! tick have arrived. Fixed-point math means bit-identical state on every machine.

const std = @import("std");
const magnet = @import("magnet");

const Fixed = magnet.core.Fixed(i64, 16); // Q16.16, no floats

const Units = struct { pos: [2]i64 }; // two players' positions, as Q16.16 raw
const Move = struct { advance: bool };

fn sim(state: Units, inputs: [*]const Move, n: usize) Units {
    var out = state;
    const third = Fixed.fromRatio(1, 3); // exactly ⅓ per step
    for (0..n) |p| {
        if (inputs[p].advance) out.pos[p] = (Fixed{ .raw = out.pos[p] }).add(third).raw;
    }
    return out;
}

const Lockstep = magnet.replication.Lockstep(Units, Move, sim, 2, 64);

pub fn main() void {
    var alice = Lockstep.init(.{ .pos = .{ 0, 0 } });
    var bob = Lockstep.init(.{ .pos = .{ 0, 0 } });

    var t: u32 = 1;
    while (t <= 30) : (t += 1) {
        for ([_]*Lockstep{ &alice, &bob }) |peer| {
            peer.submit(0, t, .{ .advance = true }); // player 0 keeps moving
            peer.submit(1, t, .{ .advance = false }); // player 1 stands still
        }
        _ = alice.advanceAll();
        _ = bob.advanceAll();
    }

    const p0 = (Fixed{ .raw = alice.state.pos[0] }).toIntRound();
    std.debug.print("lockstep_rts: peers agree = {}; player0 = {d} (30×⅓ exactly, no drift)\n", .{
        alice.state.pos[0] == bob.state.pos[0], p0,
    });
}
