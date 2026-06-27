//! The reliability taxonomy as **comptime-monomorphized** receivers. Each mode
//! compiles in only the state it needs - an `unreliable` receiver has no
//! `SequenceBuffer` at all; `reliable_ordered` carries the reorder window; the
//! sequenced modes carry just a `latest` cursor. One `accept()` body, specialized
//! per mode at compile time.

const std = @import("std");
const seq = @import("core").seq;
const SequenceBuffer = @import("core").SequenceBuffer;

pub const Mode = enum {
    unreliable, // deliver as it arrives
    unreliable_sequenced, // drop anything older than the newest seen
    reliable_unordered, // dedup, deliver as it arrives
    reliable_ordered, // dedup + reorder → strictly in order, exactly once
    reliable_sequenced, // reliable dedup, but only the newest is delivered
    /// Ordered+sequenced blend on one stream (RakNet): reliable dedup at the carrier;
    /// the Session re-orders via a `BlendReceiver` keyed by a per-message tag carried
    /// in the payload (ordered messages in order, newest-sequenced-per-slot).
    reliable_ordered_sequenced,
};

pub fn isReliable(mode: Mode) bool {
    return switch (mode) {
        .reliable_unordered, .reliable_ordered, .reliable_sequenced, .reliable_ordered_sequenced => true,
        else => false,
    };
}

/// Send-side lazy dense data-sequence numbering: each channel assigns its own
/// monotonically increasing sequence at send time (keeps numbers dense → small
/// receiver hole-window).
pub const Sequencer = struct {
    next: u16 = 0,
    pub fn alloc(self: *Sequencer) u16 {
        const s = self.next;
        self.next +%= 1;
        return s;
    }
};

test "sequencer hands out dense increasing sequences" {
    var sq = Sequencer{};
    try std.testing.expectEqual(@as(u16, 0), sq.alloc());
    try std.testing.expectEqual(@as(u16, 1), sq.alloc());
    try std.testing.expectEqual(@as(u16, 2), sq.alloc());
}

pub fn Receiver(comptime mode: Mode, comptime T: type, comptime cap: usize, comptime Seq: type) type {
    const needs_reorder = mode == .reliable_ordered;
    const needs_seen = mode == .reliable_unordered or mode == .reliable_sequenced or mode == .reliable_ordered_sequenced;
    const needs_latest = mode == .unreliable_sequenced or mode == .reliable_sequenced;

    return struct {
        const Self = @This();

        expected: if (needs_reorder) Seq else void = if (needs_reorder) @as(Seq, 0) else {},
        reorder: if (needs_reorder) SequenceBuffer(T, cap, Seq) else void =
            if (needs_reorder) .{} else {},
        seen: if (needs_seen) SequenceBuffer(void, cap, Seq) else void =
            if (needs_seen) .{} else {},
        latest: if (needs_latest) Seq else void = if (needs_latest) @as(Seq, 0) else {},
        has_latest: if (needs_latest) bool else void = if (needs_latest) false else {},

        /// Accept a message with data-sequence `s`. Delivered messages (possibly
        /// several, for reorder) are pushed to `out` (anything with `push(T)`).
        pub fn accept(self: *Self, s: Seq, value: T, out: anytype) void {
            switch (mode) {
                .unreliable => out.push(value),
                .unreliable_sequenced => {
                    if (!self.has_latest or seq.greaterThan(Seq, s, self.latest)) {
                        self.latest = s;
                        self.has_latest = true;
                        out.push(value);
                    }
                },
                .reliable_unordered, .reliable_ordered_sequenced => {
                    // reliable dedup at the carrier; the Session's BlendReceiver does the
                    // ordered+sequenced re-ordering for `.reliable_ordered_sequenced`.
                    if (self.seen.exists(s)) return; // duplicate
                    self.seen.insert(s, {});
                    out.push(value);
                },
                .reliable_ordered => {
                    if (seq.lessThan(Seq, s, self.expected)) return; // already delivered
                    if (self.reorder.exists(s)) return; // duplicate
                    self.reorder.insert(s, value);
                    while (self.reorder.get(self.expected)) |v| {
                        out.push(v.*);
                        self.reorder.remove(self.expected);
                        self.expected +%= 1;
                    }
                },
                .reliable_sequenced => {
                    if (self.seen.exists(s)) return; // duplicate (reliable dedup)
                    self.seen.insert(s, {});
                    if (!self.has_latest or seq.greaterThan(Seq, s, self.latest)) {
                        self.latest = s;
                        self.has_latest = true;
                        out.push(value);
                    }
                },
            }
        }
    };
}

const testing = std.testing;

fn Collector(comptime N: usize) type {
    return struct {
        items: [N]u32 = undefined,
        n: usize = 0,
        pub fn push(self: *@This(), v: u32) void {
            self.items[self.n] = v;
            self.n += 1;
        }
        pub fn slice(self: *@This()) []const u32 {
            return self.items[0..self.n];
        }
    };
}

test "unreliable delivers everything as it arrives" {
    var r = Receiver(.unreliable, u32, 64, u16){};
    var c = Collector(8){};
    r.accept(3, 30, &c);
    r.accept(1, 10, &c);
    r.accept(1, 10, &c); // dups pass through (unreliable)
    try testing.expectEqualSlices(u32, &.{ 30, 10, 10 }, c.slice());
}

test "unreliable_sequenced drops older + duplicate-of-latest" {
    var r = Receiver(.unreliable_sequenced, u32, 64, u16){};
    var c = Collector(8){};
    r.accept(1, 10, &c);
    r.accept(3, 30, &c);
    r.accept(2, 20, &c); // older than 3 → dropped
    r.accept(3, 30, &c); // not newer → dropped
    try testing.expectEqualSlices(u32, &.{ 10, 30 }, c.slice());
}

test "reliable_unordered dedups, keeps arrival order" {
    var r = Receiver(.reliable_unordered, u32, 64, u16){};
    var c = Collector(8){};
    r.accept(1, 10, &c);
    r.accept(2, 20, &c);
    r.accept(1, 10, &c); // dup
    r.accept(3, 30, &c);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, c.slice());
}

test "reliable_ordered reorders to in-order, exactly once" {
    var r = Receiver(.reliable_ordered, u32, 64, u16){};
    var c = Collector(8){};
    r.accept(2, 20, &c); // held
    r.accept(0, 0, &c); // releases 0
    r.accept(2, 20, &c); // dup
    r.accept(1, 10, &c); // releases 1, then 2
    try testing.expectEqualSlices(u32, &.{ 0, 10, 20 }, c.slice());
}

test "reliable_sequenced delivers only the newest, dedups retransmits" {
    var r = Receiver(.reliable_sequenced, u32, 64, u16){};
    var c = Collector(8){};
    r.accept(1, 10, &c);
    r.accept(3, 30, &c);
    r.accept(2, 20, &c); // older → suppressed
    r.accept(3, 30, &c); // dup → suppressed
    try testing.expectEqualSlices(u32, &.{ 10, 30 }, c.slice());
}

test "unreliable receiver compiles out the sequence buffer (zero state)" {
    try testing.expectEqual(@as(usize, 0), @sizeOf(Receiver(.unreliable, u32, 64, u16)));
    try testing.expect(@sizeOf(Receiver(.reliable_ordered, u32, 64, u16)) > 0);
}
