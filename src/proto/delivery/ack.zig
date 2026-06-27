//! ACK ranges (the locked default). Newest→oldest run-length encoding of
//! received packet numbers, generic over the packet-number width `Seq` and the
//! block cap. Wire (inside an ACK frame):
//!   [largest:Seq][nblocks:u8][first_size:u16] then nblocks × [gap:u16][size:u16]
//! `first` block covers [largest-first_size+1 .. largest]; each subsequent block
//! sits `gap` missing pns below the previous block's bottom, with `size` pns. A
//! `STOP_WAITING` lower bound (`subtract_below`) is applied by the session before
//! generation to cap growth; here the `window` bound does the same job.

const std = @import("std");

pub fn Ack(comptime Seq: type, comptime max_blocks: usize) type {
    const seq_bytes = @sizeOf(Seq);
    return struct {
        pub const block_cap = max_blocks;

        pub const Frame = struct {
            largest: Seq,
            first_size: u16,
            /// ms the sender of this frame held `largest` before acking it; the receiver
            /// of the ACK subtracts it from the RTT sample (QUIC ack_delay, RFC 9002 §5.3).
            ack_delay: u16 = 0,
            gaps: [max_blocks]u16 = undefined,
            sizes: [max_blocks]u16 = undefined,
            nblocks: u8 = 0,
        };

        /// Build an ACK frame from a received-pn set (`recv.exists(pn)`), scanning
        /// down from `largest`, bounded to `window` pns and `max_blocks` blocks.
        pub fn generate(recv: anytype, largest: Seq, window: u16) Frame {
            var f = Frame{ .largest = largest, .first_size = 1 };
            var bottom = largest;
            var dist: u16 = 0;
            while (dist + 1 < window and recv.exists(bottom -% 1)) {
                bottom -%= 1;
                f.first_size += 1;
                dist += 1;
            }
            while (f.nblocks < max_blocks and dist + 1 < window) {
                var q = bottom -% 1;
                var gap: u16 = 0;
                while (dist + 1 < window and !recv.exists(q)) {
                    q -%= 1;
                    gap += 1;
                    dist += 1;
                }
                if (!recv.exists(q)) break; // hit the window edge in a gap
                var size: u16 = 1;
                while (dist + 1 < window and recv.exists(q -% 1)) {
                    q -%= 1;
                    size += 1;
                    dist += 1;
                }
                f.gaps[f.nblocks] = gap;
                f.sizes[f.nblocks] = size;
                f.nblocks += 1;
                bottom = q;
            }
            return f;
        }

        pub fn encode(f: Frame, buf: []u8) ?usize {
            const need = seq_bytes + 5 + @as(usize, f.nblocks) * 4;
            if (buf.len < need) return null;
            std.mem.writeInt(Seq, buf[0..seq_bytes], f.largest, .little);
            buf[seq_bytes] = f.nblocks;
            std.mem.writeInt(u16, buf[seq_bytes + 1 ..][0..2], f.ack_delay, .little);
            std.mem.writeInt(u16, buf[seq_bytes + 3 ..][0..2], f.first_size, .little);
            var p: usize = seq_bytes + 5;
            var i: usize = 0;
            while (i < f.nblocks) : (i += 1) {
                std.mem.writeInt(u16, buf[p..][0..2], f.gaps[i], .little);
                std.mem.writeInt(u16, buf[p + 2 ..][0..2], f.sizes[i], .little);
                p += 4;
            }
            return p;
        }

        pub const Decoded = struct { frame: Frame, len: usize };

        pub fn decode(buf: []const u8) ?Decoded {
            const head = seq_bytes + 5;
            if (buf.len < head) return null;
            var f = Frame{ .largest = std.mem.readInt(Seq, buf[0..seq_bytes], .little), .first_size = 0 };
            f.nblocks = buf[seq_bytes];
            if (f.nblocks > max_blocks) return null;
            f.ack_delay = std.mem.readInt(u16, buf[seq_bytes + 1 ..][0..2], .little);
            f.first_size = std.mem.readInt(u16, buf[seq_bytes + 3 ..][0..2], .little);
            if (f.first_size == 0) return null;
            var p: usize = head;
            var i: usize = 0;
            while (i < f.nblocks) : (i += 1) {
                if (p + 4 > buf.len) return null;
                f.gaps[i] = std.mem.readInt(u16, buf[p..][0..2], .little);
                f.sizes[i] = std.mem.readInt(u16, buf[p + 2 ..][0..2], .little);
                p += 4;
            }
            return .{ .frame = f, .len = p };
        }

        /// Call `ctx.ack(pn)` for every acknowledged packet number.
        pub fn forEachAcked(f: Frame, ctx: anytype) void {
            var bottom = f.largest -% (f.first_size - 1);
            ackRange(bottom, f.largest, ctx);
            var i: usize = 0;
            while (i < f.nblocks) : (i += 1) {
                if (f.sizes[i] == 0) break;
                const top = bottom -% f.gaps[i] -% 1;
                const blo = top -% (f.sizes[i] - 1);
                ackRange(blo, top, ctx);
                bottom = blo;
            }
        }

        fn ackRange(lo: Seq, hi: Seq, ctx: anytype) void {
            var pn = lo;
            while (true) {
                ctx.ack(pn);
                if (pn == hi) break;
                pn +%= 1;
            }
        }
    };
}

