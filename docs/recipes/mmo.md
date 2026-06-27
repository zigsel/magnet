# Recipe: MMO / large world

Server-authoritative with aggressive interest management and little or no prediction for
most entities - bandwidth, not latency, is the constraint.

```zig
// area-of-interest grid: a client only receives entities near it
const Grid = magnet.replication.interest.Grid(.{
    .dims = 2, .cell = 32, .layout = .sparse, .max_entities = 100_000,
});
grid.rebuild(&items);                       // once per tick, O(n)
const n = grid.collectNear(viewer, 2, &out); // O(neighbours), not O(world)
```

- **Interest** = rooms (bitset overlap) and/or the spatial grid; only visible entities
  enter a client's replication set.
- **Priority + budget** (`Priority`) decides what to send within a per-tick byte cap -
  far/idle entities update less often, near/important ones more, for free.
- **Interpolation** for remotes; prediction only for the local avatar if at all.
- Scale connections with the `sharded` runtime. Tick 10–20 Hz.

The sparse grid costs memory proportional to entities, not world volume, so a huge map is
fine.

Runnable: [`examples/mmo_interest.zig`](../../examples/mmo_interest.zig).
