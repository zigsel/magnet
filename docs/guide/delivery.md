# Delivery

The L2 engine: packet numbers, acknowledgements, loss detection, RTT, congestion control,
pacing, and fragmentation. Most of it just works; here's what you can tune via
`Config.delivery` and `Config.congestion`.

## Acks & loss

Acks are run-length ranges (a lossless stream costs ~5 bytes). Loss is detected with RACK:
a packet is lost if it's `loss_packet_threshold` (default 3) behind the largest acked, or
older than `loss_time_num/loss_time_den × RTT` (default 9/8). A receiver also schedules a
fast-NAK after `nack_delay_ms` for sub-RTT retransmission. Spurious losses (a packet declared
lost then later acked) restore the congestion window.

## Congestion control

The controller is a comptime type - swap it and nothing else changes:

```zig
const Cfg = magnet.Config{ .channels = Schema, .congestion = magnet.proto.delivery.cc.Cubic };
```

| Controller | Notes |
|---|---|
| `cc.Reno` | NewReno, the default; slow-start + AIMD |
| `cc.Cubic` | CUBIC (RFC 8312), integer/fixed-point |
| `cc.Bbr` | BBR v1, models bandwidth × RTT, loss-agnostic |
| `cc.Fixed` | a constant window, for lab/deterministic use |

All are integer/fixed-point, so transport behaviour is reproducible and never affects
game-sim determinism. A token-bucket pacer smooths sends to the controller's rate.

## RTT & keepalive

`session.rttMs()`, `session.cwnd()`, `session.bytesInFlight()`, `session.congestionEvents()`
expose the live state. An idle connection sends a keepalive ping every `ping_interval_ms`
(also the RTT probe); `idle_timeout_ms` (0 = off) closes a peer that's gone silent.

## Fragmentation & large blobs

Opt in with `delivery.fragmentation = true`, then send a message larger than `max_payload`
over a reliable channel:

```zig
try session.sendBlock(.file, big_bytes);     // split into reliable fragments
if (session.receiveBlock(.file, &out)) |len| { … } // reassembled byte-exact
```

## Path MTU discovery

`enable_pmtud = true` makes the session probe larger datagram sizes (DF-padded) and raise
its budget when they're acked; `session.pathMtu()` reads the current value. `onBlackHole()`
falls back to the safe base if large packets suddenly fail.

Runnable: [`examples/congestion.zig`](../../examples/congestion.zig),
[`examples/big_transfer.zig`](../../examples/big_transfer.zig).
