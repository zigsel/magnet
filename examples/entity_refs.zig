//! entity_refs - a replicated component can point at another entity. The reference
//! travels as a stable network id and resolves, on the receiver, to *its own* local
//! entity for that id - so cross-entity links survive the trip between worlds.

const std = @import("std");
const magnet = @import("magnet");
const repl = magnet.replication;

const Pos = struct { x: i16, y: i16 };
const Turret = struct { aiming_at: repl.EntityRef };

const Reg = repl.registry(.{ .components = .{ Pos, Turret } });
const World = repl.World(Reg, 32);
const Snapshot = repl.Snapshot(Reg, World);
const Map = repl.EntityMap(World.Entity, 32);

pub fn main() void {
    var server = World{};
    var baseline = World{};

    const tank = server.spawn().?;
    server.set(tank, Pos, .{ .x = 40, .y = 0 });
    const turret = server.spawn().?;
    server.set(turret, Turret, .{ .aiming_at = repl.EntityRef.of(tank) }); // points at the tank

    var buf: [128]u8 = undefined;
    const n = Snapshot.write(&server, &baseline, &.{ tank, turret }, 128, &buf);

    var client = World{};
    var map = Map{};
    Snapshot.apply(&client, &map, buf[0..n]);

    // on the client, resolve the turret's reference back to the client's local tank.
    const local_turret = map.get(turret.idx).?;
    const ref = client.get(local_turret, Turret).?.aiming_at;
    const local_tank = map.resolve(ref).?;

    std.debug.print("entity_refs: the turret aims at the tank at ({d},{d}) - link resolved cross-world\n", .{
        client.get(local_tank, Pos).?.x, client.get(local_tank, Pos).?.y,
    });
}
