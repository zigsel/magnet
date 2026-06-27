//! Bit-level reader/writer with a 64-bit scratch accumulator (yojimbo-style),
//! LSB-first, little-endian byte order. The hot path writes into a caller-owned
//! `[]u8`; there is no allocator. Reads are bounds-checked (set `failed`).

const std = @import("std");

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0, // next byte to write
    scratch: u64 = 0,
    nbits: u6 = 0, // bits buffered in scratch (0..7 after each flush)
    total_bits: usize = 0,
    overflowed: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// Write the low `bits` bits of `value` (bits ≤ 32).
    pub fn writeBits(self: *Writer, value: u32, bits: u6) void {
        std.debug.assert(bits <= 32);
        if (bits == 0) return;
        const mask = (@as(u64, 1) << bits) - 1;
        self.scratch |= (@as(u64, value) & mask) << self.nbits;
        self.nbits += bits;
        self.total_bits += bits;
        // 32-bit word fast-path: flush 4 bytes at once when a full word is buffered and
        // it fits - byte-identical (LSB-first LE) to the byte loop, just fewer stores.
        while (self.nbits >= 32 and self.pos + 4 <= self.buf.len) {
            std.mem.writeInt(u32, self.buf[self.pos..][0..4], @truncate(self.scratch), .little);
            self.pos += 4;
            self.scratch >>= 32;
            self.nbits -= 32;
        }
        while (self.nbits >= 8) {
            if (self.pos < self.buf.len) {
                self.buf[self.pos] = @truncate(self.scratch);
                self.pos += 1;
            } else {
                self.overflowed = true;
            }
            self.scratch >>= 8;
            self.nbits -= 8;
        }
    }

    /// Write up to 64 bits.
    pub fn writeBits64(self: *Writer, value: u64, bits: u7) void {
        std.debug.assert(bits <= 64);
        if (bits <= 32) {
            self.writeBits(@truncate(value), @intCast(bits));
        } else {
            self.writeBits(@truncate(value), 32);
            self.writeBits(@truncate(value >> 32), @intCast(bits - 32));
        }
    }

    pub fn writeBool(self: *Writer, b: bool) void {
        self.writeBits(@intFromBool(b), 1);
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) void {
        for (bytes) |byte| self.writeBits(byte, 8);
    }

    /// Flush any partial trailing byte (zero-padded) and return the written slice.
    pub fn finish(self: *Writer) []u8 {
        if (self.nbits > 0) {
            if (self.pos < self.buf.len) {
                self.buf[self.pos] = @truncate(self.scratch);
                self.pos += 1;
            } else {
                self.overflowed = true;
            }
            self.scratch = 0;
            self.nbits = 0;
        }
        return self.buf[0..self.pos];
    }

    pub fn bitCount(self: *const Writer) usize {
        return self.total_bits;
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    scratch: u64 = 0,
    nbits: u6 = 0,
    total_bits: usize = 0,
    failed: bool = false,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn readBits(self: *Reader, bits: u6) u32 {
        std.debug.assert(bits <= 32);
        if (bits == 0) return 0;
        while (self.nbits < bits) {
            const byte: u64 = if (self.pos < self.buf.len) self.buf[self.pos] else blk: {
                self.failed = true;
                break :blk 0;
            };
            self.pos += 1;
            self.scratch |= byte << self.nbits;
            self.nbits += 8;
        }
        const mask = (@as(u64, 1) << bits) - 1;
        const v: u32 = @truncate(self.scratch & mask);
        self.scratch >>= bits;
        self.nbits -= bits;
        self.total_bits += bits;
        return v;
    }

    pub fn readBits64(self: *Reader, bits: u7) u64 {
        std.debug.assert(bits <= 64);
        if (bits <= 32) return self.readBits(@intCast(bits));
        const lo: u64 = self.readBits(32);
        const hi: u64 = self.readBits(@intCast(bits - 32));
        return lo | (hi << 32);
    }

    pub fn readBool(self: *Reader) bool {
        return self.readBits(1) != 0;
    }

    pub fn readBytes(self: *Reader, out: []u8) void {
        for (out) |*byte| byte.* = @truncate(self.readBits(8));
    }

    pub fn bitCount(self: *const Reader) usize {
        return self.total_bits;
    }
};

const testing = std.testing;

test "bitpack roundtrip mixed widths" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeBits(5, 3); // 101
    w.writeBits(0, 1);
    w.writeBits(0xABCD, 16);
    w.writeBool(true);
    w.writeBits64(0xDEADBEEFCAFE, 48);
    w.writeBits(1, 32);
    const bytes = w.finish();
    try testing.expect(!w.overflowed);

    var r = Reader.init(bytes);
    try testing.expectEqual(@as(u32, 5), r.readBits(3));
    try testing.expectEqual(@as(u32, 0), r.readBits(1));
    try testing.expectEqual(@as(u32, 0xABCD), r.readBits(16));
    try testing.expectEqual(true, r.readBool());
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), r.readBits64(48));
    try testing.expectEqual(@as(u32, 1), r.readBits(32));
    try testing.expect(!r.failed);
}

test "bitpack reports overflow on a too-small buffer" {
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeBits(0xFFFF, 16);
    w.writeBits(0xFF, 8); // beyond 2 bytes
    _ = w.finish();
    try testing.expect(w.overflowed);
}

test "bitpack read past end sets failed" {
    var buf: [1]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeBits(3, 2);
    const bytes = w.finish();
    var r = Reader.init(bytes);
    _ = r.readBits(2);
    _ = r.readBits(32); // past end
    try testing.expect(r.failed);
}

test "byte count exact for byte-aligned writes" {
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeBytes(&.{ 1, 2, 3 });
    const bytes = w.finish();
    try testing.expectEqual(@as(usize, 3), bytes.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, bytes);
}
