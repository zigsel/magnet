//! Fixed-point arithmetic - deterministic, allocation-free integer math used by
//! the congestion controllers (Cubic/BBR) and the deterministic authority modes
//! (`.p2p_rollback`, `.lockstep`). No `f64` anywhere, so transport replay and
//! cross-machine simulation are bit-reproducible.

const std = @import("std");

/// Signed fixed-point value with `frac` fractional bits backed by `Backing`
/// (a signed integer type). A double-width type is used for mul/div intermediates.
pub fn Fixed(comptime Backing: type, comptime frac: comptime_int) type {
    const bi = @typeInfo(Backing).int;
    if (bi.signedness != .signed) @compileError("Fixed backing must be signed");
    if (frac <= 0 or frac >= bi.bits) @compileError("frac must be in (0, bits)");
    const Wide = std.meta.Int(.signed, bi.bits * 2);

    return struct {
        const Self = @This();
        pub const one: Self = .{ .raw = @as(Backing, 1) << frac };
        pub const zero: Self = .{ .raw = 0 };
        pub const frac_bits = frac;

        raw: Backing,

        pub fn fromInt(x: anytype) Self {
            return .{ .raw = @as(Backing, @intCast(x)) << frac };
        }

        /// Build from a numerator/denominator ratio (e.g. fromRatio(9, 8)).
        pub fn fromRatio(num: i64, den: i64) Self {
            const n: Wide = @as(Wide, num) << frac;
            return .{ .raw = @intCast(@divTrunc(n, den)) };
        }

        pub fn toIntTrunc(self: Self) Backing {
            return self.raw >> frac;
        }

        pub fn toIntRound(self: Self) Backing {
            const half: Backing = @as(Backing, 1) << (frac - 1);
            return (self.raw + half) >> frac;
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .raw = a.raw + b.raw };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .raw = a.raw - b.raw };
        }

        pub fn mul(a: Self, b: Self) Self {
            const w: Wide = @as(Wide, a.raw) * b.raw;
            return .{ .raw = @intCast(w >> frac) };
        }

        pub fn div(a: Self, b: Self) Self {
            const w: Wide = @as(Wide, a.raw) << frac;
            return .{ .raw = @intCast(@divTrunc(w, b.raw)) };
        }

        /// Multiply by an integer scalar (exact, no rounding).
        pub fn scaleInt(a: Self, k: i64) Self {
            return .{ .raw = @intCast(@as(Wide, a.raw) * k) };
        }

        pub fn lt(a: Self, b: Self) bool {
            return a.raw < b.raw;
        }

        pub fn min(a: Self, b: Self) Self {
            return if (a.raw < b.raw) a else b;
        }

        pub fn max(a: Self, b: Self) Self {
            return if (a.raw > b.raw) a else b;
        }
    };
}

/// Convenient default: Q32.32 in i64.
pub const Q32 = Fixed(i64, 32);

const testing = std.testing;

test "fixed int roundtrip and add/sub" {
    const F = Fixed(i64, 16);
    const a = F.fromInt(7);
    const b = F.fromInt(5);
    try testing.expectEqual(@as(i64, 12), a.add(b).toIntTrunc());
    try testing.expectEqual(@as(i64, 2), a.sub(b).toIntTrunc());
}

test "fixed mul/div" {
    const F = Fixed(i64, 16);
    const a = F.fromInt(6);
    const b = F.fromInt(7);
    try testing.expectEqual(@as(i64, 42), a.mul(b).toIntTrunc());
    const c = F.fromInt(40);
    const d = F.fromInt(8);
    try testing.expectEqual(@as(i64, 5), c.div(d).toIntTrunc());
}

test "fromRatio 9/8 then *8 ~= 9" {
    const F = Fixed(i64, 16);
    const r = F.fromRatio(9, 8);
    try testing.expectEqual(@as(i64, 9), r.scaleInt(8).toIntRound());
}

test "round vs trunc" {
    const F = Fixed(i64, 8);
    const r = F.fromRatio(5, 2); // 2.5
    try testing.expectEqual(@as(i64, 2), r.toIntTrunc());
    try testing.expectEqual(@as(i64, 3), r.toIntRound());
}
