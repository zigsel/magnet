//! The assembled **engine** - `engine(.{ .components, .Input, .step, … })`
//! bundles the registry + world + the prediction/rollback machinery so the user
//! writes **one** deterministic `step(world, dt)` and magnet runs it in all three
//! contexts, by construction consistent:
//!   • `Server.advance(dt)` - authoritative, once per tick over the whole world;
//!   • `Client.predict(input, dt)` - owned entities, local input, immediately;
//!   • `Client.reconcile(auth, tick)` - restore the authoritative world and **replay
//!     `step`** forward over the buffered local inputs (completed-tick whole-world
//!     rollback - one rollback point certifies the world).
//! The `World` is the surface: `spawn`/`despawn`/`get`/`set`/`has`/`query`/
//! `input`/`setInput`. `get` is transparent: predicted for owned entities, confirmed
//! for remotes (compose an `Interpolator` for smooth remotes). Sans-IO.

const std = @import("std");
const registry = @import("registry.zig").registry;
const World = @import("world.zig").World;
const BitSet = @import("core").BitSet;
const MismatchMask = @import("history.zig").MismatchMask;
const History = @import("history.zig").History;
const Interpolator = @import("interpolate.zig").Interpolator;
const store = @import("store.zig");

fn field(comptime spec: anytype, comptime name: []const u8, comptime default: anytype) @TypeOf(default) {
    return if (@hasField(@TypeOf(spec), name)) @field(spec, name) else default;
}

