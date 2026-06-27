//! Prespawn reconciliation. The client predict-spawns an entity (a projectile)
//! before the server's version arrives and tags it with a **deterministic hash**
//! `hash(spawn_tick ++ sorted component ids ++ salt)`. The server computes the same
//! hash; when its entity arrives, a match **unifies** the predicted and confirmed
//! entities instead of creating a duplicate. On rollback, prespawns whose spawn tick
//! is *after* the rollback point are despawned so the replay re-creates them cleanly.
//! magnet owns the registry → **stable small comptime component ids** (no TypeId-sort
//! fragility).

const std = @import("std");

/// Deterministic prespawn hash. `comp_ids` need not be pre-sorted - a local copy is
/// sorted so client and server agree regardless of iteration order.
pub fn prespawnHash(spawn_tick: u32, comp_ids: []const u8, salt: u64) u64 {
    var ids: [64]u8 = undefined;
    const n = @min(comp_ids.len, ids.len);
    @memcpy(ids[0..n], comp_ids[0..n]);
    std.mem.sort(u8, ids[0..n], {}, std.sort.asc(u8));

    var h: u64 = 0xcbf29ce484222325; // FNV-1a
    const prime: u64 = 0x100000001b3;
    inline for (0..4) |b| {
        h = (h ^ ((spawn_tick >> (b * 8)) & 0xff)) *% prime;
    }
    for (ids[0..n]) |id| h = (h ^ id) *% prime;
    inline for (0..8) |b| {
        h = (h ^ ((salt >> (b * 8)) & 0xff)) *% prime;
    }
    return h;
}

pub fn PrespawnTracker(comptime Entity: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct { used: bool = false, hash: u64 = 0, entity: Entity = undefined, spawn_tick: u32 = 0 };
        slots: [cap]Slot = [_]Slot{.{}} ** cap,

        /// Register a locally predict-spawned entity by its prespawn hash.
        pub fn add(self: *Self, hash: u64, entity: Entity, spawn_tick: u32) bool {
            for (&self.slots) |*s| {
                if (!s.used) {
                    s.* = .{ .used = true, .hash = hash, .entity = entity, .spawn_tick = spawn_tick };
                    return true;
                }
            }
            return false; // tracker full
        }

        /// A server entity with `hash` arrived - return the predicted local entity to
        /// unify with (and clear it), or null to spawn fresh.
        pub fn match(self: *Self, hash: u64) ?Entity {
            for (&self.slots) |*s| {
                if (s.used and s.hash == hash) {
                    s.used = false;
                    return s.entity;
                }
            }
            return null;
        }

        /// Prespawns made after `rollback_tick` must be despawned before replay; they
        /// are written to `out` and removed. Returns the count.
        pub fn purgeAfter(self: *Self, rollback_tick: u32, out: []Entity) usize {
            var n: usize = 0;
            for (&self.slots) |*s| {
                if (s.used and s.spawn_tick > rollback_tick) {
                    if (n < out.len) {
                        out[n] = s.entity;
                        n += 1;
                    }
                    s.used = false;
                }
            }
            return n;
        }

        pub fn liveCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |s| {
                if (s.used) n += 1;
            }
            return n;
        }
    };
}

const testing = std.testing;
const E = struct { idx: u32, gen: u32 };
const Tracker = PrespawnTracker(E, 16);

test "same inputs hash identically regardless of component-id order; salt separates" {
    try testing.expectEqual(prespawnHash(5, &.{ 0, 1, 2 }, 99), prespawnHash(5, &.{ 2, 0, 1 }, 99));
    try testing.expect(prespawnHash(5, &.{ 0, 1 }, 99) != prespawnHash(6, &.{ 0, 1 }, 99)); // tick
    try testing.expect(prespawnHash(5, &.{ 0, 1 }, 99) != prespawnHash(5, &.{ 0, 1 }, 100)); // salt
}

test "predicted projectile unifies with the server entity instead of duplicating" {
    var t = Tracker{};
    const h = prespawnHash(5, &.{ 0, 1 }, 0xABCD);
    const local = E{ .idx = 7, .gen = 1 };
    try testing.expect(t.add(h, local, 5));
    try testing.expectEqual(@as(usize, 1), t.liveCount());

    // server entity arrives with the same hash → unify (no duplicate spawn)
    const unified = t.match(h).?;
    try testing.expectEqual(@as(u32, 7), unified.idx);
    try testing.expectEqual(@as(usize, 0), t.liveCount()); // consumed
    try testing.expect(t.match(h) == null); // a second arrival would spawn fresh

    // an unrelated server entity does not match
    try testing.expect(t.match(prespawnHash(5, &.{0}, 1)) == null);
}

test "rollback despawns prespawns made after the rollback tick" {
    var t = Tracker{};
    _ = t.add(prespawnHash(3, &.{0}, 1), .{ .idx = 1, .gen = 0 }, 3);
    _ = t.add(prespawnHash(7, &.{0}, 1), .{ .idx = 2, .gen = 0 }, 7);
    _ = t.add(prespawnHash(9, &.{0}, 1), .{ .idx = 3, .gen = 0 }, 9);

    var out: [16]E = undefined;
    const n = t.purgeAfter(5, &out); // ticks 7 and 9 are after the rollback at 5
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), t.liveCount()); // the tick-3 prespawn survives
}
