//! Wrapping sequence-number arithmetic (RFC 1982 serial-number comparison).
//!
//! One shared helper, parameterized by the unsigned width chosen per domain
//! (packet number `u64`, data sequence `u16`, fragment id `u16`, tick `u32`).
//! No copied magic half-range constants scattered across the codebase.

const std = @import("std");

fn halfRange(comptime W: type) W {
    const info = @typeInfo(W).int;
    if (info.signedness != .unsigned) @compileError("seq width must be unsigned");
    const shift: std.math.Log2Int(W) = @intCast(info.bits - 1);
    return @as(W, 1) << shift;
}

/// True if `a` precedes `b` in wrap-around order (a "older", b "newer").
pub fn lessThan(comptime W: type, a: W, b: W) bool {
    return a != b and (b -% a) < halfRange(W);
}

/// True if `a` follows `b` in wrap-around order (a "newer").
pub fn greaterThan(comptime W: type, a: W, b: W) bool {
    return lessThan(W, b, a);
}

pub fn lessThanEqual(comptime W: type, a: W, b: W) bool {
    return a == b or lessThan(W, a, b);
}

pub fn greaterThanEqual(comptime W: type, a: W, b: W) bool {
    return a == b or greaterThan(W, a, b);
}

/// The newer of two sequences.
pub fn max(comptime W: type, a: W, b: W) W {
    return if (greaterThan(W, a, b)) a else b;
}

/// The older of two sequences.
pub fn min(comptime W: type, a: W, b: W) W {
    return if (lessThan(W, a, b)) a else b;
}

test "lessThan basic, no wrap" {
    try std.testing.expect(lessThan(u16, 1, 2));
    try std.testing.expect(!lessThan(u16, 2, 1));
    try std.testing.expect(!lessThan(u16, 5, 5));
}

test "lessThan across the u16 wrap boundary" {
    // 0 is "newer" than 65535
    try std.testing.expect(lessThan(u16, 65535, 0));
    try std.testing.expect(!lessThan(u16, 0, 65535));
    try std.testing.expect(greaterThan(u16, 0, 65535));
    try std.testing.expect(lessThan(u16, 65530, 3));
    try std.testing.expect(greaterThan(u16, 3, 65530));
}

test "max/min pick the newer/older across wrap" {
    try std.testing.expectEqual(@as(u16, 0), max(u16, 65535, 0));
    try std.testing.expectEqual(@as(u16, 65535), min(u16, 65535, 0));
    try std.testing.expectEqual(@as(u16, 10), max(u16, 10, 4));
}

test "works for u64 packet numbers" {
    try std.testing.expect(lessThan(u64, 100, 200));
    // maxInt +% 1 == 0, so 0 is the *newer* sequence across the wrap.
    try std.testing.expect(lessThan(u64, std.math.maxInt(u64), 0));
    try std.testing.expect(greaterThan(u64, 0, std.math.maxInt(u64)));
}