pub fn Engine(comptime spec: anytype) type {
    const Reg = registry(.{ .components = spec.components });
    const Input = field(spec, "Input", void);
    const max_entities = field(spec, "max_entities", @as(usize, 64));
    const max_rollback = field(spec, "max_rollback_ticks", @as(usize, 24));
    const max_clients = field(spec, "max_clients", @as(usize, 8));
    const tick_hz = field(spec, "tick_hz", @as(f32, 60));
    const step = spec.step; // fn(*World, dt: f32) void
    const Inner = World(Reg, max_entities);
    const Snap = @import("snapshot.zig").Snapshot(Reg, Inner);
    const dt: f32 = 1.0 / tick_hz;
    const interp_cap = field(spec, "interp_cap", @as(usize, 16));
    // Optional duck-typed tracer (`pub fn onRollback(self, ticks, entities) void`),
    // called when a reconcile actually rolls back. Defaults to a zero-sized no-op so
    // the engine needs no dependency on the `trace` module.
    const NullTracer = struct {
        pub fn onRollback(self: *@This(), ticks: u32, entities: u32) void {
            _ = self;
            _ = ticks;
            _ = entities;
        }
    };
    const Tracer = field(spec, "tracer", NullTracer);
    // Comptime-pluggable rollback-history backend (default: whole-world copy). Swap to
    // `store.Scoped` / `store.Sparse` - or supply your own - per game; see store.zig.
    const rollbackBackend = field(spec, "rollback", store.Dense);

    // Components opting into smooth remote rendering declare `pub fn lerp(a,b,t) Self`.
    // The client keeps a per-remote-entity interpolator per such component.
    const lerp_ids = comptime blk: {
        var ids: [Reg.count]usize = undefined;
        var n: usize = 0;
        for (0..Reg.count) |id| {
            if (@typeInfo(Reg.Type(id)) == .@"struct" and @hasDecl(Reg.Type(id), "lerp")) {
                ids[n] = id;
                n += 1;
            }
        }
        break :blk ids[0..n].*;
    };
    const InterpTypes = comptime blk: {
        var t: [lerp_ids.len]type = undefined;
        for (lerp_ids, 0..) |id, i| {
            const C = Reg.Type(id);
            t[i] = [max_entities]Interpolator(C, C.lerp, interp_cap);
        }
        break :blk t;
    };
    const InterpTuple = std.meta.Tuple(&InterpTypes);
    const lerpIndexOf = struct {
        fn f(comptime C: type) ?usize {
            inline for (lerp_ids, 0..) |id, i| {
                if (Reg.Type(id) == C) return i;
            }
            return null;
        }
    }.f;

    // The World: the registry store + per-entity inputs + ownership + tick.
    const GameWorld = struct {
        const Self = @This();
        pub const Entity = Inner.Entity;
        pub const Registry = Reg;

        pub const capacity = max_entities;

        inner: Inner = .{},
        inputs: [max_entities]?Input = [_]?Input{null} ** max_entities,
        owned: BitSet(max_entities) = .{}, // receives local input (⊆ predicted)
        // Per-entity sim **role**: predicted = simulated in the rollback loop;
        // interpolated = advanced by the InterpolationTimeline (rendered, not stepped);
        // neither = replicated (server-only, just stored). `simulate_all` is set by the
        // server, whose world IS the whole authority - so its `query` yields everything.
        predicted: BitSet(max_entities) = .{},
        interpolated: BitSet(max_entities) = .{},
        simulate_all: bool = false,
        tick: u32 = 0,
        // Per-entity authority owner (0 = server). On the server, entities it does NOT
        // own are stored but not simulated (the owning client drives them); on a client,
        // `owns()` marks the client-authoritative entities it simulates + uploads.
        authority: @import("authority.zig").Table(max_entities) = .{},
        local_owner: u16 = 0, // this world's owner id (server = 0; a client = its id+1)

        pub fn setAuthority(self: *Self, e: Entity, owner: u16) void {
            self.authority.set(e.idx, owner);
        }
        pub fn authorityOf(self: *const Self, e: Entity) u16 {
            return self.authority.get(e.idx);
        }
        /// Does *this* world hold authority over `idx`? (server owns what it's marked
        /// server-owned; a client owns what's assigned to its `local_owner`.)
        pub fn ownsSlot(self: *const Self, idx: u32) bool {
            return self.authority.get(idx) == self.local_owner;
        }

        pub const Role = enum { predicted, interpolated, replicated };
        pub fn setRole(self: *Self, e: Entity, role: Role) void {
            self.predicted.clear(e.idx);
            self.interpolated.clear(e.idx);
            switch (role) {
                .predicted => self.predicted.set(e.idx),
                .interpolated => self.interpolated.set(e.idx),
                .replicated => {},
            }
        }
        pub fn isPredicted(self: *const Self, e: Entity) bool {
            return self.predicted.isSet(e.idx);
        }
        pub fn isInterpolated(self: *const Self, e: Entity) bool {
            return self.interpolated.isSet(e.idx);
        }

        /// Default spawn → **replicated** (stored, not client-simulated). Use the role
        /// helpers below to opt an entity into the prediction or interpolation set.
        pub fn spawn(self: *Self) ?Entity {
            return self.inner.spawn();
        }
        /// Predicted + input-controlled (the local avatar).
        pub fn spawnOwned(self: *Self) ?Entity {
            const e = self.inner.spawn() orelse return null;
            self.owned.set(e.idx);
            self.predicted.set(e.idx);
            return e;
        }
        /// Predicted but not input-controlled (a nearby collider you simulate locally).
        pub fn spawnPredicted(self: *Self) ?Entity {
            const e = self.inner.spawn() orelse return null;
            self.predicted.set(e.idx);
            return e;
        }
        /// Interpolated remote (rendered behind the server; never stepped on the client).
        pub fn spawnInterpolated(self: *Self) ?Entity {
            const e = self.inner.spawn() orelse return null;
            self.interpolated.set(e.idx);
            return e;
        }
        pub fn despawn(self: *Self, e: Entity) void {
            self.owned.clear(e.idx);
            self.predicted.clear(e.idx);
            self.interpolated.clear(e.idx);
            self.inputs[e.idx] = null;
            self.inner.despawn(e);
        }
        pub fn get(self: *Self, e: Entity, comptime C: type) ?*C {
            return self.inner.get(e, C);
        }
        pub fn set(self: *Self, e: Entity, comptime C: type, v: C) void {
            self.inner.set(e, C, v);
        }
        pub fn has(self: *const Self, e: Entity, comptime C: type) bool {
            return self.inner.has(e, C);
        }
        pub fn isOwned(self: *const Self, e: Entity) bool {
            return self.owned.isSet(e.idx);
        }
        /// The input attached to entity `e` this tick (controlled entities), or null.
        pub fn input(self: *const Self, e: Entity) ?Input {
            return if (self.inner.isAlive(e)) self.inputs[e.idx] else null;
        }
        pub fn setInput(self: *Self, e: Entity, in: Input) void {
            self.inputs[e.idx] = in;
        }

        /// Iterate live entities that have every component in `comps` (a tuple of types).
        pub fn query(self: *Self, comptime comps: anytype) Query(comps) {
            return .{ .w = self, .i = 0 };
        }
        fn Query(comptime comps: anytype) type {
            return struct {
                w: *Self,
                i: usize,
                pub fn next(q: *@This()) ?Entity {
                    while (q.i < max_entities) {
                        const idx: u32 = @intCast(q.i);
                        q.i += 1;
                        if (!q.w.inner.alive.isSet(idx)) continue;
                        // `step` may mutate only the **simulated** set: the predicted
                        // entities on a client, every entity on the server. Reads of
                        // other entities (collision) still use `world.get`.
                        if (!q.w.simulate_all and !q.w.predicted.isSet(idx)) continue;
                        // even on the authority, skip entities owned by a client - that
                        // client simulates them and uploads their state (client-authority).
                        if (q.w.simulate_all and !q.w.authority.serverOwns(idx)) continue;
                        const e = Entity{ .idx = idx, .gen = q.w.inner.gens[idx] };
                        var ok = true;
                        inline for (comps) |C| {
                            if (!q.w.inner.has(e, C)) ok = false;
                        }
                        if (ok) return e;
                    }
                    return null;
                }
            };
        }
    };

    const Backend = rollbackBackend(GameWorld, max_rollback);

    return struct {
        pub const Registry = Reg;
        /// The rollback-history backend type in effect (for tests / introspection).
        pub const Rollback = Backend;
        pub const WorldT = GameWorld;
        pub const Entity = GameWorld.Entity;
        pub const InputType = Input;
        pub const fixed_dt = dt;
        /// Server-side lag-compensation snapshot ring (record hitboxes per tick, then
        /// `rewindRaycast(view_tick, …)` - favor the shooter). See `lagcomp.zig`.
        pub const LagComp = @import("lagcomp.zig").LagComp(max_entities, max_rollback);
        /// Per-remote smoothing for a transparent interpolated read. See `interpolate.zig`.
        pub const Interpolator = @import("interpolate.zig").Interpolator;

        pub const Snapshot = Snap;
        pub const EntityMap = @import("entity_map.zig").EntityMap(Entity, max_entities);

        /// Server-authoritative simulation: one `step` per tick over the whole world,
        /// plus the per-client send path (interest set → priority order → delta vs the
        /// client's baseline, budgeted). The app supplies the visible, priority-ordered
        /// entity list (interest/priority are policy - see `interest.zig`/`priority.zig`).
        pub const Server = struct {
            world: GameWorld = .{ .simulate_all = true }, // authority simulates the whole world
            baselines: [max_clients]Inner = [_]Inner{.{}} ** max_clients, // per-client last-sent baseline

            pub fn advance(self: *Server) void {
                step(&self.world, dt);
                self.world.tick += 1;
            }
            pub fn setInput(self: *Server, e: Entity, in: Input) void {
                self.world.setInput(e, in);
            }

            // ---- client authority ----

            const authmod = @import("authority.zig");

            /// Transfer authority over `e` to `owner` (`authority.server` to revoke,
            /// `authority.client(id)` to hand to a client). The server stops simulating a
            /// client-owned entity; the owning client uploads its state via `uploadOwned`.
            /// Broadcast the returned `Grant` (over a reliable channel) so clients learn it.
            pub fn transferAuthority(self: *Server, e: Entity, owner: u16) authmod.Grant {
                self.world.setAuthority(e, owner);
                return .{ .net_id = e.idx, .owner = owner };
            }
            pub fn authorityOf(self: *Server, e: Entity) u16 {
                return self.world.authorityOf(e);
            }

            /// Handle a client's authority `Request` under a policy: `allow(req) bool`
            /// (e.g. only if currently server-owned). Returns the `Grant` to broadcast, or
            /// null if denied.
            pub fn onAuthorityRequest(self: *Server, req: authmod.Request, ctx: anytype) ?authmod.Grant {
                if (!ctx.allow(req)) return null;
                self.world.authority.set(req.net_id, authmod.client(req.client_id));
                return .{ .net_id = req.net_id, .owner = authmod.client(req.client_id) };
            }

            /// Apply a client's authoritative upload (the bytes `Client.uploadOwned`
            /// produced) - **only** for entities that client owns; an update for any other
            /// entity is dropped (anti-cheat). Those changes then re-replicate to other
            /// clients through the normal `snapshotFor` baseline diff.
            pub fn applyClientUpload(self: *Server, client_id: u16, bytes: []const u8) void {
                const Ctx = struct {
                    auth: *const authmod.Table(max_entities),
                    owner: u16,
                    pub fn allow(c: *@This(), net_id: u32) bool {
                        return c.auth.ownedBy(net_id, c.owner);
                    }
                };
                var ctx = Ctx{ .auth = &self.world.authority, .owner = authmod.client(client_id) };
                Snap.applyOwned(&self.world.inner, bytes, &ctx);
            }

            /// Write a delta snapshot for `client_idx` covering `visible` (the client's
            /// interest set, priority-ordered) within `budget` bytes; updates that
            /// client's baseline. Returns the datagram length.
            pub fn snapshotFor(self: *Server, client_idx: usize, visible: []const Entity, budget: usize, buf: []u8) usize {
                return Snap.write(&self.world.inner, &self.baselines[client_idx], visible, budget, buf);
            }

            /// Ack-gated delta for an **unreliable** snapshot channel: writes the delta
            /// without advancing the client's baseline. Call `commitSnapshot` only when
            /// the client acknowledges receipt - so a dropped snapshot re-sends rather
            /// than permanently desyncing that client.
            pub fn snapshotPendingFor(self: *Server, client_idx: usize, visible: []const Entity, budget: usize, buf: []u8) usize {
                return Snap.writePending(&self.world.inner, &self.baselines[client_idx], visible, budget, buf);
            }
            /// Roll `client_idx`'s baseline forward by an acknowledged pending snapshot.
            pub fn commitSnapshot(self: *Server, client_idx: usize, bytes: []const u8) void {
                Snap.commit(&self.baselines[client_idx], bytes);
            }
        };

        /// Client: simulates the **predicted set**, reconciles it against the
        /// authoritative world (completed-tick rollback), and renders interpolated
        /// remotes behind the server. Rollback history is stored by the comptime
        /// `Backend` (whole-world / scoped / sparse - `.rollback` in the spec).
        pub const Client = struct {
            world: GameWorld = .{}, // present (predicted) state + interpolated colliders
            backend: Backend = .{}, // per-tick predicted-state history (pluggable)
            // Local input per tick on the sparse `History` primitive: tick-keyed,
            // stores only changes, `get(t)` resolves the latest input ≤ t, `shift` keeps it
            // aligned through a hard tick-resync.
            in_hist: History(Input, max_rollback) = .{},
            tick: u32 = 0,
            rollbacks: u32 = 0,
            mismatch: MismatchMask = .{}, // O(1) dedup of already-rolled-back ticks
            interp: InterpTuple = undefined, // per-remote-entity interpolators (lerp components)
            tracer: Tracer = .{}, // duck-typed; `onRollback` fires on a real rollback

            pub fn init(self: *Client) void {
                self.* = .{};
                self.backend.init();
                inline for (0..lerp_ids.len) |i| {
                    for (&self.interp[i]) |*ip| ip.* = .{};
                }
            }

            const authmod = @import("authority.zig");

            /// Set this client's id (so it knows which entities it owns). Call once.
            pub fn setClientId(self: *Client, id: u16) void {
                self.world.local_owner = authmod.client(id);
            }

            /// Spawn a **client-authoritative** entity at its network-id slot. Authority
            /// entities are mirrored at `idx == net_id` on both ends, so the client's
            /// `uploadOwned` and the server's `applyClientUpload` address them identically
            /// with no reverse mapping. Use for client-spawned-then-server-owned objects.
            pub fn spawnAuthoritative(self: *Client, net_id: u32) ?Entity {
                const e = self.world.inner.spawnAt(net_id) orelse return null;
                self.world.setAuthority(e, self.world.local_owner);
                self.world.predicted.set(e.idx); // the client simulates what it owns
                return e;
            }

            /// Apply an authority `Grant` from the server: a newly-owned entity (at its
            /// net-id slot) starts being simulated + uploaded locally; a revoked one stops.
            pub fn onAuthorityGrant(self: *Client, grant: authmod.Grant) void {
                const e = self.world.inner.ensureSlot(grant.net_id);
                self.world.setAuthority(e, grant.owner);
                if (grant.owner == self.world.local_owner) {
                    self.world.predicted.set(e.idx);
                } else {
                    self.world.predicted.clear(e.idx); // no longer ours → stop simulating
                }
            }
            pub fn ownsEntity(self: *const Client, e: Entity) bool {
                return self.world.ownsSlot(e.idx);
            }

            /// Write this client's authoritative state for every entity it owns, keyed by
            /// net id (== slot), as a delta vs `local_baseline`. Send the bytes to the
            /// server (`applyClientUpload`). Returns the length.
            pub fn uploadOwned(self: *Client, local_baseline: *Inner, budget: usize, buf: []u8) usize {
                var owned: [max_entities]Inner.Entity = undefined;
                var n: usize = 0;
                var i: u32 = 0;
                while (i < max_entities) : (i += 1) {
                    if (self.world.inner.alive.isSet(i) and self.world.ownsSlot(i)) {
                        owned[n] = .{ .idx = i, .gen = self.world.inner.gens[i] };
                        n += 1;
                    }
                }
                return Snap.write(&self.world.inner, local_baseline, owned[0..n], budget, buf);
            }

            /// Push the confirmed value of `e`'s lerp-able components at server `tick`
            /// into its interpolators (call when an authoritative snapshot is applied,
            /// *before* the next `predict`, so the confirmed value isn't yet overwritten
            /// by a collider sample).
            pub fn recordRemote(self: *Client, e: Entity, server_tick: u32) void {
                inline for (lerp_ids, 0..) |id, li| {
                    const C = Reg.Type(id);
                    if (self.world.get(e, C)) |v| self.interp[li][e.idx].push(server_tick, v.*);
                }
            }

            /// **Transparent render read**: predicted entities → their present
            /// value; interpolated entities → the lerp sample at `render_tick`
            /// (= server tick − delay) for lerp-able components, else confirmed; replicated
            /// → confirmed. Render code never branches on role.
            pub fn render(self: *Client, e: Entity, comptime C: type, render_tick: f32) ?C {
                if (self.world.isInterpolated(e)) {
                    if (comptime lerpIndexOf(C)) |li| {
                        if (self.interp[li][e.idx].sample(render_tick)) |v| return v;
                    }
                }
                return if (self.world.get(e, C)) |p| p.* else null;
            }

            /// Place interpolated entities at their `render_tick` sample so the predicted
            /// set collides against where remotes are *rendered* (compiles to nothing when
            /// no component opts into `lerp`).
            fn placeColliders(self: *Client, render_tick: f32) void {
                if (comptime lerp_ids.len == 0) return;
                var i: u32 = 0;
                while (i < max_entities) : (i += 1) {
                    if (!self.world.interpolated.isSet(i) or !self.world.inner.alive.isSet(i)) continue;
                    const e = Entity{ .idx = i, .gen = self.world.inner.gens[i] };
                    inline for (lerp_ids, 0..) |id, li| {
                        const C = Reg.Type(id);
                        if (self.interp[li][i].sample(render_tick)) |v| self.world.set(e, C, v);
                    }
                }
            }

            /// Attach `local` to owned entities and advance one tick immediately -
            /// stepping only the predicted set (interpolated colliders are placed first).
            pub fn predict(self: *Client, local: Input) void {
                self.tick += 1;
                applyOwnedInput(&self.world, local);
                self.placeColliders(@floatFromInt(self.tick));
                step(&self.world, dt);
                self.world.tick = self.tick;
                self.backend.record(self.tick, &self.world, &self.world.predicted);
                self.in_hist.record(self.tick, local);
            }

            /// An authoritative world for the **completed tick** `auth_tick` arrived. The
            /// completed-tick invariant certifies every replicated component at `auth_tick`.
            /// Compare the **predicted set** against it; on any mismatch, restore those
            /// entities from authority and **replay** `step` (predicted-only, colliders
            /// re-placed per tick) forward to "now". Interpolated/replicated entities are
            /// outside the rollback loop. The `MismatchMask` counts a tick's rollback once.
            pub fn reconcile(self: *Client, auth: *const GameWorld, auth_tick: u32) bool {
                if (auth_tick > self.tick) return false;
                if (self.backend.agree(auth_tick, auth, &self.world.predicted)) return false; // held
                if (!self.mismatch.isMarked(auth_tick)) {
                    self.rollbacks += 1; // count this completed-tick rollback once
                    self.mismatch.mark(auth_tick);
                    self.tracer.onRollback(auth_tick, @intCast(self.world.predicted.popCount()));
                }
                copyPredicted(&self.world, auth); // restore the predicted set from authority
                self.world.tick = auth_tick;
                self.backend.record(auth_tick, &self.world, &self.world.predicted);
                var t = auth_tick + 1;
                while (t <= self.tick) : (t += 1) {
                    if (self.in_hist.get(t)) |in| applyOwnedInput(&self.world, in);
                    self.placeColliders(@floatFromInt(t));
                    step(&self.world, dt);
                    self.world.tick = t;
                    self.backend.record(t, &self.world, &self.world.predicted);
                }
                return true;
            }

            /// Read the present (post-replay) value: predicted for the predicted set,
            /// latest-confirmed otherwise. For smooth interpolated remotes use `render`.
            pub fn get(self: *Client, e: Entity, comptime C: type) ?*C {
                return self.world.get(e, C);
            }
        };

        fn applyOwnedInput(w: *GameWorld, in: Input) void {
            var i: u32 = 0;
            while (i < max_entities) : (i += 1) {
                if (w.owned.isSet(i) and w.inner.alive.isSet(i)) w.inputs[i] = in;
            }
        }

        /// Restore the **predicted** entities of `w` from the authoritative world (the
        /// single rollback point), leaving interpolated/replicated entities untouched.
        fn copyPredicted(w: *GameWorld, auth: *const GameWorld) void {
            var i: u32 = 0;
            while (i < max_entities) : (i += 1) {
                if (!w.predicted.isSet(i)) continue;
                const a = @constCast(auth);
                if (auth.inner.alive.isSet(i)) {
                    w.inner.alive.set(i);
                    w.inner.gens[i] = auth.inner.gens[i];
                    inline for (0..Reg.count) |id| {
                        if (auth.inner.present[id].isSet(i)) {
                            w.inner.present[id].set(i);
                            w.inner.store[id][i] = a.inner.store[id][i];
                        } else {
                            w.inner.present[id].clear(i);
                        }
                    }
                } else if (w.inner.alive.isSet(i)) {
                    w.inner.alive.clear(i);
                    inline for (0..Reg.count) |id| w.inner.present[id].clear(i);
                }
            }
        }
    };
}

