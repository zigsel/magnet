//! Snapshot delta. Per client, the server diffs each visible entity's
//! components against that client's **last-acked baseline** and serializes only what
//! changed, highest-priority first, until a per-tick **byte budget** is exhausted.
//! The receiver applies the delta to its own world via the entity map (spawning a
//! local entity on first sight). Bit-packed and self-delimiting (a 1-bit
//! continue/stop flag per record), so no count prefix is needed.
//!
//! Wire (bitpacked): `( 1 [net_id:32][mask:count] {changed component values} )* 0`
//!
//! `WorldT` is a duck-typed **View** - `Snapshot` reaches into no store internals, so
//! the built-in `World` *or any external ECS* (flecs, your own) plugs in by exposing:
//!   pub const Entity = struct { idx: u32, gen: u32 };  // net id = slot index
//!   pub const capacity = N;
//!   isAlive(e) bool · get(e, comptime C) ?*C · set(e, comptime C, v) · spawn() ?Entity
//!   ensureSlot(idx) Entity   // revive-or-return slot `idx` (baseline reconstruct)
//! The receiver-side `apply` also takes a `map` (net id ↔ local entity). This is the
//! View seam: replication runs over your ECS with no mirror copy (rollback still
//! uses the dense `World` - it needs cheap snapshot/restore the way `apply` does not).

const std = @import("std");
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;

/// Comptime contract check for a **View** (the ECS seam Snapshot drives - the built-in
/// `World` or your own store): it must expose `Entity`, `capacity`, and
/// `isAlive`/`get`/`set`/`spawn`/`ensureSlot`. A clear error here beats a deep failure
/// inside the snapshot walk. See `World` (or the `StubView` in this file's tests) to copy.
pub fn assertView(comptime W: type) void {
    if (!@hasDecl(W, "Entity")) @compileError("View '" ++ @typeName(W) ++ "' must declare `pub const Entity`");
    if (!@hasDecl(W, "capacity")) @compileError("View '" ++ @typeName(W) ++ "' must declare `pub const capacity`");
    inline for (.{ "isAlive", "get", "set", "spawn", "ensureSlot" }) |m| {
        if (!@hasDecl(W, m)) @compileError("View '" ++ @typeName(W) ++ "' is missing the `" ++ m ++ "` method");
    }
}

