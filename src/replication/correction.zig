//! Visual correction smoothing. After a reconciliation snaps the *authoritative*
//! state, the rendered position shouldn't jump - it carries the old visual offset and
//! **decays it framerate-independently**: `factor = exp(ln(decay_ratio)/decay_period · dt)`,
//! so `decay_ratio` of the error remains after `decay_period`, regardless of frame dt
//! (two half-steps equal one full step exactly). This is render-only and never feeds
//! the authoritative/rollback state, so floats are fine here (unlike the CC path).

const std = @import("std");

pub const Mode = enum { smooth, snap, none };

/// Per-frame decay factor in (0,1): how much of the visual error survives `dt_ms`.
pub fn factor(decay_ratio: f32, decay_period_ms: f32, dt_ms: f32) f32 {
    std.debug.assert(decay_ratio > 0 and decay_ratio < 1);
    return @exp(@log(decay_ratio) / decay_period_ms * dt_ms);
}

/// A scalar visual offset that decays toward zero. The rendered value is
/// `authoritative + error`; a reconciliation that shifts the authoritative state by
/// `delta` adds `-delta` to `error` so the render stays put, then it smooths away.
pub fn Smoother(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        err: f32 = 0,
        decay_ratio: f32 = 0.1, // 10% of error remains after one period
        decay_period_ms: f32 = 100,

        /// A correction shifted authoritative state by `delta`; keep the render still.
        pub fn onCorrection(self: *Self, delta: f32) void {
            switch (mode) {
                .smooth => self.err -= delta,
                .snap, .none => self.err = 0, // no visual carry → instant snap
            }
        }
        /// Advance the visual error by `dt_ms`; returns the remaining error.
        pub fn advance(self: *Self, dt_ms: f32) f32 {
            if (mode == .smooth) self.err *= factor(self.decay_ratio, self.decay_period_ms, dt_ms);
            return self.err;
        }
        /// The value to render given the authoritative `auth`.
        pub fn render(self: *const Self, auth: f32) f32 {
            return auth + self.err;
        }
    };
}

const testing = std.testing;

test "decay factor is in (0,1) and framerate-independent" {
    const fa = factor(0.1, 100, 16);
    const fb = factor(0.1, 100, 32);
    try testing.expect(fa > 0 and fa < 1);
    // two 16ms steps == one 32ms step
    try testing.expectApproxEqAbs(fa * fa, fb, 1e-5);
    // a full period leaves ~decay_ratio of the error
    try testing.expectApproxEqAbs(factor(0.1, 100, 100), @as(f32, 0.1), 1e-5);
}

test "smooth carries the correction then decays it to ~zero" {
    var s = Smoother(.smooth){};
    s.onCorrection(10); // authoritative jumped +10 → render must not jump
    try testing.expectApproxEqAbs(@as(f32, -10), s.err, 1e-6);
    // render stays near the pre-correction visual at first
    try testing.expectApproxEqAbs(@as(f32, 90), s.render(100), 1e-6);
    // after many frames the error decays toward zero
    var i: usize = 0;
    while (i < 60) : (i += 1) _ = s.advance(16);
    try testing.expect(@abs(s.err) < 0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), s.render(100), 0.5);
}

test "snap mode applies no visual carry" {
    var s = Smoother(.snap){};
    s.onCorrection(10);
    try testing.expectEqual(@as(f32, 0), s.err);
    try testing.expectEqual(@as(f32, 100), s.render(100));
}