// ---- tests: one user `step`, run server-side and client predict/reconcile ----

const testing = std.testing;

const Pos = struct { x: i32, y: i32 };
const Vel = struct { x: i32, y: i32 };
const Cmd = struct { ax: i32 };

fn gameStep(w: anytype, dt_: f32) void {
    _ = dt_;
    var it = w.query(.{ Pos, Vel });
    while (it.next()) |e| {
        const v = w.get(e, Vel).?;
        const in = w.input(e) orelse Cmd{ .ax = 0 };
        w.get(e, Pos).?.x += v.x;
        v.x += in.ax; // controlled acceleration
    }
}

const Game = Engine(.{ .components = .{ Pos, Vel }, .Input = Cmd, .max_entities = 32, .max_rollback_ticks = 32, .step = gameStep });

test "engine: the same step runs server-authoritative and client-predicted" {
    var server = Game.Server{};
    const e = server.world.spawn().?;
    server.world.set(e, Pos, .{ .x = 0, .y = 0 });
    server.world.set(e, Vel, .{ .x = 0, .y = 0 });
    server.setInput(e, .{ .ax = 1 });

    var i: usize = 0;
    while (i < 5) : (i += 1) server.advance();
    // pos accumulates v before each step: 0+1+2+3+4 = 10; v reaches 5
    try testing.expectEqual(@as(i32, 10), server.world.get(e, Pos).?.x);
    try testing.expectEqual(@as(i32, 5), server.world.get(e, Vel).?.x);
}