pub fn Snapshot(comptime R: type, comptime WorldT: type) type {
    comptime assertView(WorldT);
    const Entity = WorldT.Entity;
    const Mask = R.Mask;
    const cbits: u7 = R.count;

    return struct {
        /// A component opts into **field-level** delta by declaring `pub const
        /// net_diffable = true` - only its changed fields go on the wire (preceded by a
        /// field bitmask), instead of the whole component.
        fn diffable(comptime T: type) bool {
            return @typeInfo(T) == .@"struct" and @hasDecl(T, "net_diffable") and @typeInfo(T).@"struct".fields.len <= 32;
        }
        fn nfields(comptime T: type) usize {
            return @typeInfo(T).@"struct".fields.len;
        }

        /// Components of `e` that differ from the baseline slot (changed or new).
        pub fn changedMask(world: *WorldT, baseline: *WorldT, e: Entity, be: Entity) Mask {
            var m: Mask = 0;
            inline for (0..R.count) |id| {
                const T = R.Type(id);
                if (world.get(e, T)) |wv| {
                    const changed = if (baseline.get(be, T)) |bv| !R.eql(id, wv.*, bv.*) else true;
                    if (changed) m |= (@as(Mask, 1) << id);
                }
            }
            return m;
        }

        fn recordBits(world: *WorldT, e: Entity, mask: Mask) usize {
            var bits: usize = 1 + 32 + R.count;
            inline for (0..R.count) |id| {
                if (mask & (@as(Mask, 1) << id) != 0) {
                    const T = R.Type(id);
                    // upper bound: full component (+ the field mask when diffable)
                    bits += serde.measureBits(world.get(e, T).?.*);
                    if (diffable(T)) bits += nfields(T);
                }
            }
            return bits;
        }

        /// Write a delta of `entities` (interest-filtered, priority-ordered) into
        /// `buf`, updating `baseline` for every record sent. Stops when the byte
        /// budget can't fit the next record. Returns the datagram length.
        /// Delta vs `baseline`, **committing** `baseline` to what was sent. Correct
        /// only over a reliable channel (a dropped datagram would desync the baseline).
        pub fn write(world: *WorldT, baseline: *WorldT, entities: []const Entity, budget_bytes: usize, buf: []u8) usize {
            return writeImpl(true, world, baseline, entities, budget_bytes, buf);
        }

        /// Delta vs `baseline` **without** advancing it - the ack-gated path for an
        /// *unreliable* snapshot channel. The caller sends `buf`, and only on a peer
        /// ack calls `commit(baseline, buf)` to roll the baseline forward; a dropped
        /// (never-acked) snapshot leaves the baseline put, so the next delta re-sends
        /// the still-unconfirmed changes. This is the "delta vs last-ACKED
        /// baseline" invariant the committing `write` cannot honor over loss.
        pub fn writePending(world: *WorldT, baseline: *WorldT, entities: []const Entity, budget_bytes: usize, buf: []u8) usize {
            return writeImpl(false, world, baseline, entities, budget_bytes, buf);
        }

        fn writeImpl(comptime do_commit: bool, world: *WorldT, baseline: *WorldT, entities: []const Entity, budget_bytes: usize, buf: []u8) usize {
            var w = bitpack.Writer.init(buf);
            const budget_bits = budget_bytes * 8;
            for (entities) |e| {
                if (!world.isAlive(e)) continue;
                const be = baseline.ensureSlot(e.idx);
                const mask = changedMask(world, baseline, e, be);
                if (mask == 0) continue;
                if (w.bitCount() + recordBits(world, e, mask) + 1 > budget_bits) break; // +1 terminator
                w.writeBits(1, 1);
                w.writeBits64(@as(u64, e.idx), 32);
                w.writeBits64(@as(u64, mask), cbits);
                inline for (0..R.count) |id| {
                    if (mask & (@as(Mask, 1) << id) != 0) {
                        const T = R.Type(id);
                        const v = world.get(e, T).?.*;
                        if (diffable(T)) {
                            // field-level delta: a per-field bitmask + only changed fields
                            const fields = @typeInfo(T).@"struct".fields;
                            const bv = baseline.get(be, T); // ?*T
                            var fmask: u32 = 0;
                            inline for (fields, 0..) |f, fi| {
                                const ch = if (bv) |b| !std.meta.eql(@field(v, f.name), @field(b.*, f.name)) else true;
                                if (ch) fmask |= (@as(u32, 1) << fi);
                            }
                            w.writeBits(fmask, @intCast(fields.len));
                            inline for (fields, 0..) |f, fi| {
                                if (fmask & (@as(u32, 1) << fi) != 0) serde.write(&w, @field(v, f.name));
                            }
                        } else {
                            serde.write(&w, v);
                        }
                        if (do_commit) baseline.set(be, T, v); // baseline now matches what we sent
                    }
                }
            }
            w.writeBits(0, 1); // terminator: a 0 "continue" bit
            return w.finish().len;
        }

        /// Apply a delta into `world`, mapping each network id to a local entity
        /// (spawning on first sight) via `map`.
        pub fn apply(world: *WorldT, map: anytype, bytes: []const u8) void {
            var r = bitpack.Reader.init(bytes);
            while (true) {
                const more = r.readBits(1);
                if (r.failed or more == 0) return;
                const net_id: u32 = @intCast(r.readBits64(32));
                const mask: Mask = @intCast(r.readBits64(cbits));
                if (r.failed) return;
                var e: Entity = undefined;
                if (map.get(net_id)) |x| {
                    e = x;
                } else {
                    e = world.spawn() orelse return;
                    map.put(net_id, e);
                }
                inline for (0..R.count) |id| {
                    if (mask & (@as(Mask, 1) << id) != 0) {
                        const T = R.Type(id);
                        var v: T = undefined;
                        if (diffable(T)) {
                            // start from the existing value and overwrite only changed fields
                            const fields = @typeInfo(T).@"struct".fields;
                            v = if (world.get(e, T)) |cur| cur.* else std.mem.zeroes(T);
                            const fmask = r.readBits(@intCast(fields.len));
                            inline for (fields, 0..) |f, fi| {
                                if (fmask & (@as(u32, 1) << fi) != 0) {
                                    @field(v, f.name) = serde.read(f.type, &r) orelse return;
                                }
                            }
                        } else {
                            v = serde.read(T, &r) orelse return;
                        }
                        world.set(e, T, v);
                    }
                }
            }
        }

        /// Roll `baseline` forward by a snapshot the peer acknowledged (the bytes a
        /// prior `writePending` produced). Net ids address `baseline` directly (its
        /// slot index == net id), so no entity map is needed. Mirrors `apply`'s walk.
        pub fn commit(baseline: *WorldT, bytes: []const u8) void {
            var r = bitpack.Reader.init(bytes);
            while (true) {
                const more = r.readBits(1);
                if (r.failed or more == 0) return;
                const net_id: u32 = @intCast(r.readBits64(32));
                const mask: Mask = @intCast(r.readBits64(cbits));
                if (r.failed or net_id >= WorldT.capacity) return;
                const e = baseline.ensureSlot(net_id);
                inline for (0..R.count) |id| {
                    if (mask & (@as(Mask, 1) << id) != 0) {
                        const T = R.Type(id);
                        var v: T = undefined;
                        if (diffable(T)) {
                            const fields = @typeInfo(T).@"struct".fields;
                            v = if (baseline.get(e, T)) |cur| cur.* else std.mem.zeroes(T);
                            const fmask = r.readBits(@intCast(fields.len));
                            inline for (fields, 0..) |f, fi| {
                                if (fmask & (@as(u32, 1) << fi) != 0) {
                                    @field(v, f.name) = serde.read(f.type, &r) orelse return;
                                }
                            }
                        } else {
                            v = serde.read(T, &r) orelse return;
                        }
                        baseline.set(e, T, v);
                    }
                }
            }
        }

        /// Apply a client's authoritative update into `world` **by net id**, but only for
        /// records `ctx.allow(net_id)` accepts (the server gates a client to the entities
        /// it owns - an update for an unowned entity is read past and dropped, i.e. an
        /// authority/anti-cheat check). Net id == slot, so no entity map is needed.
        pub fn applyOwned(world: *WorldT, bytes: []const u8, ctx: anytype) void {
            var r = bitpack.Reader.init(bytes);
            while (true) {
                const more = r.readBits(1);
                if (r.failed or more == 0) return;
                const net_id: u32 = @intCast(r.readBits64(32));
                const mask: Mask = @intCast(r.readBits64(cbits));
                if (r.failed or net_id >= WorldT.capacity) return;
                const allowed = ctx.allow(net_id);
                const e = if (allowed) world.ensureSlot(net_id) else undefined;
                inline for (0..R.count) |id| {
                    if (mask & (@as(Mask, 1) << id) != 0) {
                        const T = R.Type(id);
                        var v: T = undefined;
                        if (diffable(T)) {
                            const fields = @typeInfo(T).@"struct".fields;
                            v = if (allowed) (if (world.get(e, T)) |cur| cur.* else std.mem.zeroes(T)) else std.mem.zeroes(T);
                            const fmask = r.readBits(@intCast(fields.len));
                            inline for (fields, 0..) |f, fi| {
                                if (fmask & (@as(u32, 1) << fi) != 0) {
                                    @field(v, f.name) = serde.read(f.type, &r) orelse return;
                                }
                            }
                        } else {
                            v = serde.read(T, &r) orelse return;
                        }
                        if (allowed) world.set(e, T, v); // dropped for unowned entities
                    }
                }
            }
        }
    };
}

