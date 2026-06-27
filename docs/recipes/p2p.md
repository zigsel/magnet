# Recipe: P2P rollback (fighting / GGPO)

Peer-to-peer with no authoritative server. Each peer advances every tick on its own input
plus a prediction of the remote's, and rolls back + replays when the real remote input
arrives and differs.

```zig
const P2p = magnet.replication.P2p(State, Input, step, cap);

_ = peer.advance(local_input);             // predicts the remote, advances now
_ = peer.confirmRemote(tick, remote_input); // rolls back if the prediction was wrong
```

- Like lockstep, this needs **hard cross-machine determinism** - `step` in fixed-point.
- Unlike lockstep, it hides latency behind prediction instead of waiting for the peer.
- Small input delay; tick 60 Hz.

To establish the connection through NATs first, see `proto.conn.ice` + `host.pumpIce`
([nat_punch example](../../examples/nat_punch.zig)); P2p then runs over whatever transport
that yields. `P2p` is the simulation; ICE is the connectivity - they compose.

Runnable: [`examples/p2p_rollback.zig`](../../examples/p2p_rollback.zig).