test "engine: client predicts, then a whole-world rollback reconciles to authoritative" {
    var client = Game.Client{};
    client.init();
    const e = client.world.spawnOwned().?;
    client.world.set(e, Pos, .{ .x = 0, .y = 0 });
    client.world.set(e, Vel, .{ .x = 0, .y = 0 });

    // authoritative twin runs the same step, with an unpredicted impulse at tick 10
    var server = Game.Server{};
    const se = server.world.spawnOwned().?;
    server.world.set(se, Pos, .{ .x = 0, .y = 0 });
    server.world.set(se, Vel, .{ .x = 0, .y = 0 });

    // snapshot of the authoritative world at each tick, delivered `latency` ticks late
    const latency: u32 = 5;
    var pending: [128]struct { at: u32, tick: u32, w: Game.WorldT } = undefined;
    var np: usize = 0;

    var t: u32 = 1;
    while (t <= 40) : (t += 1) {
        const cmd = Cmd{ .ax = 1 };
        client.predict(cmd); // responsive: owned entity advances immediately
        server.setInput(se, cmd);
        if (t == 10) server.world.get(se, Vel).?.x += 20; // server-only event
        server.advance();
        pending[np] = .{ .at = t + latency, .tick = t, .w = server.world };
        np += 1;
        for (pending[0..np]) |snap| {
            if (snap.at == t) _ = client.reconcile(&snap.w, snap.tick);
        }
    }
    for (pending[0..np]) |snap| {
        if (snap.at > 40) _ = client.reconcile(&snap.w, snap.tick);
    }

    try testing.expect(client.rollbacks > 0); // the impulse was a real misprediction
    try testing.expectEqual(@as(u32, 40), client.tick); // stayed at "now"
    // after the whole-world rollback + replay, the client matches the authoritative world
    try testing.expectEqual(server.world.get(se, Pos).?.x, client.get(e, Pos).?.x);
    try testing.expectEqual(server.world.get(se, Vel).?.x, client.get(e, Vel).?.x);
}

