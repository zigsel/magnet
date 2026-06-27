//! Quantization primitives for the hot snapshot path: bounded integers packed in
//! exactly the bits their range needs, and compressed floats quantized to a fixed
//! bit budget over a known range. Used directly and (later) wired into the derived
//! serializer via a `pub const net` precision decl on a message type.

const std = @import("std");
const bitpack = @import("bitpack.zig");

/// Bits required to represent every value in the inclusive range [min, max].
pub fn bitsForRange(min: i64, max: i64) u7 {
    std.debug.assert(max >= min);
    const range: u64 = @intCast(max - min);
    if (range == 0) return 0;
    return @intCast(64 - @clz(range));
}

pub fn writeRangedInt(w: *bitpack.Writer, value: i64, min: i64, max: i64) void {
    std.debug.assert(value >= min and value <= max);
    const offset: u64 = @intCast(value - min);
    w.writeBits64(offset, bitsForRange(min, max));
}

pub fn readRangedInt(r: *bitpack.Reader, min: i64, max: i64) i64 {
    const offset = r.readBits64(bitsForRange(min, max));
    return min + @as(i64, @intCast(offset));
}

/// Quantize a float in [min, max] to `bits` (≤ 32) and pack it.
pub fn writeFloat(w: *bitpack.Writer, value: f32, min: f32, max: f32, bits: u6) void {
    std.debug.assert(bits >= 1 and bits <= 32);
    const clamped = std.math.clamp(value, min, max);
    const maxq: f32 = @floatFromInt((@as(u64, 1) << bits) - 1);
    const norm = (clamped - min) / (max - min);
    const q: u64 = @intFromFloat(@round(norm * maxq));
    w.writeBits64(q, bits);
}

pub fn readFloat(r: *bitpack.Reader, min: f32, max: f32, bits: u6) f32 {
    std.debug.assert(bits >= 1 and bits <= 32);
    const maxq: f32 = @floatFromInt((@as(u64, 1) << bits) - 1);
    const q = r.readBits64(bits);
    const norm = @as(f32, @floatFromInt(q)) / maxq;
    return min + norm * (max - min);
}

/// The quantization step size (max absolute error is half this).
pub fn floatResolution(min: f32, max: f32, bits: u6) f32 {
    const maxq: f32 = @floatFromInt((@as(u64, 1) << bits) - 1);
    return (max - min) / maxq;
}

const inv_sqrt2: f32 = 0.7071067811865476;

/// Quaternion "smallest three": store which component is largest (2 bits) plus the
/// other three quantized to [-1/√2, 1/√2]; reconstruct the largest from unit
/// length. Input should be (approximately) unit length.
pub fn writeQuat(w: *bitpack.Writer, q: [4]f32, bits: u6) void {
    var largest: usize = 0;
    var maxabs = @abs(q[0]);
    inline for (1..4) |i| {
        if (@abs(q[i]) > maxabs) {
            maxabs = @abs(q[i]);
            largest = i;
        }
    }
    // q and -q are the same rotation; negate so the largest component is positive.
    const sign: f32 = if (q[largest] < 0) -1 else 1;
    w.writeBits(@intCast(largest), 2);
    inline for (0..4) |i| {
        if (i != largest) writeFloat(w, sign * q[i], -inv_sqrt2, inv_sqrt2, bits);
    }
}

pub fn readQuat(r: *bitpack.Reader, bits: u6) [4]f32 {
    const largest: usize = r.readBits(2);
    var out: [4]f32 = undefined;
    var sumsq: f32 = 0;
    inline for (0..4) |i| {
        if (i != largest) {
            const v = readFloat(r, -inv_sqrt2, inv_sqrt2, bits);
            out[i] = v;
            sumsq += v * v;
        }
    }
    out[largest] = @sqrt(@max(0.0, 1.0 - sumsq));
    return out;
}

