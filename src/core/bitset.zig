//! Comptime-sized bitset over `[K]u64`. Used for the replay window, the
//! rollback mismatch mask, fragment presence maps, and room interest sets.

const std = @import("std");

pub fn BitSet(comptime bits: usize) type {
    const words = (bits + 63) / 64;
    return struct {
        const Self = @This();
        pub const bit_count = bits;
        words: [words]u64 = [_]u64{0} ** words,

        pub fn init() Self {
            return .{};
        }

        pub fn set(self: *Self, i: usize) void {
            self.words[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
        }

        pub fn clear(self: *Self, i: usize) void {
            self.words[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
        }

        pub fn isSet(self: *const Self, i: usize) bool {
            return (self.words[i >> 6] >> @intCast(i & 63)) & 1 != 0;
        }

        pub fn setAll(self: *Self) void {
            @memset(&self.words, ~@as(u64, 0));
        }

        pub fn clearAll(self: *Self) void {
            @memset(&self.words, 0);
        }

        pub fn popCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.words) |w| n += @popCount(w);
            return n;
        }

        /// True if any bit is shared with `other` (e.g. room-interest overlap).
        pub fn intersects(self: *const Self, other: *const Self) bool {
            for (self.words, other.words) |a, b| {
                if (a & b != 0) return true;
            }
            return false;
        }

        /// In-place bitwise AND (`self &= other`).
        pub fn andInto(self: *Self, other: *const Self) void {
            for (&self.words, other.words) |*w, o| w.* &= o;
        }

        /// In-place bitwise OR (`self |= other`).
        pub fn orInto(self: *Self, other: *const Self) void {
            for (&self.words, other.words) |*w, o| w.* |= o;
        }
    };
}

/// A sliding replay-protection window: accept each sequence at most once, reject
/// anything older than `window` behind the highest seen. Mirrors the netcode.io
/// `[256]u64`-style window, comptime-sized.
pub fn ReplayWindow(comptime window: usize, comptime Seq: type) type {
    const seq_mod = @import("seq.zig");
    return struct {
        const Self = @This();
        seen: BitSet(window) = .{},
        highest: Seq = 0,
        started: bool = false,

        pub fn init() Self {
            return .{};
        }

        /// Returns true if `s` is fresh (and records it); false if replayed/too-old.
        pub fn accept(self: *Self, s: Seq) bool {
            if (!self.started) {
                self.started = true;
                self.highest = s;
                self.seen.clearAll();
                self.seen.set(@as(usize, s) % window);
                return true;
            }
            if (seq_mod.greaterThan(Seq, s, self.highest)) {
                // advance: clear bits for the newly-uncovered span
                const advance = s -% self.highest;
                if (@as(usize, advance) >= window) {
                    self.seen.clearAll();
                } else {
                    var k: Seq = self.highest +% 1;
                    while (true) {
                        self.seen.clear(@as(usize, k) % window);
                        if (k == s) break;
                        k +%= 1;
                    }
                }
                self.highest = s;
                self.seen.set(@as(usize, s) % window);
                return true;
            } else {
                // within or below window
                const behind = self.highest -% s;
                if (@as(usize, behind) >= window) return false; // too old
                const idx = @as(usize, s) % window;
                if (self.seen.isSet(idx)) return false; // replay
                self.seen.set(idx);
                return true;
            }
        }
    };
}

const testing = std.testing;

test "bitset set/clear/isSet/popcount" {
    var bs = BitSet(200).init();
    try testing.expect(!bs.isSet(0));
    bs.set(0);
    bs.set(63);
    bs.set(64);
    bs.set(199);
    try testing.expect(bs.isSet(0) and bs.isSet(63) and bs.isSet(64) and bs.isSet(199));
    try testing.expectEqual(@as(usize, 4), bs.popCount());
    bs.clear(64);
    try testing.expect(!bs.isSet(64));
    try testing.expectEqual(@as(usize, 3), bs.popCount());
}

test "bitset intersects" {
    var a = BitSet(128).init();
    var b = BitSet(128).init();
    a.set(5);
    b.set(100);
    try testing.expect(!a.intersects(&b));
    b.set(5);
    try testing.expect(a.intersects(&b));
}

test "replay window accepts fresh, rejects replay and too-old" {
    var rw = ReplayWindow(64, u16).init();
    try testing.expect(rw.accept(100));
    try testing.expect(!rw.accept(100)); // replay
    try testing.expect(rw.accept(101));
    try testing.expect(rw.accept(99)); // within window, not yet seen
    try testing.expect(!rw.accept(99)); // now replay
    try testing.expect(rw.accept(200)); // big jump forward
    try testing.expect(!rw.accept(100)); // far too old now
}