const testing = std.testing;
const SequenceBuffer = @import("core").SequenceBuffer;
const A16 = Ack(u16, 16);

const Collector = struct {
    set: *SequenceBuffer(void, 256, u16),
    pub fn ack(self: *@This(), pn: u16) void {
        self.set.insert(pn, {});
    }
};

test "ack-ranges roundtrip reproduces the received set" {
    var recv = SequenceBuffer(void, 256, u16).init();
    // received: 0..5, 8..10, 12  (gaps at 6,7 and 11)
    const got = [_]u16{ 0, 1, 2, 3, 4, 5, 8, 9, 10, 12 };
    for (got) |pn| recv.insert(pn, {});

    var f = A16.generate(&recv, 12, 128);
    f.ack_delay = 1234;
    var buf: [128]u8 = undefined;
    const n = A16.encode(f, &buf).?;
    const dec = A16.decode(buf[0..n]).?;
    try testing.expectEqual(@as(usize, n), dec.len);
    try testing.expectEqual(@as(u16, 1234), dec.frame.ack_delay); // ack_delay survives the wire

    var out = SequenceBuffer(void, 256, u16).init();
    var c = Collector{ .set = &out };
    A16.forEachAcked(dec.frame, &c);

    for (got) |pn| try testing.expect(out.exists(pn));
    try testing.expect(!out.exists(6));
    try testing.expect(!out.exists(7));
    try testing.expect(!out.exists(11));
}

test "lossless stream encodes a single block" {
    var recv = SequenceBuffer(void, 256, u16).init();
    var pn: u16 = 0;
    while (pn < 40) : (pn += 1) recv.insert(pn, {});
    const f = A16.generate(&recv, 39, 128);
    try testing.expectEqual(@as(u8, 0), f.nblocks); // one contiguous block, no gaps
}

test "wider PN width (u32) roundtrips" {
    const A32 = Ack(u32, 16);
    var recv = SequenceBuffer(void, 256, u32).init();
    const base: u32 = 1_000_000;
    for ([_]u32{ base, base + 1, base + 2, base + 5 }) |pn| recv.insert(pn, {});
    const f = A32.generate(&recv, base + 5, 128);
    var buf: [128]u8 = undefined;
    const n = A32.encode(f, &buf).?;
    const dec = A32.decode(buf[0..n]).?;
    try testing.expectEqual(base + 5, dec.frame.largest);
}
