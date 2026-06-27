//! The replication ↔ transport bridge: turns the proven-but-manual "drive the L5 engine
//! over a Session/Endpoint" loop into one-call helpers. Pure duck-typed glue - generic
//! over the endpoint and engine types the app instantiates, so it stays out of the layer
//! graph (the sans-IO core never imports this). Use it to run a server-authoritative
//! engine across many connections, or apply snapshots on a client, without hand-wiring
//! the snapshot bytes through a channel each tick.

const std = @import("std");

/// Server side: write a per-client delta snapshot for every live connection on `ep` and
/// send it over reliable channel `ch`. The endpoint's connection slot index is the
/// engine's per-client baseline index (so `Endpoint.capacity ≤ Engine max_clients`).
/// `vis` supplies each client's visible, priority-ordered entity list:
///   `pub fn visible(self, addr: u64, out: []Entity) []const Entity`
/// (interest + priority are policy - see `interest.zig` / `priority.zig`).
pub fn pushSnapshots(server: anytype, ep: anytype, comptime ch: anytype, budget: usize, vis: anytype) void {
    const Entity = @TypeOf(server.world).Entity;
    const cap = @TypeOf(ep.*).capacity;
    var buf: [1500]u8 = undefined;
    var visbuf: [256]Entity = undefined;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        if (!ep.used[i]) continue;
        const addr = ep.addrs[i];
        const visible = vis.visible(addr, &visbuf);
        const n = server.snapshotFor(i, visible, @min(budget, buf.len), &buf);
        if (n > 1) ep.sendRawTo(addr, ch, buf[0..n]) catch {}; // >1 ⇒ more than the terminator
    }
}

/// Client side: drain every snapshot waiting on channel `ch` from `addr` and apply it
/// into `world` (the registry store, e.g. `&client.world.inner`) via `map`. `Snap` is the
/// engine's `Snapshot` type. Returns how many snapshots were applied this call.
pub fn applySnapshots(ep: anytype, addr: u64, comptime ch: anytype, comptime Snap: type, world: anytype, map: anytype) usize {
    var buf: [1500]u8 = undefined;
    var n: usize = 0;
    while (ep.receiveRawFrom(addr, ch, &buf)) |len| {
        Snap.apply(world, map, buf[0..len]);
        n += 1;
    }
    return n;
}

/// Typed server-side replication host: owns the engine's `Server` and replicates it
/// over an `Endpoint`. Unlike the free `pushSnapshots`, the methods take **concrete**
/// types (`*EpT`, `EngT.Server`), so an editor shows real signatures + completions.
/// `EpT` = `magnet.Endpoint(cfg)`, `EngT` = `magnet.replication.engine(.{…})`.
pub fn Host(comptime EpT: type, comptime EngT: type) type {
    return struct {
        const Self = @This();
        pub const Endpoint = EpT;
        pub const Engine = EngT;
        pub const Entity = EngT.Entity;

        ep: *EpT,
        server: EngT.Server = .{},

        /// One authoritative simulation tick.
        pub fn advance(self: *Self) void {
            self.server.advance();
        }
        /// Replicate the world to every connection over channel `ch` within `budget`
        /// bytes. `vis` supplies each client's visible, priority-ordered entity list:
        /// `pub fn visible(self, addr: u64, out: []Entity) []const Entity`.
        pub fn replicate(self: *Self, comptime ch: anytype, budget: usize, vis: anytype) void {
            pushSnapshots(&self.server, self.ep, ch, budget, vis);
        }
        /// Transfer authority over `e` to `owner` (`auth.server` / `auth.client(id)`);
        /// returns the `Grant` for the caller to broadcast over a reliable channel.
        pub fn transferAuthority(self: *Self, e: Entity, owner: u16) replAuth.Grant {
            return self.server.transferAuthority(e, owner);
        }
    };
}

/// Typed client-side replication host: owns the local world + entity map and applies
/// snapshots arriving on a channel. Concrete-typed methods for editor completion.
pub fn ClientHost(comptime EpT: type, comptime EngT: type) type {
    return struct {
        const Self = @This();
        pub const Endpoint = EpT;
        pub const Engine = EngT;
        pub const Entity = EngT.Entity;

        ep: *EpT,
        world: EngT.WorldT = .{},
        map: EngT.EntityMap = .{},

        /// Drain + apply every snapshot waiting from `addr` on channel `ch`. Returns count.
        pub fn apply(self: *Self, addr: u64, comptime ch: anytype) usize {
            return applySnapshots(self.ep, addr, ch, EngT.Snapshot, &self.world.inner, &self.map);
        }
        /// This client's local entity for a server network id, or null.
        pub fn local(self: *Self, net_id: u32) ?Entity {
            return self.map.get(net_id);
        }
        pub fn get(self: *Self, e: Entity, comptime C: type) ?*C {
            return self.world.inner.get(e, C);
        }
    };
}