test "engine: world.query iterates entities with the required components; input attaches" {
    var w = Game.WorldT{};
    const a = w.spawnPredicted().?; // query is scoped to the predicted set
    w.set(a, Pos, .{ .x = 1, .y = 1 });
    w.set(a, Vel, .{ .x = 1, .y = 0 }); // has both
    const b = w.spawnPredicted().?;
    w.set(b, Pos, .{ .x = 2, .y = 2 }); // Pos only
    w.setInput(a, .{ .ax = 3 });

    var n: usize = 0;
    var it = w.query(.{ Pos, Vel });
    while (it.next()) |e| {
        try testing.expect(w.has(e, Pos) and w.has(e, Vel));
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n); // only `a` has both
    try testing.expectEqual(@as(i32, 3), w.input(a).?.ax);
    try testing.expect(w.input(b) == null);
}

test "engine: a REMOTE (non-owned) entity mismatch triggers the whole-world rollback" {
    var client = Game.Client{};
    client.init();
    const player = client.world.spawnOwned().?; // owned, predicted from input
    client.world.set(player, Pos, .{ .x = 0, .y = 0 });
    client.world.set(player, Vel, .{ .x = 0, .y = 0 });
    const npc = client.world.spawnPredicted().?; // predicted (not owned), simulated by `step`
    client.world.set(npc, Pos, .{ .x = 0, .y = 0 });
    client.world.set(npc, Vel, .{ .x = 1, .y = 0 });

    var server = Game.Server{};
    const sp = server.world.spawnOwned().?;
    server.world.set(sp, Pos, .{ .x = 0, .y = 0 });
    server.world.set(sp, Vel, .{ .x = 0, .y = 0 });
    const snpc = server.world.spawn().?;
    server.world.set(snpc, Pos, .{ .x = 0, .y = 0 });
    server.world.set(snpc, Vel, .{ .x = 1, .y = 0 });

    // tick 5: the server changes the NPC's velocity - the client predicted the old one.
    var t: u32 = 1;
    var auth_at5: ?Game.WorldT = null;
    while (t <= 10) : (t += 1) {
        client.predict(.{ .ax = 0 }); // player idle; both still predict the NPC drifting
        server.world.setInput(sp, .{ .ax = 0 });
        if (t == 5) server.world.get(snpc, Vel).?.x = 9; // unpredicted REMOTE change
        server.advance();
        if (t == 5) auth_at5 = server.world;
    }
    // deliver the authoritative completed-tick-5 world: the NPC (a remote) diverged
    try testing.expect(client.reconcile(&auth_at5.?, 5)); // whole-world rollback fired
    try testing.expect(client.rollbacks == 1);
    // reconciling the same completed tick again does not double-count the rollback
    _ = client.reconcile(&auth_at5.?, 5);
    try testing.expectEqual(@as(u32, 1), client.rollbacks);
}

