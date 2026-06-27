//! Message fragmentation + reassembly for payloads larger than one datagram.
//! A message is split into `frag_payload`-sized chunks (the last is smaller);
//! the receiver reassembles via fixed slots, each with a presence bitset, keyed
//! by a group id. Concurrent reassemblies are bounded by `slots`; exhaustion is
//! a counted degrade event (the `dropped` counter → tracer `onDrop` later).
//!
//! Reassembly is order-agnostic: fragments may arrive shuffled, duplicated, or
//! interleaved across groups (the reliable channel retransmits any that are lost).

const std = @import("std");
const BitSet = @import("core").BitSet;
const seq = @import("core").seq;
const SequenceBuffer = @import("core").SequenceBuffer;

pub const Meta = struct { group: u16, index: u16, count: u16 };

pub fn fragmentCount(len: usize, frag_payload: usize) usize {
    if (len == 0) return 1;
    return (len + frag_payload - 1) / frag_payload;
}

pub fn fragmentSlice(bytes: []const u8, index: usize, frag_payload: usize) []const u8 {
    const off = index * frag_payload;
    const end = @min(off + frag_payload, bytes.len);
    return bytes[off..end];
}

pub fn Reassembler(comptime frag_payload: usize, comptime max_frags: usize, comptime slots: usize) type {
    const max_msg = frag_payload * max_frags;
    return struct {
        const Self = @This();
        pub const max_message = max_msg;

        const Slot = struct {
            active: bool = false,
            group: u16 = 0,
            count: u16 = 0,
            channel: u8 = 0,
            got: u16 = 0,
            len: usize = 0,
            received: BitSet(max_frags) = .{},
            data: [max_msg]u8 = undefined,
        };

        slots: [slots]Slot = [_]Slot{.{}} ** slots,
        // Recently-completed group ids. Fragment frames bypass the channel's dedup, so a
        // retransmitted or duplicated fragment of an *already-finished* block would
        // otherwise re-allocate a slot that never fills and leak it. This wrap-correct
        // window drops such late dups instead. (Sized well above the in-flight blocks.)
        done: SequenceBuffer(void, 64, u16) = .{},
        dropped: u64 = 0,

        pub const Complete = struct { channel: u8, bytes: []const u8 };

        fn find(self: *Self, group: u16) ?*Slot {
            for (&self.slots) |*s| {
                if (s.active and s.group == group) return s;
            }
            return null;
        }
        fn alloc(self: *Self, group: u16, count: u16, channel: u8) ?*Slot {
            for (&self.slots) |*s| {
                if (!s.active) {
                    s.* = .{ .active = true, .group = group, .count = count, .channel = channel };
                    return s;
                }
            }
            return null;
        }

        /// Feed one fragment. Returns the reassembled message when the group
        /// completes (bytes valid until the next `feed`), else null.
        pub fn feed(self: *Self, channel: u8, meta: Meta, chunk: []const u8) ?Complete {
            if (meta.count == 0 or meta.count > max_frags or meta.index >= meta.count) {
                self.dropped += 1;
                return null;
            }
            if (self.done.exists(meta.group)) return null; // late dup/retransmit of a finished block
            const s = self.find(meta.group) orelse (self.alloc(meta.group, meta.count, channel) orelse {
                self.dropped += 1; // slot exhaustion / late-completion contention
                return null;
            });
            if (s.received.isSet(meta.index)) return null; // duplicate
            const off = @as(usize, meta.index) * frag_payload;
            if (off + chunk.len > max_msg) {
                self.dropped += 1;
                return null;
            }
            @memcpy(s.data[off .. off + chunk.len], chunk);
            s.received.set(meta.index);
            s.got += 1;
            if (meta.index == meta.count - 1) s.len = off + chunk.len; // last sets total length
            if (s.got == s.count) {
                const result = Complete{ .channel = s.channel, .bytes = s.data[0..s.len] };
                s.active = false; // free; bytes valid until next feed touches this slot
                self.done.insert(meta.group, {}); // remember it so late dups don't re-alloc
                return result;
            }
            return null;
        }

        pub fn active(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |s| {
                if (s.active) n += 1;
            }
            return n;
        }
    };
}

const testing = std.testing;

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
}

const FP = 200;
const Reasm = Reassembler(FP, 64, 4);

test "in-order reassembly" {
    var msg: [5000]u8 = undefined;
    fillPattern(&msg);
    var r = Reasm{};
    const n = fragmentCount(msg.len, FP);
    var i: usize = 0;
    var done: ?Reasm.Complete = null;
    while (i < n) : (i += 1) {
        const meta = Meta{ .group = 1, .index = @intCast(i), .count = @intCast(n) };
        done = r.feed(9, meta, fragmentSlice(&msg, i, FP));
    }
    try testing.expect(done != null);
    try testing.expectEqual(@as(u8, 9), done.?.channel);
    try testing.expectEqualSlices(u8, &msg, done.?.bytes);
}

test "reassembly under shuffle + duplication" {
    var msg: [5000]u8 = undefined;
    fillPattern(&msg);
    const n = fragmentCount(msg.len, FP);

    var order: [25]usize = undefined;
    try testing.expectEqual(@as(usize, 25), n);
    for (&order, 0..) |*o, i| o.* = i;
    var prng = std.Random.DefaultPrng.init(0xF7A6);
    prng.random().shuffle(usize, &order);

    var r = Reasm{};
    var done: ?Reasm.Complete = null;
    for (order) |idx| {
        const meta = Meta{ .group = 7, .index = @intCast(idx), .count = @intCast(n) };
        const chunk = fragmentSlice(&msg, idx, FP);
        // feed each fragment twice (duplicate); completion happens exactly once
        const a = r.feed(3, meta, chunk);
        const b = r.feed(3, meta, chunk);
        if (a) |c| done = c;
        try testing.expect(b == null); // dup never re-completes
    }
    try testing.expect(done != null);
    try testing.expectEqualSlices(u8, &msg, done.?.bytes);
}

test "concurrent groups interleave; slot exhaustion is a counted degrade" {
    var r = Reasm{}; // 4 slots
    // start 5 distinct groups (one fragment each, none completing): the 5th can't get a slot
    var g: u16 = 0;
    while (g < 5) : (g += 1) {
        const meta = Meta{ .group = g, .index = 0, .count = 3 };
        _ = r.feed(0, meta, "abc");
    }
    try testing.expectEqual(@as(usize, 4), r.active());
    try testing.expect(r.dropped >= 1); // 5th group dropped (slot exhaustion)
}

test "malformed fragment metadata is rejected" {
    var r = Reasm{};
    try testing.expect(r.feed(0, .{ .group = 1, .index = 5, .count = 3 }, "x") == null); // index ≥ count
    try testing.expect(r.feed(0, .{ .group = 1, .index = 0, .count = 0 }, "x") == null); // count 0
    try testing.expect(r.dropped >= 2);
}