/// Drive an ICE-lite `agent` over a duck-typed transport (`recv(buf, now) ?{addr,len}` /
/// `send(addr, bytes, now)`) for one tick: emit the next connectivity-check probe, and
/// answer/process any inbound checks. Run it each tick (alongside `agent.pollDeadline`)
/// until `agent.selected()` returns the punched-through address; then connect the
/// `Endpoint` to that address. Signaling (candidate exchange) stays the app's job.
pub fn pumpIce(agent: anytype, transport: anytype, now: i64) void {
    var pbuf: [64]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    if (agent.pollProbe(&pbuf, now)) |pr| transport.send(pr.to, pbuf[0..pr.len], now);
    var ibuf: [64]u8 = undefined;
    while (transport.recv(&ibuf, now)) |r| {
        if (agent.onCheck(r.addr, ibuf[0..r.len], &rbuf)) |rlen| transport.send(r.addr, rbuf[0..rlen], now);
    }
}

const testing = std.testing;
const Config = @import("config").Config;
const Endpoint = @import("proto").Endpoint;
const channels = @import("proto").channels;
const sim = @import("runtime").sim;
const poll = @import("runtime").poll;
const replEngine = @import("replication").engine;
const replAuth = @import("replication").auth;
const ice = @import("proto").conn.ice;

// a tiny NAT-modeling transport: datagrams route only to a *public* mapping (host
// candidates are unreachable), and the receiver sees the sender's public mapping.
const IceNet = struct {
    const Msg = struct { from: u64, len: usize, data: [64]u8 = undefined };
    a_pub: u64,
    b_pub: u64,
    a_in: [16]Msg = undefined,
    a_n: usize = 0,
    b_in: [16]Msg = undefined,
    b_n: usize = 0,
    fn deliver(self: *IceNet, to: u64, from: u64, bytes: []const u8) void {
        if (to != self.a_pub and to != self.b_pub) return; // NAT drops non-public dests
        var m = Msg{ .from = from, .len = bytes.len };
        @memcpy(m.data[0..bytes.len], bytes);
        if (to == self.a_pub) {
            self.a_in[self.a_n] = m;
            self.a_n += 1;
        } else {
            self.b_in[self.b_n] = m;
            self.b_n += 1;
        }
    }
};
fn IceSide(comptime is_a: bool) type {
    return struct {
        net: *IceNet,
        pub const Recv = struct { addr: u64, len: usize };
        pub fn send(self: *@This(), to: u64, bytes: []const u8, now: i64) void {
            _ = now;
            self.net.deliver(to, if (is_a) self.net.a_pub else self.net.b_pub, bytes);
        }
        pub fn recv(self: *@This(), buf: []u8, now: i64) ?Recv {
            _ = now;
            const n = if (is_a) &self.net.a_n else &self.net.b_n;
            if (n.* == 0) return null;
            const inb = if (is_a) &self.net.a_in else &self.net.b_in;
            const m = inb[0];
            var i: usize = 1;
            while (i < n.*) : (i += 1) inb[i - 1] = inb[i];
            n.* -= 1;
            @memcpy(buf[0..m.len], m.data[0..m.len]);
            return .{ .addr = m.from, .len = m.len };
        }
    };
}

test "pumpIce drives two agents through a NAT to a nominated public path" {
    var net = IceNet{ .a_pub = 0xAAAA, .b_pub = 0xBBBB };
    var a = ice.Agent(8){ .controlling = true, .tx_seed = 0xA };
    var b = ice.Agent(8){ .controlling = false, .tx_seed = 0xB };
    a.addRemote(.{ .addr = 0x000B, .kind = .host }, 100); // B's host (unreachable)
    a.addRemote(.{ .addr = net.b_pub, .kind = .srflx }, 100); // B's public mapping
    b.addRemote(.{ .addr = 0x000A, .kind = .host }, 100);
    b.addRemote(.{ .addr = net.a_pub, .kind = .srflx }, 100);

    var sa = IceSide(true){ .net = &net };
    var sb = IceSide(false){ .net = &net };
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 200 and (a.selected() == null or b.selected() == null)) : (step += 1) {
        pumpIce(&a, &sa, now);
        pumpIce(&b, &sb, now);
        now += 25;
    }
    try testing.expectEqual(@as(?u64, net.b_pub), a.selected()); // punched through to B's public path
    try testing.expectEqual(@as(?u64, net.a_pub), b.selected());
}

const HPos = struct { x: i32, y: i32 };
const HVel = struct { x: i32, y: i32 };
fn hStep(w: anytype, dt: f32) void {
    _ = dt;
    var it = w.query(.{ HPos, HVel });
    while (it.next()) |e| w.get(e, HPos).?.x += w.get(e, HVel).?.x;
}
const HGame = replEngine(.{ .components = .{ HPos, HVel }, .max_entities = 32, .max_clients = 4, .step = hStep });
const HSchema = channels(.{ .snap = .{ .mode = .reliable_ordered, .Message = void } });
const HCfg = Config{ .channels = HSchema, .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 200, .bridge_cap = 1024, .recvpn_cap = 256 } };
const HEp = Endpoint(HCfg);