test "engine Server.snapshotFor: per-client delta replicates the world to a client" {
    var server = Game.Server{};
    const a = server.world.spawn().?;
    server.world.set(a, Pos, .{ .x = 5, .y = -3 });
    server.world.set(a, Vel, .{ .x = 1, .y = 0 });
    const b = server.world.spawn().?;
    server.world.set(b, Pos, .{ .x = 9, .y = 9 });

    var buf: [256]u8 = undefined;
    const vis = [_]Game.Entity{ a, b };
    const n = server.snapshotFor(0, &vis, 256, &buf);

    var client = Game.WorldT{};
    var map = Game.EntityMap{};
    Game.Snapshot.apply(&client.inner, &map, buf[0..n]);
    try testing.expectEqual(@as(i16, 5), client.inner.get(map.get(a.idx).?, Pos).?.x);
    try testing.expectEqual(@as(i8, 1), client.inner.get(map.get(a.idx).?, Vel).?.x);
    try testing.expectEqual(@as(i16, 9), client.inner.get(map.get(b.idx).?, Pos).?.y);

    // unchanged → the next snapshot is just the terminator
    try testing.expectEqual(@as(usize, 1), server.snapshotFor(0, &vis, 256, &buf));
}

const Tf = struct {
    x: f32,
    pub fn lerp(a: Tf, b: Tf, t: f32) Tf {
        return .{ .x = a.x + (b.x - a.x) * t };
    }
};
const In2 = struct { dx: f32 };
fn step2(w: anytype, dt_: f32) void {
    _ = dt_;
    var it = w.query(.{Tf});
    while (it.next()) |e| {
        const in = w.input(e) orelse In2{ .dx = 0 };
        w.get(e, Tf).?.x += in.dx;
    }
}
const Game2 = Engine(.{ .components = .{Tf}, .Input = In2, .max_entities = 16, .step = step2 });

