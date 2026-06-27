//! Redundant 32-bit ack-bitfield (reliable.io / Gaffer), the opt-in alternate to the
//! default RLE ack-ranges. Each packet re-acks the previous 32: `ack` is
//! the most-recent received sequence and bit *i* is set iff `(ack - 1 - i)` was also
//! received. No dedicated ack packets and near-zero header cost, but bounded to a
//! 33-packet horizon - pick it (per-config) when a fixed tiny window is preferable to
//! exact unbounded loss feedback. Generic over the sequence width.

const std = @import("std");
const seq = @import("core").seq;

pub fn AckBits(comptime Seq: type) type {
    return struct {
        pub const Frame = struct { ack: Seq, bits: u32 };

        /// Build the `(ack, bits)` pair from a received-sequence set (`recv.exists(s)`),
        /// covering `ack` and the 32 sequences below it.
        pub fn generate(recv: anytype, ack: Seq) Frame {
            var bits: u32 = 0;
            var i: u5 = 0;
            while (true) {
                const s = ack -% @as(Seq, i) -% 1;
                if (recv.exists(s)) bits |= (@as(u32, 1) << i);
                if (i == 31) break;
                i += 1;
            }
            return .{ .ack = ack, .bits = bits };
        }

        /// Call `ctx.ack(s)` for `ack` and every set bit below it.
        pub fn forEachAcked(f: Frame, ctx: anytype) void {
            ctx.ack(f.ack);
            var i: u5 = 0;
            while (true) {
                if (f.bits & (@as(u32, 1) << i) != 0) ctx.ack(f.ack -% @as(Seq, i) -% 1);
                if (i == 31) break;
                i += 1;
            }
        }

        pub fn encode(f: Frame, buf: []u8) ?usize {
            const sb = @sizeOf(Seq);
            if (buf.len < sb + 4) return null;
            std.mem.writeInt(Seq, buf[0..sb], f.ack, .little);
            std.mem.writeInt(u32, buf[sb..][0..4], f.bits, .little);
            return sb + 4;
        }
        pub fn decode(buf: []const u8) ?Frame {
            const sb = @sizeOf(Seq);
            if (buf.len < sb + 4) return null;
            return .{ .ack = std.mem.readInt(Seq, buf[0..sb], .little), .bits = std.mem.readInt(u32, buf[sb..][0..4], .little) };
        }
    };
}

const testing = std.testing;
const SequenceBuffer = @import("core").SequenceBuffer;

test "ack-bitfield reproduces the received set within the 33-packet window" {
    var recv = SequenceBuffer(void, 256, u16).init();
    // received 100..105 and 108, missing 106/107
    for ([_]u16{ 100, 101, 102, 103, 104, 105, 108 }) |s| recv.insert(s, {});
    const A = AckBits(u16);
    const f = A.generate(&recv, 108);

    var buf: [8]u8 = undefined;
    const n = A.encode(f, &buf).?;
    const back = A.decode(buf[0..n]).?;
    try testing.expectEqual(f.ack, back.ack);
    try testing.expectEqual(f.bits, back.bits);

    var out = SequenceBuffer(void, 256, u16).init();
    const C = struct {
        set: *SequenceBuffer(void, 256, u16),
        pub fn ack(self: *@This(), s: u16) void {
            self.set.insert(s, {});
        }
    };
    var c = C{ .set = &out };
    A.forEachAcked(back, &c);
    for ([_]u16{ 100, 101, 102, 103, 104, 105, 108 }) |s| try testing.expect(out.exists(s));
    try testing.expect(!out.exists(106));
    try testing.expect(!out.exists(107));
}

test "lossless stream sets all 32 bits" {
    var recv = SequenceBuffer(void, 256, u16).init();
    var s: u16 = 0;
    while (s < 40) : (s += 1) recv.insert(s, {});
    const f = AckBits(u16).generate(&recv, 39);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), f.bits);
}
