//! Pluggable rollback-history backends for the replication engine. The client's
//! `reconcile` records the predicted world each tick and compares the stored state
//! at the authoritative tick against the server's - over the **predicted set only**
//! (per-entity roles). *How* that per-tick state is stored is a comptime
//! choice, exactly like the congestion controller (`Config.congestion = type`):
//!
//!   .rollback = magnet.replication.Dense  // default: full copy; simplest
//!   .rollback = magnet.replication.Scoped      // copy only predicted entities (CPU ∝ predicted)
//!   .rollback = magnet.replication.Sparse      // per-component change history (CPU/mem ∝ changes)
//!   .rollback = MyBackend                       // or supply your own (record/agree)
//!
//! A backend implements two methods, both scoped by the predicted `mask`:
//!   record(tick, world, mask)        - store the predicted entities' state at `tick`
//!   agree(tick, auth, mask) bool     - does the stored state at `tick` match `auth`?
//! plus an `init(self)` (real for Sparse; a no-op for the slot backends).

const std = @import("std");
const BitSet = @import("core").BitSet;
const History = @import("history.zig").History;

/// Whole-world agreement over the **predicted set** (the completed-tick invariant,
/// scoped to roles): every predicted entity must match on liveness and on every
/// component - including spawn/despawn and component add/remove within the set.
pub fn agreePredicted(comptime GW: type, a: *const GW, b: *const GW, mask: *const BitSet(GW.capacity)) bool {
    const Reg = GW.Registry;
    var i: u32 = 0;
    while (i < GW.capacity) : (i += 1) {
        if (!mask.isSet(i)) continue;
        const aa = a.inner.alive.isSet(i);
        const ba = b.inner.alive.isSet(i);
        if (aa != ba) return false; // spawn/despawn divergence
        if (!aa) continue;
        const ea = GW.Entity{ .idx = i, .gen = a.inner.gens[i] };
        const eb = GW.Entity{ .idx = i, .gen = b.inner.gens[i] };
        inline for (0..Reg.count) |id| {
            const C = Reg.Type(id);
            const va = @constCast(a).inner.get(ea, C);
            const vb = @constCast(b).inner.get(eb, C);
            if ((va == null) != (vb == null)) return false; // component add/remove
            if (va != null and !Reg.eql(id, va.?.*, vb.?.*)) return false;
        }
    }
    return true;
}

/// Backend 1 - **Dense**: a full struct copy of the world per tick. Fastest to
/// record (one assignment), most memory (a world per rollback slot). Best for the
/// predicted-avatar scale where the world is small.
pub fn Dense(comptime GW: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        slots: [cap]GW = undefined,
        pub fn init(self: *Self) void {
            _ = self;
        }
        pub fn record(self: *Self, tick: u32, world: *const GW, mask: *const BitSet(GW.capacity)) void {
            _ = mask;
            self.slots[tick % cap] = world.*;
        }
        pub fn agree(self: *Self, tick: u32, auth: *const GW, mask: *const BitSet(GW.capacity)) bool {
            return agreePredicted(GW, &self.slots[tick % cap], auth, mask);
        }
    };
}

/// Backend 2 - **Scoped**: copy only the **predicted** entities into a reset slot.
/// `agree` reads only predicted entities, so the rest of the slot is left empty.
/// CPU ∝ |predicted set| (cheap when you predict a handful of entities in a large
/// world); memory is still a slot per tick (use Sparse to also shrink memory).
pub fn Scoped(comptime GW: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Reg = GW.Registry;
        slots: [cap]GW = undefined,
        pub fn init(self: *Self) void {
            _ = self;
        }
        pub fn record(self: *Self, tick: u32, world: *const GW, mask: *const BitSet(GW.capacity)) void {
            const slot = &self.slots[tick % cap];
            slot.* = .{}; // empty world; only predicted entities are populated below
            var i: u32 = 0;
            while (i < GW.capacity) : (i += 1) {
                if (!mask.isSet(i) or !world.inner.alive.isSet(i)) continue;
                slot.inner.alive.set(i);
                slot.inner.gens[i] = world.inner.gens[i];
                inline for (0..Reg.count) |id| {
                    if (world.inner.present[id].isSet(i)) {
                        slot.inner.present[id].set(i);
                        slot.inner.store[id][i] = world.inner.store[id][i];
                    }
                }
            }
        }
        pub fn agree(self: *Self, tick: u32, auth: *const GW, mask: *const BitSet(GW.capacity)) bool {
            return agreePredicted(GW, &self.slots[tick % cap], auth, mask);
        }
    };
}

