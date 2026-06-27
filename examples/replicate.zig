//! replicate - server-authoritative world sync. You write one deterministic `step`; the
//! server simulates and the `host` bridge streams per-client delta snapshots over a
//! channel. The client applies them into its own world. Only what changed is sent.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const poll = magnet.runtime.poll;

const Pos = struct { x: i32, y: i32 };
const Vel = struct { x: i32, y: i32 };
fn step(world: anytype, dt: f32) void {
    _ = dt;
    var it = world.query(.{ Pos, Vel });
    while (it.next()) |e| world.get(e, Pos).?.x += world.get(e, Vel).?.x;
}
const Game = magnet.replication.engine(.{ .components = .{ Pos, Vel }, .max_entities = 32, .max_clients = 4, .step = step });

const Schema = magnet.proto.channels(.{ .snap = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = magnet.Config{ .channels = Schema };
const Endpoint = magnet.Endpoint(Cfg);
const client_addr = 1;
const server_addr = 2;

// the client's interest set: which entities it should receive (here, all of them).
const AllVisible = struct {
    list: []const Game.Entity,
    pub fn visible(self: *@This(), addr: u64, out: []Game.Entity) []const Game.Entity {
        _ = addr;
        @memcpy(out[0..self.list.len], self.list);
        return out[0..self.list.len];
    }
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const link = try gpa.create(sim.DefaultLink);
    defer gpa.destroy(link);
    link.* = sim.DefaultLink.init(.{ .latency_ms = 30, .loss_permille = 100, .seed = 1 });
    const sep = try gpa.create(Endpoint);
    defer gpa.destroy(sep);
    sep.* = .{};
    const cep = try gpa.create(Endpoint);
    defer gpa.destroy(cep);
    cep.* = .{};

    var host = magnet.host.Host(Endpoint, Game){ .ep = sep };
    var client = magnet.host.ClientHost(Endpoint, Game){ .ep = cep };

    const ball = host.server.world.spawn().?;
    host.server.world.set(ball, Pos, .{ .x = 0, .y = 0 });
    host.server.world.set(ball, Vel, .{ .x = 3, .y = 0 });
    var vis = AllVisible{ .list = &.{ball} };

    cep.sendRawTo(server_addr, .snap, "hello") catch {}; // open the connection

    var to_srv: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var to_cli: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [256]u8 = undefined;
    var now: i64 = 0;
    var tick: usize = 0;
    while (tick < 200) : (tick += 1) {
        if (tick < 100) {
            host.advance(); // authoritative tick
            host.replicate(.snap, 200, &vis); // one call: per-client delta snapshots
        }
        poll.flushAll(sep, &to_cli, &scratch, now);
        poll.recvAll(cep, &to_srv, &scratch, now);
        _ = client.apply(server_addr, .snap); // one call: apply incoming snapshots
        poll.flushAll(cep, &to_srv, &scratch, now);
        poll.recvAll(sep, &to_cli, &scratch, now);
        now += 5;
    }

    const local = client.local(ball.idx).?;
    std.debug.print("replicate: server ball at x={d}, client converged to x={d}\n", .{
        host.server.world.get(ball, Pos).?.x, client.get(local, Pos).?.x,
    });
}
