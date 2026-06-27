//! Ordered+sequenced blend on a single stream (RakNet's two-level-order trick,
//! #13). magnet's first-class model is one reliability mode per channel
//! (independent streams, no cross-channel HOL - which subsumes most uses), but when an
//! app genuinely wants *ordered* and *sequenced* messages interleaved on **one** stream
//! (an ordered "terminator" that must arrive after a burst of sequenced updates in its
//! slot), this primitive provides RakNet's single-key blend without a second channel.
//!
//! The key packs two levels into one integer: the ordering slot in the high bits, and
//! within a slot a sequenced message's `seq_idx` sorts *before* the ordered terminator
//! (`(1<<shift) − 1`). Releasing buffered messages by ascending key therefore yields:
//! slot 0's sequenced updates (newest wins), then slot 0's ordered message, then slot 1…

const std = @import("std");

pub const slot_shift: u6 = 20; // up to 2^20 sequenced messages per ordered slot

pub const Tag = struct {
    order: u32, // ordering slot
    seq_idx: u32 = 0, // position within the slot (sequenced messages)
    sequenced: bool = false, // false = the ordered message terminating the slot
};

/// The blended sort key: `order·2^shift + (sequenced ? seq_idx : 2^shift − 1)`.
pub fn key(t: Tag) u64 {
    const lo: u64 = if (t.sequenced) @min(t.seq_idx, (@as(u32, 1) << slot_shift) - 1) else (@as(u64, 1) << slot_shift) - 1;
    return (@as(u64, t.order) << slot_shift) | lo;
}

/// A single-stream receiver that releases a mixed ordered/sequenced message set in the
/// blended order, delivering only the newest sequenced message per slot. `cap` bounds
/// the in-flight buffer.
pub fn BlendReceiver(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Item = struct { used: bool = false, tag: Tag, val: T, key: u64 };

        items: [cap]Item = [_]Item{.{ .used = false, .tag = .{ .order = 0 }, .val = undefined, .key = 0 }} ** cap,
        next_order: u32 = 0, // next ordered slot to release
        last_seq_in_slot: u32 = 0, // newest sequenced index released for next_order
        delivered_key: u64 = 0,
        started: bool = false,

        /// Buffer a message. Stale sequenced messages (older than the newest seen for
        /// their slot) are dropped immediately; duplicates of the ordered terminator too.
        pub fn accept(self: *Self, tag: Tag, val: T) void {
            const k = key(tag);
            if (self.started and k <= self.delivered_key) return; // already past it
            // find a free slot or an existing same-slot sequenced entry to overwrite
            var free: ?usize = null;
            for (&self.items, 0..) |*it, i| {
                if (it.used and it.tag.order == tag.order and it.tag.sequenced and tag.sequenced) {
                    if (tag.seq_idx > it.tag.seq_idx) it.* = .{ .used = true, .tag = tag, .val = val, .key = k }; // newer wins
                    return;
                }
                if (!it.used and free == null) free = i;
            }
            if (free) |i| self.items[i] = .{ .used = true, .tag = tag, .val = val, .key = k };
        }

        /// Release the next message in blended order, or null if the next ordered slot
        /// isn't present yet. Sequenced updates for the current slot flow first.
        pub fn next(self: *Self) ?T {
            // smallest buffered key wins, but we may only advance contiguously past the
            // next ordered terminator (sequenced messages of future slots wait).
            var best: ?usize = null;
            var best_key: u64 = std.math.maxInt(u64);
            for (&self.items, 0..) |*it, i| {
                if (!it.used) continue;
                // don't release anything beyond the not-yet-arrived ordered terminator
                if (it.tag.order > self.next_order) continue;
                if (it.key < best_key) {
                    best = i;
                    best_key = it.key;
                }
            }
            const idx = best orelse return null;
            const it = &self.items[idx];
            const v = it.val;
            const tag = it.tag;
            it.used = false;
            self.delivered_key = it.key;
            self.started = true;
            if (!tag.sequenced) {
                self.next_order = tag.order + 1; // slot terminated → advance
            }
            return v;
        }
    };
}

const testing = std.testing;

test "blend key: sequenced sorts before the ordered terminator within a slot" {
    try testing.expect(key(.{ .order = 0, .seq_idx = 5, .sequenced = true }) < key(.{ .order = 0, .sequenced = false }));
    try testing.expect(key(.{ .order = 0, .sequenced = false }) < key(.{ .order = 1, .seq_idx = 0, .sequenced = true }));
    // higher seq within a slot sorts later (so newest is "last" before the terminator)
    try testing.expect(key(.{ .order = 2, .seq_idx = 1, .sequenced = true }) < key(.{ .order = 2, .seq_idx = 9, .sequenced = true }));
}

fn Collector(comptime N: usize) type {
    return struct {
        v: [N]u32 = undefined,
        n: usize = 0,
        fn drain(self: *@This(), r: anytype) void {
            while (r.next()) |x| {
                self.v[self.n] = x;
                self.n += 1;
            }
        }
    };
}

test "ordered+sequenced interleave on one stream: ordered in order, only newest sequenced per slot" {
    var r = BlendReceiver(u32, 32){};
    // slot 0: two sequenced updates (10, 11 - newest is 11) then the ordered terminator 100
    r.accept(.{ .order = 0, .seq_idx = 0, .sequenced = true }, 10);
    r.accept(.{ .order = 0, .seq_idx = 1, .sequenced = true }, 11);
    r.accept(.{ .order = 0, .sequenced = false }, 100);
    // slot 1 arrives out of order: terminator before its sequenced update
    r.accept(.{ .order = 1, .sequenced = false }, 101);
    r.accept(.{ .order = 1, .seq_idx = 0, .sequenced = true }, 20);

    var c = Collector(8){};
    c.drain(&r);
    // slot 0: newest sequenced (11) then ordered (100); slot 1: sequenced (20) then ordered (101)
    try testing.expectEqualSlices(u32, &.{ 11, 100, 20, 101 }, c.v[0..c.n]);
}

test "a future ordered slot waits until its predecessor's terminator arrives" {
    var r = BlendReceiver(u32, 32){};
    r.accept(.{ .order = 1, .sequenced = false }, 201); // slot 1 ready, slot 0 missing
    try testing.expect(r.next() == null); // can't skip slot 0
    r.accept(.{ .order = 0, .sequenced = false }, 200);
    try testing.expectEqual(@as(u32, 200), r.next().?);
    try testing.expectEqual(@as(u32, 201), r.next().?);
    try testing.expect(r.next() == null);
}