/// Backend 3 - **Sparse**: per-component **change** history (the primitive).
/// Each (entity, component) keeps a sparse tick-history that stores only *changes*,
/// so idle entities/components cost nothing - CPU and memory ∝ changes, not world
/// size. Best for large, mostly-static worlds. Liveness is a per-entity history
/// (0 = dead, else gen+1). `get(tick)` resolves the latest value ≤ tick.
pub fn Sparse(comptime GW: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Reg = GW.Registry;
        const n = Reg.count;
        const max = GW.capacity;

        fn Cell(comptime C: type) type {
            return struct { present: bool, val: C };
        }
        const CompArrays = blk: {
            var t: [n]type = undefined;
            for (0..n) |id| t[id] = [max]History(Cell(Reg.Type(id)), cap);
            break :blk t;
        };

        gen: [max]History(u32, cap) = undefined,
        comps: std.meta.Tuple(&CompArrays) = undefined,

        pub fn init(self: *Self) void {
            for (&self.gen) |*g| g.* = .{};
            inline for (0..n) |id| {
                for (&self.comps[id]) |*h| h.* = .{};
            }
        }

        fn changedU32(h: *const History(u32, cap), v: u32) bool {
            return if (h.latest()) |e| e.val != v else true;
        }
        fn changedCell(comptime C: type, h: *const History(Cell(C), cap), c: Cell(C)) bool {
            if (h.latest()) |e| {
                if (e.val.present != c.present) return true;
                if (c.present and !std.meta.eql(e.val.val, c.val)) return true;
                return false;
            }
            return true;
        }

        pub fn record(self: *Self, tick: u32, world: *const GW, mask: *const BitSet(GW.capacity)) void {
            var i: u32 = 0;
            while (i < max) : (i += 1) {
                if (!mask.isSet(i)) continue;
                const alive = world.inner.alive.isSet(i);
                const gv: u32 = if (alive) world.inner.gens[i] + 1 else 0;
                if (changedU32(&self.gen[i], gv)) self.gen[i].record(tick, gv);
                if (!alive) continue;
                inline for (0..n) |id| {
                    const C = Reg.Type(id);
                    const present = world.inner.present[id].isSet(i);
                    const cell: Cell(C) = .{ .present = present, .val = if (present) world.inner.store[id][i] else undefined };
                    if (changedCell(C, &self.comps[id][i], cell)) self.comps[id][i].record(tick, cell);
                }
            }
        }

        pub fn agree(self: *Self, tick: u32, auth: *const GW, mask: *const BitSet(GW.capacity)) bool {
            var i: u32 = 0;
            while (i < max) : (i += 1) {
                if (!mask.isSet(i)) continue;
                const gv = self.gen[i].get(tick) orelse 0;
                const stored_alive = gv > 0;
                const auth_alive = auth.inner.alive.isSet(i);
                if (stored_alive != auth_alive) return false;
                if (!auth_alive) continue;
                const eb = GW.Entity{ .idx = i, .gen = auth.inner.gens[i] };
                inline for (0..n) |id| {
                    const C = Reg.Type(id);
                    const cell = self.comps[id][i].get(tick);
                    const stored_present = if (cell) |c| c.present else false;
                    const vb = @constCast(auth).inner.get(eb, C);
                    if (stored_present != (vb != null)) return false;
                    if (stored_present and !Reg.eql(id, cell.?.val, vb.?.*)) return false;
                }
            }
            return true;
        }
    };
}
