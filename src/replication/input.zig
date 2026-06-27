//! Input handling. A per-tick `InputBuffer` stores `Absent | SameAsPrecedent |
//! Input(v)`; `SameAsPrecedent` resolves to the nearest preceding explicit input at
//! read time (compresses idle ticks and silently corrects late out-of-order inserts).
//! Each input packet carries the **last N ticks redundantly** on a sequenced-
//! unreliable channel, so input survives loss *without* retransmit latency - a newer
//! packet re-supplies the dropped ticks. **Adaptive input delay** covers latency
//! with buffered delay up to a cap, then prediction beyond.

const std = @import("std");
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;

pub const Slot = enum(u2) { absent = 0, same = 1, value = 2 };

pub fn InputBuffer(comptime Input: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Cell = struct { tick: u32 = 0, slot: Slot = .absent, val: Input = undefined };

        cells: [cap]Cell = [_]Cell{.{}} ** cap,
        newest: u32 = 0,
        started: bool = false,

        fn cell(self: *Self, tick: u32) *Cell {
            return &self.cells[tick % cap];
        }

        pub fn set(self: *Self, tick: u32, val: Input) void {
            self.cells[tick % cap] = .{ .tick = tick, .slot = .value, .val = val };
            if (!self.started or tick > self.newest) {
                self.newest = tick;
                self.started = true;
            }
        }
        pub fn setSame(self: *Self, tick: u32) void {
            self.cells[tick % cap] = .{ .tick = tick, .slot = .same };
            if (!self.started or tick > self.newest) {
                self.newest = tick;
                self.started = true;
            }
        }

        /// Resolve `tick` to a concrete input: a `value` directly, a `same` to the
        /// nearest preceding explicit value, `absent`/out-of-window → null.
        pub fn get(self: *Self, tick: u32) ?Input {
            var t = tick;
            var steps: usize = 0;
            while (steps < cap) : (steps += 1) {
                const c = self.cell(t);
                if (c.tick != t) return null; // fell out of the window
                switch (c.slot) {
                    .value => return c.val,
                    .same => {
                        if (t == 0) return null;
                        t -= 1;
                    },
                    .absent => return null,
                }
            }
            return null;
        }

        pub fn newestTick(self: *const Self) u32 {
            return self.newest;
        }
        pub fn shift(self: *Self, delta: i64) void {
            // ticks index the ring (tick % cap), so a shift must REBUCKET, not relabel.
            const old = self.cells;
            self.cells = [_]Cell{.{}} ** cap;
            for (old) |c| {
                if (c.slot != .absent) {
                    const nt: u32 = @intCast(@as(i64, c.tick) + delta);
                    self.cells[nt % cap] = .{ .tick = nt, .slot = c.slot, .val = c.val };
                }
            }
            self.newest = @intCast(@as(i64, self.newest) + delta);
        }

        // ---- redundant wire encoding (sequenced-unreliable channel) ----

        /// Write the last `n` ticks (ending at `newest`) as `[base:u32][n:u8] vals`.
        pub fn writeRedundant(self: *Self, w: *bitpack.Writer, n: u32) void {
            const count = @min(n, self.newest + 1);
            const base = self.newest - (count - 1);
            w.writeBits64(@as(u64, base), 32);
            w.writeBits(count, 8);
            var t = base;
            while (t <= self.newest) : (t += 1) {
                const v = self.get(t) orelse std.mem.zeroes(Input);
                serde.write(w, v);
            }
        }

        /// Apply a redundant input packet; returns how many ticks were *newly*
        /// supplied or changed (a nonzero count is the input-rollback trigger).
        pub fn readRedundant(self: *Self, r: *bitpack.Reader) usize {
            const base: u32 = @intCast(r.readBits64(32));
            const count = r.readBits(8);
            var fresh: usize = 0;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const t = base + i;
                const v = serde.read(Input, r) orelse return fresh;
                const existing = self.get(t);
                if (existing == null or !std.meta.eql(existing.?, v)) {
                    self.set(t, v);
                    fresh += 1;
                }
            }
            return fresh;
        }
    };
}

/// Adaptive input delay (ticks): cover `effective_rtt = rtt/2 + jitter` with buffered
/// delay, clamped to `[0, max_delay]`. Latency beyond the cap is covered by prediction.
pub fn inputDelayTicks(rtt_ms: i64, jitter_ms: i64, tick_ms: i64, max_delay: u32) u32 {
    const effective = @max(@divTrunc(rtt_ms, 2) + jitter_ms, 0);
    const ticks = @divTrunc(effective, @max(tick_ms, 1));
    return @intCast(@min(ticks, @as(i64, max_delay)));
}

const testing = std.testing;

const Cmd = struct { dx: i8, dy: i8, fire: bool };
const TestInput = InputBuffer(Cmd, 64);

test "SameAsPrecedent resolves to the nearest preceding explicit input" {
    var ib = TestInput{};
    ib.set(0, .{ .dx = 1, .dy = 0, .fire = false });
    ib.setSame(1);
    ib.setSame(2);
    ib.set(3, .{ .dx = 0, .dy = -1, .fire = true });
    try testing.expectEqual(@as(i8, 1), ib.get(0).?.dx);
    try testing.expectEqual(@as(i8, 1), ib.get(2).?.dx); // resolves back to tick 0
    try testing.expect(ib.get(3).?.fire);
    try testing.expect(ib.get(50) == null); // never set
}

test "redundant sends let input survive loss without retransmit" {
    var sender = TestInput{};
    var i: u32 = 0;
    while (i <= 10) : (i += 1) sender.set(i, .{ .dx = @intCast(i), .dy = 0, .fire = false });

    var recv = TestInput{};
    var buf: [256]u8 = undefined;

    // the packet carrying ticks ~3..6 is "lost"; a later packet re-supplies them.
    var w = bitpack.Writer.init(&buf);
    sender.writeRedundant(&w, 8); // covers ticks 3..10 (last 8)
    var r = bitpack.Reader.init(w.finish());
    const fresh = recv.readRedundant(&r);
    try testing.expect(fresh >= 8); // all 8 ticks newly supplied despite the earlier drop
    try testing.expectEqual(@as(i8, 5), recv.get(5).?.dx);
    try testing.expectEqual(@as(i8, 10), recv.get(10).?.dx);

    // re-applying the same packet supplies nothing new (idempotent)
    var r2 = bitpack.Reader.init(w.finish());
    try testing.expectEqual(@as(usize, 0), recv.readRedundant(&r2));
}

test "adaptive input delay scales with rtt+jitter, clamped" {
    try testing.expectEqual(@as(u32, 0), inputDelayTicks(0, 0, 16, 8));
    // rtt 100 → 50ms one-way + 16 jitter = 66ms / 16ms ≈ 4 ticks
    try testing.expectEqual(@as(u32, 4), inputDelayTicks(100, 16, 16, 8));
    try testing.expectEqual(@as(u32, 8), inputDelayTicks(1000, 100, 16, 8)); // clamped to cap
}