test "engine render: owned reads predicted, remote reads interpolated (uniform get)" {
    var c = Game2.Client{};
    c.init();
    const me = c.world.spawnOwned().?;
    c.world.set(me, Tf, .{ .x = 0 });
    const them = c.world.spawnInterpolated().?; // remote, rendered via interpolation

    // confirmed remote samples: tick 0 → x=0, tick 10 → x=100
    c.world.set(them, Tf, .{ .x = 0 });
    c.recordRemote(them, 0);
    c.world.set(them, Tf, .{ .x = 100 });
    c.recordRemote(them, 10);

    // render the REMOTE at tick 5 → interpolated halfway (50), not the latest confirmed
    try testing.expectApproxEqAbs(@as(f32, 50), c.render(them, Tf, 5).?.x, 1e-4);
    // render the OWNED entity → its predicted/present value (no interpolation)
    c.world.set(me, Tf, .{ .x = 42 });
    try testing.expectApproxEqAbs(@as(f32, 42), c.render(me, Tf, 5).?.x, 1e-4);
}

// ---- roles (B): per-entity prediction scope ----

test "interpolated (non-predicted) entity divergence does NOT trigger a rollback" {
    var client = Game.Client{};
    client.init();
    const me = client.world.spawnOwned().?; // predicted
    client.world.set(me, Pos, .{ .x = 0, .y = 0 });
    client.world.set(me, Vel, .{ .x = 0, .y = 0 });
    const ghost = client.world.spawnInterpolated().?; // NOT predicted → outside rollback
    client.world.set(ghost, Pos, .{ .x = 0, .y = 0 });
    client.world.set(ghost, Vel, .{ .x = 0, .y = 0 });

    var server = Game.Server{};
    const sme = server.world.spawnOwned().?;
    server.world.set(sme, Pos, .{ .x = 0, .y = 0 });
    server.world.set(sme, Vel, .{ .x = 0, .y = 0 });
    const sghost = server.world.spawn().?;
    server.world.set(sghost, Pos, .{ .x = 999, .y = 0 }); // wildly different from the client's ghost
    server.world.set(sghost, Vel, .{ .x = 0, .y = 0 });

    var t: u32 = 1;
    while (t <= 10) : (t += 1) {
        client.predict(.{ .ax = 0 }); // owned idle → no owned mismatch
        server.setInput(sme, .{ .ax = 0 });
        server.advance();
    }
    // the predicted set (me) matches authority; the ghost is interpolated, so its huge
    // divergence is *not* compared → no rollback. (Whole-world compare would have fired.)
    try testing.expect(!client.reconcile(&server.world, 10));
    try testing.expectEqual(@as(u32, 0), client.rollbacks);
}

// ---- the rollback-storage backend seam: all three are interchangeable ----

// ---- client authority + transfer ----

const authm = @import("authority.zig");

test "client authority: owner simulates + uploads; server stores it and gates non-owners" {
    var server = Game.Server{};
    // sa: server-owned (the server simulates it). sb: will be handed to client 0.
    const sa = server.world.spawn().?;
    server.world.set(sa, Pos, .{ .x = 0, .y = 0 });
    server.world.set(sa, Vel, .{ .x = 1, .y = 0 });
    const sb = server.world.spawn().?;
    server.world.set(sb, Pos, .{ .x = 0, .y = 0 });
    server.world.set(sb, Vel, .{ .x = 0, .y = 0 });

    // hand authority over sb to client 0.
    const grant = server.transferAuthority(sb, authm.client(0));
    try testing.expectEqual(authm.client(0), server.authorityOf(sb));

    // the server now simulates only sa (sb is client-owned → skipped by the query gate).
    server.advance();
    try testing.expectEqual(@as(i32, 1), server.world.get(sa, Pos).?.x); // server-owned, stepped
    try testing.expectEqual(@as(i32, 0), server.world.get(sb, Pos).?.x); // client-owned, not stepped

    // client 0 receives the grant, owns sb at its net-id slot, sets its authoritative value.
    var client = Game.Client{};
    client.init();
    client.setClientId(0);
    client.onAuthorityGrant(grant);
    const cb = Game.Entity{ .idx = sb.idx, .gen = client.world.inner.gens[sb.idx] };
    try testing.expect(client.ownsEntity(cb));
    client.world.set(cb, Pos, .{ .x = 999, .y = 7 });

    // forge: the client also tries to upload sa (which it does NOT own) - anti-cheat.
    const fa = client.world.inner.ensureSlot(sa.idx);
    client.world.setAuthority(fa, client.world.local_owner); // client lies that it owns sa
    client.world.set(fa, Pos, .{ .x = 777, .y = 0 });

    var cbase = @TypeOf(client.world.inner){}; // the client's last-uploaded baseline
    var buf: [256]u8 = undefined;
    const n = client.uploadOwned(&cbase, 256, &buf);
    server.applyClientUpload(0, buf[0..n]);

    // sb (owned by client 0) was applied; sa (owned by the server) was dropped.
    try testing.expectEqual(@as(i32, 999), server.world.get(sb, Pos).?.x);
    try testing.expectEqual(@as(i32, 1), server.world.get(sa, Pos).?.x); // unchanged - forge rejected
}

