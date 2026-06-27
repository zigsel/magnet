//! client_authority - by default the server owns every entity, but authority can be
//! handed to a client (a thrown grenade, a dropped item, a vehicle they're driving).
//! The owning client then simulates it and uploads its state; the server stores it and
//! re-shares it - and an upload for an entity the client does NOT own is rejected.

const std = @import("std");
const magnet = @import("magnet");
const auth = magnet.replication.auth;

const Pos = struct { x: i32, y: i32 };
const Vel = struct { x: i32, y: i32 };
fn step(world: anytype, dt: f32) void {
    _ = dt;
    var it = world.query(.{ Pos, Vel });
    while (it.next()) |e| world.get(e, Pos).?.x += world.get(e, Vel).?.x;
}
const Game = magnet.replication.engine(.{ .components = .{ Pos, Vel }, .max_entities = 32, .max_clients = 4, .step = step });

pub fn main() void {
    var server = Game.Server{};
    const npc = server.world.spawn().?; // server-owned
    server.world.set(npc, Pos, .{ .x = 0, .y = 0 });
    server.world.set(npc, Vel, .{ .x = 1, .y = 0 });
    const item = server.world.spawn().?; // about to be handed to the client
    server.world.set(item, Pos, .{ .x = 0, .y = 0 });
    server.world.set(item, Vel, .{ .x = 0, .y = 0 });

    const grant = server.transferAuthority(item, auth.client(0)); // hand `item` to client 0
    server.advance(); // the server steps the npc it owns, but NOT the client-owned item

    // client 0 owns `item`, drives it, and uploads its authoritative state.
    var client = Game.Client{};
    client.init();
    client.setClientId(0);
    client.onAuthorityGrant(grant);
    const local_item = Game.Entity{ .idx = item.idx, .gen = client.world.inner.gens[item.idx] };
    client.world.set(local_item, Pos, .{ .x = 99, .y = 0 });

    // it also tries to cheat - upload the npc it does not own.
    const fake_npc = client.world.inner.ensureSlot(npc.idx);
    client.world.setAuthority(fake_npc, client.world.local_owner);
    client.world.set(fake_npc, Pos, .{ .x = 666, .y = 0 });

    var baseline = @TypeOf(client.world.inner){};
    var buf: [256]u8 = undefined;
    const n = client.uploadOwned(&baseline, 256, &buf);
    server.applyClientUpload(0, buf[0..n]);

    std.debug.print("client_authority: client-owned item accepted → server x={d} (uploaded 99)\n", .{
        server.world.get(item, Pos).?.x,
    });
    std.debug.print("  cheat upload of the server-owned npc rejected → server x={d} (still 1)\n", .{
        server.world.get(npc, Pos).?.x,
    });
}
