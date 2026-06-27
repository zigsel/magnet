//! Network id ↔ local entity mapping. The server replicates entities by a stable
//! **network id** (its own slot index); each receiver keeps its own local entities
//! and maps them. Zero-alloc: a fixed table keyed by network id (sentinel = unmapped).

const std = @import("std");

/// A network-stable reference to another entity, for use **inside** replicated
/// components (e.g. `Target { who: EntityRef }`). It carries the referenced entity's
/// **network id** (its server slot index) rather than a raw local `Entity`, so it
/// survives the trip between worlds: the receiver resolves it to *its* local entity via
/// `EntityMap.resolve`. Carrying the net id (not the local handle) is robust to
/// out-of-order arrival - an unresolved ref is simply null until its target replicates,
/// with no deferred-mapping bookkeeping. A plain `u32` struct, so the derived serializer
/// encodes it as one field with no custom serde.
pub const EntityRef = struct {
    net_id: u32 = none_id,
    pub const none_id: u32 = std.math.maxInt(u32);
    pub const none: EntityRef = .{ .net_id = none_id };

    /// Build a ref to a local entity (its `idx` is its network id on the authority).
    pub fn of(e: anytype) EntityRef {
        return .{ .net_id = e.idx };
    }
    pub fn isNone(self: EntityRef) bool {
        return self.net_id == none_id;
    }
};

pub fn EntityMap(comptime Entity: type, comptime max: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct { used: bool = false, e: Entity = undefined };
        slots: [max]Slot = [_]Slot{.{}} ** max,

        pub fn get(self: *const Self, net_id: u32) ?Entity {
            if (net_id >= max) return null;
            const s = self.slots[net_id];
            return if (s.used) s.e else null;
        }
        pub fn put(self: *Self, net_id: u32, e: Entity) void {
            if (net_id >= max) return;
            self.slots[net_id] = .{ .used = true, .e = e };
        }
        pub fn remove(self: *Self, net_id: u32) void {
            if (net_id < max) self.slots[net_id].used = false;
        }
        pub fn mapped(self: *const Self, net_id: u32) bool {
            return net_id < max and self.slots[net_id].used;
        }
        /// Resolve an `EntityRef` (carried inside a replicated component) to this
        /// world's local entity, or null if it is `none` or its target hasn't replicated.
        pub fn resolve(self: *const Self, ref: EntityRef) ?Entity {
            if (ref.isNone()) return null;
            return self.get(ref.net_id);
        }
    };
}

const testing = std.testing;
const E = struct { idx: u32, gen: u32 };

test "map put/get/remove" {
    var m = EntityMap(E, 16){};
    try testing.expect(m.get(3) == null);
    m.put(3, .{ .idx = 7, .gen = 1 });
    try testing.expectEqual(@as(u32, 7), m.get(3).?.idx);
    try testing.expect(m.mapped(3));
    m.remove(3);
    try testing.expect(!m.mapped(3));
    try testing.expect(m.get(99) == null); // out of range
}

test "EntityRef resolves cross-world to the local entity (null until the target maps)" {
    var m = EntityMap(E, 16){};
    // server entity at net id 5 → client local entity {idx=2, gen=4}
    const ref = EntityRef.of(E{ .idx = 5, .gen = 0 }); // ref carries the net id (5)
    try testing.expectEqual(@as(u32, 5), ref.net_id);
    try testing.expect(m.resolve(ref) == null); // target not replicated yet → null (no deferral)
    m.put(5, .{ .idx = 2, .gen = 4 });
    try testing.expectEqual(@as(u32, 2), m.resolve(ref).?.idx); // now resolves to the local entity
    try testing.expect(m.resolve(EntityRef.none) == null); // a null ref stays null
}
