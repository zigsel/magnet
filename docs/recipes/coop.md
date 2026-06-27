# Recipe: co-op / casual

Server-authoritative, light prediction for the local avatar, relaxed interest, reliable
channels for world events. The gentlest configuration - most of L5 is optional.

```zig
const Game = magnet.replication.engine(.{
    .components = .{ Transform, Health, Inventory },
    .Input = Input,
    .step = step,
    .tick_hz = 30,
});
```

- **Prediction** only for the player's own avatar; everything else interpolated.
- **Interest** can often be "everything" for a small session - skip the grid.
- **World events** (pickups, doors, score) on a `reliable_ordered` channel.
- Encryption optional; a pre-shared key is usually enough for friends-and-family hosting.

If you don't need rollback at all, you can stop at L3/L4 and just use reliable channels +
the serializer - see [layering](../concepts/layering.md#stopping-points).
