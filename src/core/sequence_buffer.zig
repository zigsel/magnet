//! SequenceBuffer - the most reused primitive in magnet (reliable.io / yojimbo /
//! laminar all converged on it). A rolling fixed-capacity map keyed by a
//! wrapping sequence number, with O(1) insert/get/remove and **zero payload
//! churn** on remove.
//!
//! Layout is hot/cold split: a parallel `tags` array holds the full sequence for
//! presence checks (sentinel = empty), and the `data` array is never cleared on
//! remove - only the tag is. Stale wrapped entries are invalidated by clearing
//! the tag span skipped when `latest` advances.

const std = @import("std");
const seq_mod = @import("seq.zig");

/// `T` payload, `capacity` slots, `Seq` the wrapping sequence type (e.g. u16).
/// Choose `capacity` so the sequence modulus is a multiple of it (e.g. a power
/// of two dividing 65536 for `u16`) to keep the index mapping wrap-consistent.
pub fn SequenceBuffer(comptime T: type, comptime capacity: usize, comptime Seq: type) type {
    if (capacity == 0) @compileError("SequenceBuffer capacity must be > 0");
    // Tag is one notch wider than Seq so a sentinel exists outside Seq's range.
    const Tag = if (@bitSizeOf(Seq) <= 16) u32 else u64;
    const empty: Tag = std.math.maxInt(Tag);

    return struct {
        const Self = @This();
        pub const cap = capacity;
        pub const Sequence = Seq;

        tags: [capacity]Tag = [_]Tag{empty} ** capacity,
        data: [capacity]T = undefined,
        latest: Seq = 0,
        has_latest: bool = false,

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            @memset(&self.tags, empty);
            self.has_latest = false;
            self.latest = 0;
        }

        inline fn index(s: Seq) usize {
            return @as(usize, s) % capacity;
        }

        /// Is `s` currently stored?
        pub fn exists(self: *const Self, s: Seq) bool {
            return self.tags[index(s)] == @as(Tag, s);
        }

        /// Most recent sequence inserted (only meaningful once `has_latest`).
        pub fn latestSeq(self: *const Self) ?Seq {
            return if (self.has_latest) self.latest else null;
        }

        /// Insert/overwrite `s` with `value`. Advances `latest` and invalidates
        /// any stale wrapped entries in the skipped span.
        pub fn insert(self: *Self, s: Seq, value: T) void {
            if (!self.has_latest) {
                self.has_latest = true;
                self.latest = s;
            } else if (seq_mod.greaterThan(Seq, s, self.latest)) {
                // Clear (latest, s] so wrapped stale tags can't masquerade.
                self.clearRange(self.latest +% 1, s);
                self.latest = s;
            }
            const i = index(s);
            self.tags[i] = @as(Tag, s);
            self.data[i] = value;
        }

        /// Pointer to the stored payload for `s`, or null if absent.
        pub fn get(self: *Self, s: Seq) ?*T {
            const i = index(s);
            if (self.tags[i] != @as(Tag, s)) return null;
            return &self.data[i];
        }

        pub fn getConst(self: *const Self, s: Seq) ?*const T {
            const i = index(s);
            if (self.tags[i] != @as(Tag, s)) return null;
            return &self.data[i];
        }

        /// Remove `s` if present (clears only the tag, not the payload).
        pub fn remove(self: *Self, s: Seq) void {
            const i = index(s);
            if (self.tags[i] == @as(Tag, s)) self.tags[i] = empty;
        }

        /// Insert only if `s` is not older than the window would allow and not a
        /// duplicate. Returns true if it was newly inserted.
        pub fn insertIfNew(self: *Self, s: Seq, value: T) bool {
            if (self.has_latest) {
                // reject entries older than the buffer can represent
                if (seq_mod.lessThan(Seq, s, self.latest -% @as(Seq, @intCast(capacity - 1)))) return false;
                if (self.exists(s)) return false;
            }
            self.insert(s, value);
            return true;
        }

        /// Clear tags for sequences [start, finish] inclusive (used internally).
        fn clearRange(self: *Self, start: Seq, finish: Seq) void {
            // If the span covers the whole buffer, clear everything once.
            if (@as(usize, finish -% start) >= capacity) {
                @memset(&self.tags, empty);
                return;
            }
            var s = start;
            while (true) {
                self.tags[index(s)] = empty;
                if (s == finish) break;
                s +%= 1;
            }
        }
    };
}

const testing = std.testing;

