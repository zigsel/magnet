//! Tick synchronization. Two synced timelines run off the local clock: the
//! **input** timeline ~RTT/2 ahead of the server (so inputs arrive just in time) and
//! the **interpolation** timeline behind it (so a render bracket always exists). A
//! **hysteresis** controller nudges a timeline's speed only after K same-direction
//! errors inside a deadband (avoiding oscillation); outside a hard bound it
//! **hard-resyncs**, which must shift *every* history buffer by the same delta
//! (`History.shift`/`Interpolator.shift`/`InputBuffer.shift`) so all buffers stay
//! tick-aligned - a must-hold invariant.

const std = @import("std");

/// An integer timeline with a fractional speed multiplier (`num/den`, 1.0 = 100/100).
pub const Timeline = struct {
    tick: i64 = 0,
    accum_ms: i64 = 0,
    tick_ms: i64,
    speed_num: i64 = 100,
    speed_den: i64 = 100,

    pub fn init(tick_ms: i64) Timeline {
        return .{ .tick_ms = tick_ms };
    }
    /// Advance by real `dt_ms`; emits as many ticks as accrued at the current speed.
    pub fn advance(self: *Timeline, dt_ms: i64) void {
        self.accum_ms += @divTrunc(dt_ms * self.speed_num, self.speed_den);
        while (self.accum_ms >= self.tick_ms) {
            self.accum_ms -= self.tick_ms;
            self.tick += 1;
        }
    }
    pub fn faster(self: *Timeline) void {
        self.speed_num = @min(self.speed_num + 2, 120); // up to +20%
    }
    pub fn slower(self: *Timeline) void {
        self.speed_num = @max(self.speed_num - 2, 80); // down to -20%
    }
    pub fn onTarget(self: *Timeline) void {
        self.speed_num = self.speed_den; // back to 1.0
    }
    /// Hard-resync: jump the timeline by `delta` ticks (callers shift all buffers too).
    pub fn resync(self: *Timeline, delta: i64) void {
        self.tick += delta;
        self.accum_ms = 0;
    }
};

pub const Action = union(enum) {
    none,
    faster,
    slower,
    /// Hard-resync: shift the timeline AND every history buffer by this many ticks.
    resync: i64,
};

/// Hysteresis speed controller. `error_ticks = target - local` (positive ⇒ behind ⇒
/// should speed up). Nudges only after `k` consecutive same-direction errors outside
/// the deadband; hard-resyncs past `bound`.
pub const Sync = struct {
    deadband: i64 = 1,
    bound: i64 = 8,
    k: u32 = 3,
    count: u32 = 0,
    dir: i8 = 0,

    pub fn update(self: *Sync, error_ticks: i64) Action {
        const mag = @abs(error_ticks);
        if (mag > self.bound) {
            self.count = 0;
            self.dir = 0;
            return .{ .resync = error_ticks };
        }
        if (mag <= self.deadband) {
            self.count = 0;
            self.dir = 0;
            return .none;
        }
        const d: i8 = if (error_ticks > 0) 1 else -1;
        if (d == self.dir) {
            self.count += 1;
        } else {
            self.dir = d;
            self.count = 1;
        }
        if (self.count >= self.k) {
            self.count = 0;
            return if (d > 0) .faster else .slower;
        }
        return .none;
    }
};

const testing = std.testing;

test "timeline advances at speed; faster/slower change the rate" {
    var tl = Timeline.init(10); // 10ms per tick
    tl.advance(35); // 3 ticks + 5ms
    try testing.expectEqual(@as(i64, 3), tl.tick);
    tl.faster(); // +2% → 102/100
    tl.onTarget();
    try testing.expectEqual(tl.speed_den, tl.speed_num);
    tl.resync(100);
    try testing.expectEqual(@as(i64, 103), tl.tick);
}

test "hysteresis nudges only after k same-direction errors; resync past the bound" {
    var s = Sync{ .deadband = 1, .bound = 8, .k = 3 };
    try testing.expect(s.update(0) == .none); // on target
    try testing.expect(s.update(2) == .none); // behind, 1st
    try testing.expect(s.update(2) == .none); // 2nd
    try testing.expect(s.update(2) == .faster); // 3rd same-direction → nudge faster
    // direction flip resets the counter (no oscillation)
    try testing.expect(s.update(-2) == .none);
    try testing.expect(s.update(-2) == .none);
    try testing.expect(s.update(-2) == .slower);
    // way off → hard resync with the delta
    switch (s.update(20)) {
        .resync => |d| try testing.expectEqual(@as(i64, 20), d),
        else => return error.TestUnexpectedResult,
    }
}

// resync must shift every buffer by the same delta to stay aligned
const History = @import("history.zig").History;
const Interpolator = @import("interpolate.zig").Interpolator;
const lerpF32 = @import("interpolate.zig").lerpF32;
const InputBuffer = @import("input.zig").InputBuffer;

test "hard-resync shifts all history buffers in lockstep" {
    var states = History(i32, 16){};
    var interp = Interpolator(f32, lerpF32, 16){};
    var inputs = InputBuffer(struct { a: u8 }, 64){};
    var tl = Timeline.init(16);
    tl.tick = 1000;

    states.record(1000, 7);
    interp.push(1000, 7.0);
    inputs.set(1000, .{ .a = 3 });

    // a hard-resync of -1000 ticks
    var s = Sync{ .bound = 8 };
    const act = s.update(-1000);
    const delta: i64 = switch (act) {
        .resync => |d| d,
        else => return error.TestUnexpectedResult,
    };
    tl.resync(delta);
    states.shift(delta);
    interp.shift(delta);
    inputs.shift(delta);

    // every timeline + buffer now agrees on the new tick numbering
    try testing.expectEqual(@as(i64, 0), tl.tick);
    try testing.expectEqual(@as(u32, 0), states.latest().?.tick);
    try testing.expectEqual(@as(u32, 0), interp.newestTick().?);
    try testing.expectEqual(@as(i32, 7), states.get(0).?); // still resolvable at the new tick
    try testing.expectEqual(@as(u8, 3), inputs.get(0).?.a);
}
