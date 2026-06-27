//! Delta / relative / varint encodings for the control plane and sequence fields.
//!
//! - Byte-aligned LEB128 varints (+ zigzag signed) for control fields.
//! - Truncated packet-number encoding (QUIC RFC 9000 §A): send only enough low
//!   bytes to disambiguate against the largest acked, reconstruct by windowing.
//! - Bucketed relative-int (yojimbo): tiny deltas in very few bits.

const std = @import("std");
const bitpack = @import("bitpack.zig");

// ----- byte-aligned cursors (control plane) -----

pub const ByteWriter = struct {
    buf: []u8,
    pos: usize = 0,
    overflowed: bool = false,

    pub fn init(buf: []u8) ByteWriter {
        return .{ .buf = buf };
    }
    pub fn byte(self: *ByteWriter, b: u8) void {
        if (self.pos < self.buf.len) {
            self.buf[self.pos] = b;
            self.pos += 1;
        } else self.overflowed = true;
    }
    pub fn varint(self: *ByteWriter, value: u64) void {
        var x = value;
        while (x >= 0x80) {
            self.byte(@truncate(x | 0x80));
            x >>= 7;
        }
        self.byte(@truncate(x));
    }
    pub fn varintSigned(self: *ByteWriter, value: i64) void {
        self.varint(zigzag(value));
    }
    pub fn finish(self: *ByteWriter) []u8 {
        return self.buf[0..self.pos];
    }
};

pub const ByteReader = struct {
    buf: []const u8,
    pos: usize = 0,
    failed: bool = false,

    pub fn init(buf: []const u8) ByteReader {
        return .{ .buf = buf };
    }
    pub fn byte(self: *ByteReader) u8 {
        if (self.pos < self.buf.len) {
            const b = self.buf[self.pos];
            self.pos += 1;
            return b;
        }
        self.failed = true;
        return 0;
    }
    pub fn varint(self: *ByteReader) u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = self.byte();
            if (self.failed) return 0;
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) break;
            shift += 7;
            if (shift >= 64) {
                self.failed = true;
                return 0;
            }
        }
        return result;
    }
    pub fn varintSigned(self: *ByteReader) i64 {
        return unzigzag(self.varint());
    }
};

pub fn zigzag(v: i64) u64 {
    const uv: u64 = @bitCast(v);
    return (uv << 1) ^ @as(u64, @bitCast(v >> 63));
}
pub fn unzigzag(u: u64) i64 {
    const x: i64 = @bitCast(u >> 1);
    const neg: i64 = -@as(i64, @intCast(u & 1));
    return x ^ neg;
}

// ----- truncated packet numbers -----

/// How many bytes (1..4) to encode `pn` so it is unambiguous given the largest
/// packet number already acknowledged.
pub fn pnLength(pn: u64, largest_acked: ?u64) u3 {
    const range: u64 = if (largest_acked) |la| (pn -% la) else pn + 1;
    if (range < (@as(u64, 1) << 7)) return 1;
    if (range < (@as(u64, 1) << 15)) return 2;
    if (range < (@as(u64, 1) << 23)) return 3;
    return 4;
}

pub fn writePn(w: *ByteWriter, pn: u64, nbytes: u3) void {
    var i: u3 = 0;
    while (i < nbytes) : (i += 1) {
        w.byte(@truncate(pn >> (@as(u6, i) * 8)));
    }
}

pub fn readPn(r: *ByteReader, nbytes: u3, expected: u64) u64 {
    var truncated: u64 = 0;
    var i: u3 = 0;
    while (i < nbytes) : (i += 1) {
        truncated |= @as(u64, r.byte()) << (@as(u6, i) * 8);
    }
    return reconstructPn(truncated, nbytes, expected);
}

fn absDiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