const testing = std.testing;
const registry = @import("registry.zig").registry;
const World = @import("world.zig").World;
const EntityMap = @import("entity_map.zig").EntityMap;
const EntityRef = @import("entity_map.zig").EntityRef;

// a component that REFERENCES another entity by EntityRef (net id), the cross-world case.
const Target = struct { who: EntityRef };
const RefReg = registry(.{ .components = .{ Pos, Target } });
const RefWorld = World(RefReg, 32);
const RefSnap = Snapshot(RefReg, RefWorld);
const RefMap = EntityMap(RefWorld.Entity, 32);

test "replicated component carrying an EntityRef resolves to the client's local entity" {
    var server: RefWorld = .{};
    var baseline: RefWorld = .{};
    var client: RefWorld = .{};
    var map = RefMap{};

    const a = server.spawn().?; // the referenced entity (net id == a.idx)
    server.set(a, Pos, .{ .x = 1, .y = 2 });
    const b = server.spawn().?; // b points at a
    server.set(b, Pos, .{ .x = 9, .y = 9 });
    server.set(b, Target, .{ .who = EntityRef.of(a) });

    var buf: [256]u8 = undefined;
    const n = RefSnap.write(&server, &baseline, &.{ a, b }, 256, &buf);
    RefSnap.apply(&client, &map, buf[0..n]);

    // b's Target.who carries a's NET id; resolving via the client's map yields the
    // client's local entity for a (different slot/gen than the server's, but correct).
    const cb = map.get(b.idx).?;
    const ref = client.get(cb, Target).?.who;
    const resolved = map.resolve(ref).?;
    try testing.expectEqual(map.get(a.idx).?.idx, resolved.idx); // → the client's local `a`
    try testing.expectEqual(@as(i16, 1), client.get(resolved, Pos).?.x); // and it's the right entity
}

