# Recipe: competitive FPS

Server-authoritative with client-side prediction of the local avatar, snapshot
interpolation for everyone else, and lag compensation so shots register against what the
shooter saw.

```zig
const Game = magnet.replication.engine(.{
    .components = .{ Transform, Velocity, Health },
    .Input = Input,
    .step = step,
    .tick_hz = 64,
});
// spawnOwned → predicted + input-controlled; spawnInterpolated → smooth remotes.
```

- **Input** on a sequenced-unreliable channel with redundant last-N-tick sends - survives
  loss without retransmit latency.
- **Snapshots** delta vs the client's last-acked baseline, interest-filtered.
- **Prediction + reconcile** via `Game.Client` (rollback + replay on a misprediction).
- **Lag compensation** via `LagComp.rewindRaycast` from the shooter's view-tick.
- **Encryption** on (`security.mode = .aead`), `congestion = cc.Reno`.

Runnable: [`examples/fps.zig`](../../examples/fps.zig).
