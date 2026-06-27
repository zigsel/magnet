//! interpolation - remote entities are rendered a little behind the server, so there's
//! always a [previous, next] pair of confirmed snapshots to smoothly blend between -
//! even across a dropped snapshot, where the bracket simply stretches over the gap.

const std = @import("std");
const magnet = @import("magnet");

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
const Interpolator = magnet.replication.Interpolator(f32, lerp, 32);

pub fn main() void {
    var remote = Interpolator{};
    remote.push(0, 0); // confirmed: at tick 0, position 0
    // the snapshot at tick 5 never arrives…
    remote.push(10, 100); // …only tick 10, position 100

    std.debug.print("interpolation: rendering between snapshots at tick 0 and 10\n", .{});
    var tick: f32 = 0;
    while (tick <= 10) : (tick += 2.5) {
        std.debug.print("  render @ {d:.1} → {d:.1}\n", .{ tick, remote.sample(tick).? });
    }
    std.debug.print("  motion stays smooth straight through the missing tick-5 snapshot\n", .{});
}