const Pos = struct { x: i16, y: i16 };
const Vel = struct { dx: i8, dy: i8 };
const TestReg = registry(.{ .components = .{ Pos, Vel } });
const TestWorld = World(TestReg, 32);
const TestSnap = Snapshot(TestReg, TestWorld);
const TestMap = EntityMap(TestWorld.Entity, 32);

test "delta sends only changed components; receiver reconstructs the world" {
    var server: TestWorld = .{};
    var baseline: TestWorld = .{};
    var client: TestWorld = .{};
    var map = TestMap{};

    const a = server.spawn().?;
    server.set(a, Pos, .{ .x = 10, .y = 20 });
    server.set(a, Vel, .{ .dx = 1, .dy = 0 });
    const b = server.spawn().?;
    server.set(b, Pos, .{ .x = -5, .y = 5 });

    var buf: [256]u8 = undefined;
    const ents = [_]TestWorld.Entity{ a, b };
    const n1 = TestSnap.write(&server, &baseline, &ents, 256, &buf);
    TestSnap.apply(&client, &map, buf[0..n1]);

    // client mirrors the server for both entities
    const ca = map.get(a.idx).?;
    try testing.expectEqual(@as(i16, 10), client.get(ca, Pos).?.x);
    try testing.expectEqual(@as(i8, 1), client.get(ca, Vel).?.dx);
    const cb = map.get(b.idx).?;
    try testing.expectEqual(@as(i16, -5), client.get(cb, Pos).?.x);
    try testing.expect(!client.has(cb, Vel)); // b never had Vel

    // second snapshot with no changes → empty delta (just the terminator)
    const n2 = TestSnap.write(&server, &baseline, &ents, 256, &buf);
    try testing.expectEqual(@as(usize, 1), n2); // 1 byte holds only the stop bit

    // change one field → only that component re-sent
    server.get(a, Pos).?.x = 11;
    const n3 = TestSnap.write(&server, &baseline, &ents, 256, &buf);
    try testing.expect(n3 > 1 and n3 < n1); // smaller than the full snapshot
    TestSnap.apply(&client, &map, buf[0..n3]);
    try testing.expectEqual(@as(i16, 11), client.get(ca, Pos).?.x);
    try testing.expectEqual(@as(i8, 1), client.get(ca, Vel).?.dx); // unchanged, still correct
}