const store_ns = @import("store.zig");
const GameDense = Engine(.{ .components = .{ Pos, Vel }, .Input = Cmd, .max_entities = 32, .max_rollback_ticks = 32, .step = gameStep, .rollback = store_ns.Dense });
const GameSc = Engine(.{ .components = .{ Pos, Vel }, .Input = Cmd, .max_entities = 32, .max_rollback_ticks = 32, .step = gameStep, .rollback = store_ns.Scoped });
const GameSp = Engine(.{ .components = .{ Pos, Vel }, .Input = Cmd, .max_entities = 32, .max_rollback_ticks = 32, .step = gameStep, .rollback = store_ns.Sparse });

fn driveRollback(comptime G: type) struct { x: i32, vx: i32, rb: u32 } {
    var client = G.Client{};
    client.init();
    const e = client.world.spawnOwned().?;
    client.world.set(e, Pos, .{ .x = 0, .y = 0 });
    client.world.set(e, Vel, .{ .x = 0, .y = 0 });
    var server = G.Server{};
    const se = server.world.spawnOwned().?;
    server.world.set(se, Pos, .{ .x = 0, .y = 0 });
    server.world.set(se, Vel, .{ .x = 0, .y = 0 });

    const latency: u32 = 5;
    var pending: [128]struct { at: u32, tick: u32, w: G.WorldT } = undefined;
    var np: usize = 0;
    var t: u32 = 1;
    while (t <= 40) : (t += 1) {
        const cmd = Cmd{ .ax = 1 };
        client.predict(cmd);
        server.setInput(se, cmd);
        if (t == 10) server.world.get(se, Vel).?.x += 20; // unpredicted impulse
        server.advance();
        pending[np] = .{ .at = t + latency, .tick = t, .w = server.world };
        np += 1;
        for (pending[0..np]) |snap| {
            if (snap.at == t) _ = client.reconcile(&snap.w, snap.tick);
        }
    }
    for (pending[0..np]) |snap| {
        if (snap.at > 40) _ = client.reconcile(&snap.w, snap.tick);
    }
    return .{ .x = client.get(e, Pos).?.x, .vx = client.get(e, Vel).?.x, .rb = client.rollbacks };
}

test "rollback backends are interchangeable: Dense == Scoped == Sparse (differential)" {
    const a = driveRollback(GameDense);
    const b = driveRollback(GameSc);
    const c = driveRollback(GameSp);
    try testing.expect(a.rb > 0); // the impulse really did force rollbacks
    // identical reconciled state AND identical rollback counts across all three backends
    try testing.expectEqual(a.x, b.x);
    try testing.expectEqual(a.vx, b.vx);
    try testing.expectEqual(a.rb, b.rb);
    try testing.expectEqual(a.x, c.x);
    try testing.expectEqual(a.vx, c.vx);
    try testing.expectEqual(a.rb, c.rb);
}

// ---- the View seam at engine scale: replicate a Server's world into an external ECS ----

const SnapshotFn = @import("snapshot.zig").Snapshot;
const EntityMapFn = @import("entity_map.zig").EntityMap;

/// An external-ECS stand-in for the engine's {Pos, Vel} registry - its own arrays,
/// no `World`. A flecs adapter is the same shape over the flecs C API.
const EngView = struct {
    const Self = @This();
    pub const Entity = struct { idx: u32, gen: u32 };
    pub const Registry = Game.Registry;
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
        @compileError("EngView: unknown component");
    }
    pub fn set(self: *Self, e: Entity, comptime C: type, v: C) void {
        if (!self.isAlive(e)) return;
        if (C == Pos) {
            self.pos[e.idx] = v;
            self.has_pos[e.idx] = true;
        } else if (C == Vel) {
            self.vel[e.idx] = v;
            self.has_vel[e.idx] = true;
        } else @compileError("EngView: unknown component");
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

test "engine replication composes with an external ECS view (Game.Registry + Snapshot)" {
    var server = Game.Server{};
    const a = server.world.spawn().?;
    server.world.set(a, Pos, .{ .x = 5, .y = -3 });
    server.world.set(a, Vel, .{ .x = 1, .y = 0 });
    const b = server.world.spawn().?;
    server.world.set(b, Pos, .{ .x = 9, .y = 9 }); // no Vel

    var buf: [256]u8 = undefined;
    const vis = [_]Game.Entity{ a, b };
    const n = server.snapshotFor(0, &vis, 256, &buf); // engine's built-in send path

    // …apply into an external ECS using the engine's *registry* + a View (no mirror).
    const ViewSnap = SnapshotFn(Game.Registry, EngView);
    const ViewMap = EntityMapFn(EngView.Entity, 32);
    var client = EngView{};
    var map = ViewMap{};
    ViewSnap.apply(&client, &map, buf[0..n]);

    try testing.expectEqual(@as(i32, 5), client.get(map.get(a.idx).?, Pos).?.x);
    try testing.expectEqual(@as(i32, 1), client.get(map.get(a.idx).?, Vel).?.x);
    try testing.expectEqual(@as(i32, 9), client.get(map.get(b.idx).?, Pos).?.y);
    try testing.expect(client.get(map.get(b.idx).?, Vel) == null);
}
