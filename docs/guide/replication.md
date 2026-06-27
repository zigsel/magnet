# Replication

L5 turns the transport into a world-sync engine. You write **one** deterministic
`step(world, dt)`; magnet runs it server-authoritative, client-predicted, and during
rollback - consistent by construction.

```zig
fn step(world: anytype, dt: f32) void {
    var it = world.query(.{ Pos, Vel });
    while (it.next()) |e| world.get(e, Pos).?.x += world.get(e, Vel).?.x;
}
const Game = magnet.replication.engine(.{
    .components = .{ Pos, Vel },
    .Input = Cmd,
    .step = step,
    .max_entities = 64,
});
```

## Server and client

- `Game.Server` simulates the whole world (`advance()`) and writes per-client delta
  snapshots (`snapshotFor`).
- `Game.Client` predicts owned entities immediately (`predict(input)`) and reconciles
  against the authoritative world by rolling back and replaying (`reconcile(auth, tick)`).

Per-entity **roles** scope the work: `spawnOwned` (predicted + input), `spawnPredicted`,
`spawnInterpolated` (smooth remote), or plain `spawn` (replicated only). Rollback storage is
a comptime-pluggable backend (`Dense` / `Scoped` / `Sparse`).

## Over the wire, in one call

The `host` bridge ties the engine to an `Endpoint`:

```zig
var server = magnet.host.Host(Endpoint, Game){ .ep = server_ep };
server.advance();
server.replicate(.snapshots, budget, &visibility); // delta-snapshot every client

var client = magnet.host.ClientHost(Endpoint, Game){ .ep = client_ep };
_ = client.apply(server_addr, .snapshots);          // apply incoming snapshots
```

## The toolkit

| System | Type |
|---|---|
| Snapshot interpolation (smooth remotes) | `Interpolator` |
| Input buffering + redundant sends | `InputBuffer` |
| Interest: rooms / spatial AoI grid | `interest.Rooms` / `interest.Grid` |
| Replication priority + byte budget | `Priority` |
| Lag compensation ("favor the shooter") | `LagComp` |
| Lockstep / P2P-rollback authority | `Lockstep` / `P2p` |
| Client authority + transfer | `replication.auth` |
| Entity references inside components | `EntityRef` |

Each is generic, zero-alloc, and usable standalone. The [recipes](../readme.md#recipes)
show genre-specific configurations.

Runnable: [`examples/replicate.zig`](../../examples/replicate.zig),
[`fps.zig`](../../examples/fps.zig), [`mmo_interest.zig`](../../examples/mmo_interest.zig),
[`client_authority.zig`](../../examples/client_authority.zig).
