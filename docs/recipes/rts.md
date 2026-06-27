# Recipe: RTS / lockstep

Deterministic command-frame netcode. Only inputs cross the wire; every peer advances the
same fixed-point simulation once all inputs for a tick have arrived - so every machine
computes an identical world with no per-entity state replication.

```zig
const Lockstep = magnet.replication.Lockstep(State, Input, step, n_peers, cap);

ls.submit(peer, tick, input);  // reliable-ordered inputs from each peer
_ = ls.advanceAll();           // steps every tick whose inputs are all present
```

- Determinism is a hard requirement, so `step` uses fixed-point math
  (`magnet.core.Fixed`) - never `f64`.
- Latency shows up as input delay (you wait for the slowest peer), which is why RTS uses a
  generous delay. Tick 10–30 Hz.
- Inputs on a reliable-ordered channel; no snapshots, no prediction.

Runnable: [`examples/lockstep_rts.zig`](../../examples/lockstep_rts.zig).