test "byte budget drops lower-priority entities" {
    var server: TestWorld = .{};
    var baseline: TestWorld = .{};
    var ents: [10]TestWorld.Entity = undefined;
    for (&ents) |*e| {
        e.* = server.spawn().?;
        server.set(e.*, Pos, .{ .x = 1, .y = 2 });
    }
    var buf: [256]u8 = undefined;
    // tiny budget fits only a couple of records
    const small = TestSnap.write(&server, &baseline, &ents, 12, &buf);
    try testing.expect(small <= 12);
    // a full-budget pass then sends the rest (baseline already has the first few)
    const rest = TestSnap.write(&server, &baseline, &ents, 256, &buf);
    try testing.expect(rest > 1); // there was leftover work
}

const Big = struct {
    a: i32,
    b: i32,
    c: i32,
    pub const net_diffable = true;
};
const DReg = registry(.{ .components = .{Big} });
const DW = World(DReg, 16);
const DSnap = Snapshot(DReg, DW);
const DMap = EntityMap(DW.Entity, 16);

test "diffable component sends only changed fields, applies correctly, shrinks the delta" {
    var server: DW = .{};
    var baseline: DW = .{};
    var client: DW = .{};
    var map = DMap{};
    const e = server.spawn().?;
    server.set(e, Big, .{ .a = 1, .b = 2, .c = 3 });

    var buf: [128]u8 = undefined;
    const n1 = DSnap.write(&server, &baseline, &.{e}, 128, &buf); // first send: all 3 fields
    DSnap.apply(&client, &map, buf[0..n1]);
    const ce = map.get(e.idx).?;
    try testing.expectEqual(@as(i32, 2), client.get(ce, Big).?.b);

    // change only field `b`
    server.get(e, Big).?.b = 99;
    const n2 = DSnap.write(&server, &baseline, &.{e}, 128, &buf);
    try testing.expect(n2 < n1); // only the changed field (+ masks) on the wire
    DSnap.apply(&client, &map, buf[0..n2]);
    const v = client.get(ce, Big).?;
    try testing.expectEqual(@as(i32, 1), v.a); // unchanged field preserved
    try testing.expectEqual(@as(i32, 99), v.b); // changed field applied
    try testing.expectEqual(@as(i32, 3), v.c); // unchanged field preserved
}

test "ack-gated baseline: a dropped pending snapshot does not desync (re-sends until committed)" {
    var server: TestWorld = .{};
    var baseline: TestWorld = .{};
    var client: TestWorld = .{};
    var map = TestMap{};

    const a = server.spawn().?;
    server.set(a, Pos, .{ .x = 7, .y = 8 });

    var buf: [128]u8 = undefined;
    // first pending snapshot - NOT acked (simulate the datagram dropping on the wire).
    const n1 = TestSnap.writePending(&server, &baseline, &.{a}, 128, &buf);
    try testing.expect(n1 > 1);
    // baseline did NOT advance, so the very next pending delta re-sends the same change
    // (over the committing `write` it would have gone empty → a permanent client desync).
    const n2 = TestSnap.writePending(&server, &baseline, &.{a}, 128, &buf);
    try testing.expectEqual(n1, n2);

    // now the client receives this one and acks it → commit rolls the baseline forward.
    TestSnap.apply(&client, &map, buf[0..n2]);
    TestSnap.commit(&baseline, buf[0..n2]);
    try testing.expectEqual(@as(i16, 7), client.get(map.get(a.idx).?, Pos).?.x);

    // unchanged + committed → the next delta is just the terminator.
    try testing.expectEqual(@as(usize, 1), TestSnap.writePending(&server, &baseline, &.{a}, 128, &buf));
}

