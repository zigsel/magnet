//! Snapshot interpolation. Remote (non-predicted) entities are rendered
//! **behind** the server by an interpolation delay, so a `[behind, newest]` bracket
//! of confirmed snapshots is always available to lerp between - smooth motion under
//! jitter, and smooth *across loss gaps* (the bracket spans a missing tick, so a
//! dropped snapshot just stretches the interpolation instead of stalling). The
//! `ConfirmedHistory` is the sparse tick-history; `sample(render_tick)` finds the
//! bracket and lerps with the fractional overstep. `world.get` returns the
//! interpolated value for remotes and the predicted value for owned entities, so
//! render code is uniform.

const std = @import("std");
const History = @import("history.zig").History;

pub fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn Interpolator(comptime T: type, comptime lerp: fn (T, T, f32) T, comptime cap: usize) type {
    return struct {
        const Self = @This();
        hist: History(T, cap) = .{},

        /// A confirmed snapshot of the remote at server `tick`.
        pub fn push(self: *Self, tick: u32, val: T) void {
            self.hist.record(tick, val);
        }

        /// The interpolated value at `render_tick` (server time minus the delay).
        /// Clamps to the oldest/newest sample when render falls outside the bracket.
        pub fn sample(self: *const Self, render_tick: f32) ?T {
            if (render_tick < 0) return null;
            const floor_t: u32 = @intFromFloat(@floor(render_tick));
            const b = self.hist.bracket(floor_t);
            if (b.lo) |lo| {
                if (b.hi) |hi| {
                    const span: f32 = @floatFromInt(hi.tick - lo.tick);
                    const alpha = std.math.clamp((render_tick - @as(f32, @floatFromInt(lo.tick))) / span, 0, 1);
                    return lerp(lo.val, hi.val, alpha);
                }
                return lo.val; // render is at/after the newest sample → hold it
            }
            return if (self.hist.oldest()) |o| o.val else null; // before history → clamp
        }

        pub fn shift(self: *Self, delta: i64) void {
            self.hist.shift(delta);
        }
        pub fn newestTick(self: *const Self) ?u32 {
            return if (self.hist.latest()) |e| e.tick else null;
        }
    };
}

const testing = std.testing;

const TestInterp = Interpolator(f32, lerpF32, 32);

test "interpolation lerps between bracketing snapshots" {
    var ip = TestInterp{};
    ip.push(0, 0);
    ip.push(10, 100); // 10 ticks → 100 units
    try testing.expectApproxEqAbs(@as(f32, 0), ip.sample(0).?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 50), ip.sample(5).?, 1e-4); // halfway
    try testing.expectApproxEqAbs(@as(f32, 25), ip.sample(2.5).?, 1e-4); // fractional overstep
    try testing.expectApproxEqAbs(@as(f32, 100), ip.sample(10).?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), ip.sample(15).?, 1e-4); // past newest → hold
}

test "interpolation stays smooth across a dropped snapshot (loss tolerance)" {
    var ip = TestInterp{};
    ip.push(0, 0);
    // snapshot at tick 5 is "lost" - only 0 and 10 present; the bracket spans the gap
    ip.push(10, 100);
    // rendering through the gap is monotonic and continuous, not stalled
    try testing.expectApproxEqAbs(@as(f32, 40), ip.sample(4).?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 60), ip.sample(6).?, 1e-4);
    try testing.expect(ip.sample(6).? > ip.sample(4).?); // keeps advancing
}

test "tick resync shifts interpolation history" {
    var ip = TestInterp{};
    ip.push(100, 0);
    ip.push(110, 100);
    ip.shift(-100); // hard-resync moves the timeline back by 100
    try testing.expectEqual(@as(u32, 10), ip.newestTick().?);
    try testing.expectApproxEqAbs(@as(f32, 50), ip.sample(5).?, 1e-4); // now resolves at the new ticks
}
