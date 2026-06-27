//! Sparse **tick-history**: the universal replay buffer - prediction, confirmed,
//! input, and interpolation histories are all this one primitive. Stores only
//! *changes* keyed by tick and binary-searches "latest value ≤ T", so idle keyframes
//! cost nothing and late out-of-order inserts still resolve. `popUntil` re-anchors the
//! surviving value at the cut so future ticks keep resolving. Also holds the
//! `MismatchMask` - O(1) "already proved a mismatch at tick T" over the rollback window.
//! (The engine's *rollback storage backends* that build on this live in `store.zig`.)

const std = @import("std");

pub fn History(comptime T: type, comptime cap: usize) type {
    if (cap == 0) @compileError("History cap must be > 0");
    return struct {
        const Self = @This();
        pub const Entry = struct { tick: u32, val: T };

        entries: [cap]Entry = undefined,
        len: usize = 0,

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Record `val` at `tick`. Recording tick T makes it the new head and
        /// **discards the future** - entries with `tick' >= tick` are dropped first
        /// (so re-recording the current tick overwrites it, and a rollback replay
        /// cleanly overwrites the stale predicted entries). Full → drop the oldest.
        pub fn record(self: *Self, tick: u32, val: T) void {
            while (self.len > 0 and self.entries[self.len - 1].tick >= tick) self.len -= 1;
            if (self.len < cap) {
                self.entries[self.len] = .{ .tick = tick, .val = val };
                self.len += 1;
            } else {
                var i: usize = 1;
                while (i < cap) : (i += 1) self.entries[i - 1] = self.entries[i];
                self.entries[cap - 1] = .{ .tick = tick, .val = val };
            }
        }

        /// The value at the latest entry with `entry.tick <= tick`, or null.
        pub fn get(self: *const Self, tick: u32) ?T {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                if (self.entries[i].tick <= tick) return self.entries[i].val;
            }
            return null;
        }

        pub fn latest(self: *const Self) ?Entry {
            return if (self.len == 0) null else self.entries[self.len - 1];
        }
        pub fn oldest(self: *const Self) ?Entry {
            return if (self.len == 0) null else self.entries[0];
        }

        /// The bracketing entries around `tick`: `lo` = latest with `tick' <= tick`,
        /// `hi` = earliest with `tick' > tick`. Used for interpolation (lerp lo→hi).
        pub fn bracket(self: *const Self, tick: u32) struct { lo: ?Entry, hi: ?Entry } {
            var lo: ?Entry = null;
            var hi: ?Entry = null;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.entries[i].tick <= tick) {
                    lo = self.entries[i];
                } else {
                    hi = self.entries[i];
                    break;
                }
            }
            return .{ .lo = lo, .hi = hi };
        }

        /// Shift every entry's tick by `delta` - the must-hold invariant when the
        /// tick timeline hard-resyncs, so all history buffers stay aligned.
        pub fn shift(self: *Self, delta: i64) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                self.entries[i].tick = @intCast(@as(i64, self.entries[i].tick) + delta);
            }
        }

        /// Drop entries strictly older than `tick`, re-anchoring the surviving value
        /// at the cut so `get(tick)` still resolves after the trim.
        pub fn popUntil(self: *Self, tick: u32) void {
            if (self.len == 0) return;
            // find the value that covers `tick` (latest <= tick)
            var anchor: ?Entry = null;
            var first_keep: usize = self.len;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.entries[i].tick <= tick) anchor = self.entries[i];
                if (self.entries[i].tick > tick) {
                    first_keep = i;
                    break;
                }
            }
            // compact: [anchor@tick] ++ entries with tick > cut
            var out: usize = 0;
            if (anchor) |a| {
                self.entries[0] = .{ .tick = tick, .val = a.val };
                out = 1;
            }
            i = first_keep;
            while (i < self.len) : (i += 1) {
                self.entries[out] = self.entries[i];
                out += 1;
            }
            self.len = out;
        }
    };
}

/// O(1) dedup of rollback ticks over a 64-tick window: "have we already proved a
/// mismatch at tick T?" The window slides forward with the newest marked tick.
pub const MismatchMask = struct {
    bits: u64 = 0,
    base: u32 = 0,
    started: bool = false,

    pub fn mark(self: *MismatchMask, tick: u32) void {
        if (!self.started) {
            self.started = true;
            self.base = tick;
        }
        if (tick < self.base) return; // too old to track
        var off = tick - self.base;
        if (off >= 64) {
            // slide the window so `tick` is the newest bit
            const shift = off - 63;
            self.bits = if (shift >= 64) 0 else self.bits >> @intCast(shift);
            self.base += shift;
            off = 63;
        }
        self.bits |= @as(u64, 1) << @intCast(off);
    }

    pub fn isMarked(self: *const MismatchMask, tick: u32) bool {
        if (!self.started or tick < self.base) return false;
        const off = tick - self.base;
        if (off >= 64) return false;
        return (self.bits >> @intCast(off)) & 1 != 0;
    }
};

const testing = std.testing;

test "sparse history: get resolves latest ≤ tick across gaps" {
    var h = History(i32, 8){};
    h.record(0, 100);
    h.record(5, 150); // gap 1..4 resolve to 100
    h.record(10, 200);
    try testing.expectEqual(@as(i32, 100), h.get(0).?);
    try testing.expectEqual(@as(i32, 100), h.get(4).?);
    try testing.expectEqual(@as(i32, 150), h.get(5).?);
    try testing.expectEqual(@as(i32, 150), h.get(9).?);
    try testing.expectEqual(@as(i32, 200), h.get(100).?);
    try testing.expect(h.get(0) != null);
    var empty = History(i32, 4){};
    try testing.expect(empty.get(3) == null);
}

test "history overwrites the current tick and rings when full" {
    var h = History(u32, 3){};
    h.record(1, 11);
    h.record(1, 99); // overwrite
    try testing.expectEqual(@as(u32, 99), h.get(1).?);
    h.record(2, 22);
    h.record(3, 33);
    h.record(4, 44); // drops tick 1
    try testing.expect(h.get(1) == null);
    try testing.expectEqual(@as(u32, 44), h.get(4).?);
    try testing.expectEqual(@as(u32, 2), h.oldest().?.tick);
}

test "popUntil re-anchors the surviving value at the cut" {
    var h = History(i32, 8){};
    h.record(0, 10);
    h.record(3, 40);
    h.record(7, 80);
    h.popUntil(5); // keep value covering tick 5 (=40 from tick 3) anchored at 5, plus tick 7
    try testing.expectEqual(@as(i32, 40), h.get(5).?);
    try testing.expectEqual(@as(i32, 40), h.get(6).?);
    try testing.expectEqual(@as(i32, 80), h.get(7).?);
    try testing.expect(h.get(2) == null); // trimmed
}

test "mismatch mask marks, queries, and slides its window" {
    var m = MismatchMask{};
    m.mark(100);
    m.mark(102);
    try testing.expect(m.isMarked(100) and m.isMarked(102));
    try testing.expect(!m.isMarked(101));
    m.mark(200); // far ahead → window slides
    try testing.expect(m.isMarked(200));
    try testing.expect(!m.isMarked(100)); // fell out of the 64-window
}