// ---- the View seam: replicate into a store that is NOT magnet's `World` ----

/// A minimal external-ECS stand-in: its own plain arrays (no `World`, no `BitSet`,
/// no component tuple) - it shares *zero* layout with `World`, so driving `Snapshot`
/// over it proves the View surface, not the store internals, is all that's required.
/// A real flecs adapter is the same shape over the flecs C API.
const StubView = struct {
    const Self = @This();
    pub const Entity = struct { idx: u32, gen: u32 };
    pub const Registry = TestReg;
    pub const capacity = 32;

    alive: [32]bool = [_]bool{false} ** 32,
    gens: [32]u32 = [_]u32{0} ** 32,
    pos: [32]Pos = undefined,
    vel: [32]Vel = undefined,
    has_pos: [32]bool = [_]bool{false} ** 32,
    has_vel: [32]bool = [_]bool{false} ** 32,

    pub fn isAlive(self: *Self, e: Entity) bool {
        return e.idx < 32 and self.alive[e.idx] and self.gens[e.idx] == e.gen;
    }
    pub fn get(self: *Self, e: Entity, comptime C: type) ?*C {
        if (!self.isAlive(e)) return null;
        if (C == Pos) return if (self.has_pos[e.idx]) &self.pos[e.idx] else null;
        if (C == Vel) return if (self.has_vel[e.idx]) &self.vel[e.idx] else null;
        @compileError("StubView: unknown component " ++ @typeName(C));
    }
    pub fn set(self: *Self, e: Entity, comptime C: type, v: C) void {
        if (!self.isAlive(e)) return;
        if (C == Pos) {
            self.pos[e.idx] = v;
            self.has_pos[e.idx] = true;
        } else if (C == Vel) {
            self.vel[e.idx] = v;
            self.has_vel[e.idx] = true;
        } else @compileError("StubView: unknown component " ++ @typeName(C));
    }
    pub fn spawn(self: *Self) ?Entity {
        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            if (!self.alive[i]) {
                self.alive[i] = true;
                self.has_pos[i] = false;
                self.has_vel[i] = false;
                return .{ .idx = i, .gen = self.gens[i] };
            }
        }
        return null;
    }
    pub fn ensureSlot(self: *Self, idx: u32) Entity {
        if (!self.alive[idx]) {
            self.alive[idx] = true;
            self.has_pos[idx] = false;
            self.has_vel[idx] = false;
        }
        return .{ .idx = idx, .gen = self.gens[idx] };
    }
};

test "snapshot drives an external (non-World) ECS through the View surface" {
    var server: TestWorld = .{};
    var baseline: TestWorld = .{};
    const a = server.spawn().?;
    server.set(a, Pos, .{ .x = 10, .y = 20 });
    server.set(a, Vel, .{ .dx = 1, .dy = -1 });
    const b = server.spawn().?;
    server.set(b, Pos, .{ .x = -5, .y = 5 }); // no Vel

    var buf: [256]u8 = undefined;
    const ents = [_]TestWorld.Entity{ a, b };
    const n = TestSnap.write(&server, &baseline, &ents, 256, &buf);

    // apply the SAME delta into a foreign store via the View surface (no mirror copy)
    const StubSnap = Snapshot(TestReg, StubView);
    const StubMap = EntityMap(StubView.Entity, 32);
    var client = StubView{};
    var map = StubMap{};
    StubSnap.apply(&client, &map, buf[0..n]);

    const ca = map.get(a.idx).?;
    try testing.expectEqual(@as(i16, 10), client.get(ca, Pos).?.x);
    try testing.expectEqual(@as(i8, 1), client.get(ca, Vel).?.dx);
    const cb = map.get(b.idx).?;
    try testing.expectEqual(@as(i16, -5), client.get(cb, Pos).?.x);
    try testing.expect(client.get(cb, Vel) == null); // b never had Vel → not replicated
}