pub fn reconstructPn(truncated: u64, nbytes: u3, expected: u64) u64 {
    const nbits: u7 = @as(u7, nbytes) * 8; // 8..32
    const win: u64 = @as(u64, 1) << @intCast(nbits);
    const mask = win - 1;
    const base = expected & ~mask;
    const c0 = base | (truncated & mask);
    var best = c0;
    var best_d = absDiff(c0, expected);
    const c2 = (base +% win) | (truncated & mask);
    if (absDiff(c2, expected) < best_d) {
        best = c2;
        best_d = absDiff(c2, expected);
    }
    if (base >= win) {
        const c1 = (base - win) | (truncated & mask);
        if (absDiff(c1, expected) < best_d) best = c1;
    }
    return best;
}

// ----- bucketed relative-int (bit-level) -----

/// Encode `current - previous` (wrapping u32) in very few bits when small.
pub fn writeRelative(w: *bitpack.Writer, current: u32, previous: u32) void {
    const delta = current -% previous;
    if (delta == 1) {
        w.writeBits(1, 1);
        return;
    }
    w.writeBits(0, 1);
    if (delta >= 2 and delta <= 17) {
        w.writeBits(0, 2);
        w.writeBits(delta - 2, 4);
    } else if (delta >= 18 and delta <= 273) {
        w.writeBits(1, 2);
        w.writeBits(delta - 18, 8);
    } else if (delta >= 274 and delta <= 4369) {
        w.writeBits(2, 2);
        w.writeBits(delta - 274, 12);
    } else {
        w.writeBits(3, 2);
        w.writeBits(delta, 32);
    }
}

pub fn readRelative(r: *bitpack.Reader, previous: u32) u32 {
    if (r.readBits(1) == 1) return previous +% 1;
    const bucket = r.readBits(2);
    const delta: u32 = switch (bucket) {
        0 => r.readBits(4) + 2,
        1 => r.readBits(8) + 18,
        2 => r.readBits(12) + 274,
        3 => r.readBits(32),
        else => unreachable,
    };
    return previous +% delta;
}

const testing = std.testing;

test "varint unsigned roundtrip" {
    const vals = [_]u64{ 0, 1, 127, 128, 255, 300, 16383, 16384, 1 << 40, std.math.maxInt(u64) };
    var buf: [128]u8 = undefined;
    var w = ByteWriter.init(&buf);
    for (vals) |v| w.varint(v);
    var r = ByteReader.init(w.finish());
    for (vals) |v| try testing.expectEqual(v, r.varint());
    try testing.expect(!r.failed);
}

test "varint signed (zigzag) roundtrip" {
    const vals = [_]i64{ 0, -1, 1, -2, 2, -1000, 1000, std.math.minInt(i64), std.math.maxInt(i64) };
    var buf: [128]u8 = undefined;
    var w = ByteWriter.init(&buf);
    for (vals) |v| w.varintSigned(v);
    var r = ByteReader.init(w.finish());
    for (vals) |v| try testing.expectEqual(v, r.varintSigned());
}

test "truncated PN reconstructs across many deltas" {
    const largest: u64 = 1_000_000;
    var delta: u64 = 0;
    while (delta < 200_000) : (delta += 777) {
        const pn = largest + delta + 1;
        const nbytes = pnLength(pn, largest);
        var buf: [8]u8 = undefined;
        var w = ByteWriter.init(&buf);
        writePn(&w, pn, nbytes);
        var r = ByteReader.init(w.finish());
        const got = readPn(&r, nbytes, largest + 1);
        try testing.expectEqual(pn, got);
    }
}

test "bucketed relative-int roundtrip across buckets" {
    const deltas = [_]u32{ 1, 2, 17, 18, 100, 273, 274, 4369, 4370, 1_000_000 };
    var buf: [64]u8 = undefined;
    for (deltas) |d| {
        var w = bitpack.Writer.init(&buf);
        const prev: u32 = 5000;
        writeRelative(&w, prev +% d, prev);
        var r = bitpack.Reader.init(w.finish());
        try testing.expectEqual(prev +% d, readRelative(&r, prev));
    }
}

test "relative '+1' is a single bit" {
    var buf: [8]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    writeRelative(&w, 43, 42);
    try testing.expectEqual(@as(usize, 1), w.bitCount());
}
