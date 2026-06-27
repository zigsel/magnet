//! The built-in **world store** (owned-store default). Dense per-component
//! arrays + a presence bitset per component, generational entity ids, all
//! monomorphized from the registry - an `unreliable`-style à-la-carte store with no
//! allocation. Games that bring their own ECS adapt via the `View` interface
//! instead (duck-typed: `get`/`set`/`has`/`spawn`/`despawn`); the snapshot/interest
//! systems are written against that shape, so they work over either.

const std = @import("std");
const BitSet = @import("core").BitSet;

pub fn World(comptime R: type, comptime max: usize) type {
    const StoreTypes = blk: {
        var t: [R.count]type = undefined;
        for (0..R.count) |i| t[i] = [max]R.Type(i);
        break :blk t;
    };
    const Store = std.meta.Tuple(&StoreTypes);

    return struct {
        const Self = @This();
        pub const capacity = max;
        pub const Mask = R.Mask;
        pub const Entity = struct { idx: u32, gen: u32 };

        alive: BitSet(max) = .{},
        gens: [max]u32 = [_]u32{0} ** max,
        present: [R.count]BitSet(max) = [_]BitSet(max){.{}} ** R.count,
        store: Store = undefined,
        live: usize = 0,

        pub fn isAlive(self: *const Self, e: Entity) bool {
            return self.alive.isSet(e.idx) and self.gens[e.idx] == e.gen;
        }

        pub fn spawn(self: *Self) ?Entity {
            var i: usize = 0;
            while (i < max) : (i += 1) {
                if (!self.alive.isSet(i)) {
                    self.alive.set(i);
                    for (&self.present) |*p| p.clear(i);
                    self.live += 1;
                    return .{ .idx = @intCast(i), .gen = self.gens[i] };
                }
            }
            return null;
        }

        /// Spawn into a specific slot (used by the entity map to mirror a network id).
        pub fn spawnAt(self: *Self, idx: u32) ?Entity {
            if (idx >= max or self.alive.isSet(idx)) return null;
            self.alive.set(idx);
            for (&self.present) |*p| p.clear(idx);
            self.live += 1;
            return .{ .idx = idx, .gen = self.gens[idx] };
        }

        /// Ensure slot `idx` is alive and return its handle (revive if dead, else the
        /// existing one). Part of the **View** surface the replication layer drives a
        /// store through - see `snapshot.zig`. Lets a baseline (or an external ECS)
        /// reconstruct an entity addressed by its stable network id (= slot index).
        pub fn ensureSlot(self: *Self, idx: u32) Entity {
            if (self.alive.isSet(idx)) return .{ .idx = idx, .gen = self.gens[idx] };
            return self.spawnAt(idx).?;
        }

        pub fn despawn(self: *Self, e: Entity) void {
            if (!self.isAlive(e)) return;
            self.alive.clear(e.idx);
            for (&self.present) |*p| p.clear(e.idx);
            self.gens[e.idx] +%= 1;
            self.live -= 1;
        }

        pub fn set(self: *Self, e: Entity, comptime T: type, value: T) void {
            if (!self.isAlive(e)) return;
            const id = comptime R.idOf(T);
            self.store[id][e.idx] = value;
            self.present[id].set(e.idx);
        }
        pub fn get(self: *Self, e: Entity, comptime T: type) ?*T {
            if (!self.isAlive(e)) return null;
            const id = comptime R.idOf(T);
            if (!self.present[id].isSet(e.idx)) return null;
            return &self.store[id][e.idx];
        }
        pub fn has(self: *const Self, e: Entity, comptime T: type) bool {
            const id = comptime R.idOf(T);
            return self.isAlive(e) and self.present[id].isSet(e.idx);
        }
        pub fn remove(self: *Self, e: Entity, comptime T: type) void {
            if (!self.isAlive(e)) return;
            const id = comptime R.idOf(T);
            self.present[id].clear(e.idx);
        }

        /// The set of components present on `e`, as a registry mask.
        pub fn maskOf(self: *const Self, e: Entity) Mask {
            var m: Mask = 0;
            inline for (0..R.count) |id| {
                if (self.present[id].isSet(e.idx)) m |= (@as(Mask, 1) << id);
            }
            return m;
        }
    };
}

const testing = std.testing;
const registry = @import("registry.zig").registry;

const Pos = struct { x: i16, y: i16 };
const Vel = struct { dx: i8, dy: i8 };
const TestReg = registry(.{ .components = .{ Pos, Vel } });
const TestWorld = World(TestReg, 64);

test "spawn/set/get/has/remove and generational reuse" {
    var w: TestWorld = .{};
    const e = w.spawn().?;
    try testing.expect(w.isAlive(e));
    try testing.expect(!w.has(e, Pos));
    w.set(e, Pos, .{ .x = 3, .y = 4 });
    w.set(e, Vel, .{ .dx = 1, .dy = -1 });
    try testing.expect(w.has(e, Pos) and w.has(e, Vel));
    try testing.expectEqual(@as(i16, 3), w.get(e, Pos).?.x);
    try testing.expectEqual(@as(TestWorld.Mask, 0b11), w.maskOf(e));
    w.remove(e, Vel);
    try testing.expect(!w.has(e, Vel));

    w.despawn(e);
    try testing.expect(!w.isAlive(e)); // stale handle invalid after despawn
    const e2 = w.spawn().?;
    try testing.expectEqual(e.idx, e2.idx); // slot reused
    try testing.expect(e2.gen != e.gen); // but generation advanced
    try testing.expect(!w.isAlive(e)); // old handle still rejected
    try testing.expect(!w.has(e2, Pos)); // fresh slot has no stale components
}

test "exhaustion returns null" {
    var w = World(TestReg, 2){};
    _ = w.spawn().?;
    _ = w.spawn().?;
    try testing.expect(w.spawn() == null);
}