/// Comptime-checked field precision spec. A message type opts in with
/// `pub const net = quantize.precision(@This(), .{ .field = ... })`; every named
/// field must exist on `T`. The returned spec is consumed by custom serializers.
pub fn precision(comptime T: type, comptime spec: anytype) @TypeOf(spec) {
    inline for (@typeInfo(@TypeOf(spec)).@"struct".fields) |f| {
        if (!@hasField(T, f.name)) {
            @compileError("precision: '" ++ f.name ++ "' is not a field of " ++ @typeName(T));
        }
    }
    return spec;
}

const testing = std.testing;

fn normalize(q: [4]f32) [4]f32 {
    const n = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return .{ q[0] / n, q[1] / n, q[2] / n, q[3] / n };
}

test "quaternion smallest-three roundtrip within tolerance" {
    const quats = [_][4]f32{
        normalize(.{ 0, 0, 0, 1 }),
        normalize(.{ 1, 0, 0, 1 }),
        normalize(.{ 0.3, -0.5, 0.2, 0.78 }),
        normalize(.{ -0.6, 0.6, -0.4, 0.33 }),
    };
    for (quats) |q| {
        var buf: [16]u8 = undefined;
        var w = bitpack.Writer.init(&buf);
        writeQuat(&w, q, 12);
        var r = bitpack.Reader.init(w.finish());
        const back = readQuat(&r, 12);
        // q and -back are the same rotation; accept whichever is closer.
        var d_pos: f32 = 0;
        var d_neg: f32 = 0;
        inline for (0..4) |i| {
            d_pos += @abs(back[i] - q[i]);
            d_neg += @abs(back[i] + q[i]);
        }
        try testing.expect(@min(d_pos, d_neg) < 0.02);
    }
}

const PrecHost = struct {
    px: f32,
    py: u16,
    pub const net = precision(@This(), .{
        .px = .{ .min = -1, .max = 1, .bits = 12 },
        .py = .{},
    });
};

test "precision comptime-checks field names" {
    try testing.expect(@hasDecl(PrecHost, "net"));
}

test "bitsForRange" {
    try testing.expectEqual(@as(u7, 0), bitsForRange(5, 5));
    try testing.expectEqual(@as(u7, 1), bitsForRange(0, 1));
    try testing.expectEqual(@as(u7, 8), bitsForRange(0, 255));
    try testing.expectEqual(@as(u7, 9), bitsForRange(0, 256));
    try testing.expectEqual(@as(u7, 8), bitsForRange(-100, 100)); // range 200 -> 8 bits
}

test "ranged int is exact and minimal" {
    var buf: [16]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    writeRangedInt(&w, -100, -128, 127); // 8-bit range
    writeRangedInt(&w, 1000, 0, 1023); // 10-bit range
    const before = w.bitCount();
    _ = w.finish();
    try testing.expectEqual(@as(usize, 18), before); // 8 + 10

    var r = bitpack.Reader.init(&buf);
    try testing.expectEqual(@as(i64, -100), readRangedInt(&r, -128, 127));
    try testing.expectEqual(@as(i64, 1000), readRangedInt(&r, 0, 1023));
}

test "compressed float within resolution" {
    var buf: [16]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    const v: f32 = 0.123456;
    writeFloat(&w, v, -1.0, 1.0, 16);
    _ = w.finish();
    var r = bitpack.Reader.init(&buf);
    const back = readFloat(&r, -1.0, 1.0, 16);
    const res = floatResolution(-1.0, 1.0, 16);
    try testing.expect(@abs(back - v) <= res);
}

test "compressed float clamps out-of-range" {
    var buf: [16]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    writeFloat(&w, 5.0, -1.0, 1.0, 12); // above max -> clamps to 1.0
    _ = w.finish();
    var r = bitpack.Reader.init(&buf);
    try testing.expectApproxEqAbs(@as(f32, 1.0), readFloat(&r, -1.0, 1.0, 12), 1e-3);
}