test "insert/get/remove roundtrip" {
    var sb = SequenceBuffer(u32, 256, u16).init();
    try testing.expect(!sb.exists(10));
    sb.insert(10, 1234);
    try testing.expect(sb.exists(10));
    try testing.expectEqual(@as(u32, 1234), sb.get(10).?.*);
    sb.remove(10);
    try testing.expect(!sb.exists(10));
    try testing.expect(sb.get(10) == null);
}

test "latest tracks newest, out-of-order older still stored" {
    var sb = SequenceBuffer(u8, 256, u16).init();
    sb.insert(10, 1);
    sb.insert(8, 2); // older; must not move latest
    try testing.expectEqual(@as(u16, 10), sb.latestSeq().?);
    try testing.expect(sb.exists(8));
    try testing.expect(sb.exists(10));
}

test "advancing latest invalidates stale wrapped entry at same index" {
    // capacity 16: index = seq % 16. seq 5 and seq 21 share index 5.
    var sb = SequenceBuffer(u8, 16, u16).init();
    sb.insert(5, 100);
    try testing.expect(sb.exists(5));
    // Jump latest forward past 21; the skipped-span clear must wipe index 5's tag.
    sb.insert(21, 200);
    try testing.expect(!sb.exists(5)); // 5 no longer present (its slot reused-window)
    try testing.expect(sb.exists(21));
    try testing.expectEqual(@as(u8, 200), sb.get(21).?.*);
}

test "large jump clears whole buffer" {
    var sb = SequenceBuffer(u8, 32, u16).init();
    var i: u16 = 0;
    while (i < 20) : (i += 1) sb.insert(i, @intCast(i));
    sb.insert(10000, 7); // huge jump
    try testing.expect(sb.exists(10000));
    // everything older is gone
    i = 0;
    while (i < 20) : (i += 1) try testing.expect(!sb.exists(i));
}

test "insertIfNew rejects duplicates and too-old" {
    var sb = SequenceBuffer(u8, 64, u16).init();
    try testing.expect(sb.insertIfNew(100, 1));
    try testing.expect(!sb.insertIfNew(100, 2)); // duplicate
    try testing.expect(sb.insertIfNew(150, 3));
    try testing.expect(!sb.insertIfNew(50, 4)); // older than window (150-63)
    try testing.expectEqual(@as(u8, 1), sb.get(100).?.*); // unchanged
}

test "wrap soak: insert a long monotonically increasing stream" {
    var sb = SequenceBuffer(u16, 256, u16).init();
    var s: u16 = 0;
    var n: usize = 0;
    while (n < 100_000) : (n += 1) {
        sb.insert(s, s);
        try testing.expect(sb.exists(s));
        // an entry 300 back (outside capacity 256) must not be present
        if (n >= 300) try testing.expect(!sb.exists(s -% 300));
        s +%= 1;
    }
}

// Exit gate: random insert/remove vs a reference model. Inserts advance
// near `latest` with bounded gaps so the live set always fits the window; the
// model evicts anything that falls outside it (the exact point the buffer's
// skipped-span / overwrite logic invalidates the slot), then asserts presence
// and value agree for every live key on every op.
test "fuzz: random insert/remove agrees with a windowed reference model" {
    const cap = 64;
    var sb = SequenceBuffer(u32, cap, u16).init();
    var model = std.AutoHashMap(u16, u32).init(testing.allocator);
    defer model.deinit();

    var prng = std.Random.DefaultPrng.init(0xF00DCAFE);
    const rnd = prng.random();
    var latest: u16 = 0;
    var have = false;

    var op: usize = 0;
    while (op < 40_000) : (op += 1) {
        if (rnd.boolean() or !have) {
            const gap: u16 = rnd.intRangeAtMost(u16, 0, cap / 2);
            const s: u16 = if (have) latest +% gap else 0;
            const val = rnd.int(u32);
            sb.insert(s, val);
            try model.put(s, val);
            if (!have or seq_mod.greaterThan(u16, s, latest)) latest = s;
            have = true;

            // Evict model entries now older than the window can represent.
            var dead: [cap]u16 = undefined;
            var nd: usize = 0;
            var it = model.keyIterator();
            while (it.next()) |k| {
                if (seq_mod.lessThan(u16, k.*, latest -% @as(u16, cap - 1))) {
                    dead[nd] = k.*;
                    nd += 1;
                }
            }
            for (dead[0..nd]) |k| _ = model.remove(k);
        } else {
            var it = model.keyIterator();
            if (it.next()) |k| {
                const key = k.*;
                sb.remove(key);
                _ = model.remove(key);
            }
        }

        var it2 = model.iterator();
        while (it2.next()) |e| {
            try testing.expect(sb.exists(e.key_ptr.*));
            try testing.expectEqual(e.value_ptr.*, sb.get(e.key_ptr.*).?.*);
        }
    }
}