test "host bridge: one call pushes the engine's world over a real lossy endpoint to a client" {
    const alloc = testing.allocator;
    const link = try alloc.create(sim.DefaultLink);
    defer alloc.destroy(link);
    link.* = .{ .params = .{ .latency_ms = 30, .jitter_ms = 10, .loss_permille = 200, .seed = 7 }, .prng = std.Random.DefaultPrng.init(7) };
    const server_ep = try alloc.create(HEp);
    defer alloc.destroy(server_ep);
    server_ep.* = .{};
    const client_ep = try alloc.create(HEp);
    defer alloc.destroy(client_ep);
    client_ep.* = .{};

    const server_addr: u64 = 2;
    const client_addr: u64 = 1;
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var game = HGame.Server{};
    const e = game.world.spawn().?;
    game.world.set(e, HPos, .{ .x = 0, .y = 0 });
    game.world.set(e, HVel, .{ .x = 3, .y = 0 });

    // touch the server endpoint so client 0's slot exists (a real app gets this on connect)
    try client_ep.sendRawTo(server_addr, .snap, "hi");

    var cworld = HGame.WorldT{};
    var map = HGame.EntityMap{};
    const Vis = struct {
        e: HGame.Entity,
        pub fn visible(self: *@This(), addr: u64, out: []HGame.Entity) []const HGame.Entity {
            _ = addr;
            out[0] = self.e;
            return out[0..1];
        }
    };
    var vis = Vis{ .e = e };

    var scratch: [256]u8 = undefined;
    var now: i64 = 0;
    var tick: usize = 0;
    while (tick < 400) : (tick += 1) {
        if (tick < 200) {
            game.advance(); // authoritative sim
            pushSnapshots(&game, server_ep, .snap, 200, &vis); // ← one call replicates to all clients
        }
        poll.flushAll(server_ep, &stx, &scratch, now);
        poll.recvAll(client_ep, &ctx, &scratch, now);
        _ = applySnapshots(client_ep, server_addr, .snap, HGame.Snapshot, &cworld.inner, &map); // ← one call applies
        poll.flushAll(client_ep, &ctx, &scratch, now);
        poll.recvAll(server_ep, &stx, &scratch, now);
        now += 5;
    }

    const ce = map.get(e.idx).?;
    try testing.expectEqual(game.world.get(e, HPos).?.x, cworld.inner.get(ce, HPos).?.x); // converged
    try testing.expectEqual(@as(i32, 3), cworld.inner.get(ce, HVel).?.x);
}

test "typed Host/ClientHost factories drive replication with concrete-typed methods" {
    const alloc = testing.allocator;
    const link = try alloc.create(sim.DefaultLink);
    defer alloc.destroy(link);
    link.* = .{ .params = .{ .latency_ms = 20, .loss_permille = 100, .seed = 9 }, .prng = std.Random.DefaultPrng.init(9) };
    const sep = try alloc.create(HEp);
    defer alloc.destroy(sep);
    sep.* = .{};
    const cep = try alloc.create(HEp);
    defer alloc.destroy(cep);
    cep.* = .{};
    const server_addr: u64 = 2;
    const client_addr: u64 = 1;
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var sh = Host(HEp, HGame){ .ep = sep }; // typed: methods take concrete EpT/EngT
    var ch_host = ClientHost(HEp, HGame){ .ep = cep };

    const e = sh.server.world.spawn().?;
    sh.server.world.set(e, HPos, .{ .x = 0, .y = 0 });
    sh.server.world.set(e, HVel, .{ .x = 2, .y = 0 });
    try cep.sendRawTo(server_addr, .snap, "hi"); // create the server-side slot

    const Vis = struct {
        e: HGame.Entity,
        pub fn visible(self: *@This(), addr: u64, out: []HGame.Entity) []const HGame.Entity {
            _ = addr;
            out[0] = self.e;
            return out[0..1];
        }
    };
    var vis = Vis{ .e = e };
    var scratch: [256]u8 = undefined;
    var now: i64 = 0;
    var tick: usize = 0;
    while (tick < 400) : (tick += 1) {
        if (tick < 200) {
            sh.advance();
            sh.replicate(.snap, 200, &vis);
        }
        poll.flushAll(sep, &stx, &scratch, now);
        poll.recvAll(cep, &ctx, &scratch, now);
        _ = ch_host.apply(server_addr, .snap);
        poll.flushAll(cep, &ctx, &scratch, now);
        poll.recvAll(sep, &stx, &scratch, now);
        now += 5;
    }
    const le = ch_host.local(e.idx).?;
    try testing.expectEqual(sh.server.world.get(e, HPos).?.x, ch_host.get(le, HPos).?.x);
}
