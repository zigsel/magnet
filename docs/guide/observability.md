# Observability

A comptime `Tracer` type is called at every interesting event - and the default `trace.Null`
optimizes away to nothing (zero-sized, zero cost). Opt into telemetry by setting
`Config.tracer`.

```zig
const Cfg = magnet.Config{
    .channels = Schema,
    .tracer = magnet.trace.Multi(magnet.trace.Counters, magnet.trace.Log(64)),
};
```

`Multi(A, B)` fans every hook out to both - here a counter and a 64-event ring.

## Hooks

A tracer declares the hooks it cares about: `onPacketSent` / `onPacketRecv` / `onAck` /
`onLoss` / `onCongestion` / `onRttUpdate` / `onDrop` / `onRetransmit` / `onCwnd` /
`onHandshake` (and `onRollback` on the engine). The shipped tracers:

- `trace.Null` - the no-op default.
- `trace.Counters` - running totals (`packets_sent`, `losses`, `retransmits`, …).
- `trace.Log(cap)` - a bounded ring of recent structured events.
- `trace.Multi(A, B)` - compose two (nest for more).

Write your own by declaring the hooks; `trace.assertTracer(T)` gives a clear error if one's
missing.

## Live stats

`session.stats()` (or `endpoint.stats(addr)`) is a snapshot - rtt, cwnd, in-flight,
congestion events - with a one-line dashboard formatter:

```zig
var line: [128]u8 = undefined;
std.debug.print("{s}\n", .{session.stats().line(&line)});
// rtt=116ms±10 cwnd=2523B inflight=160B cong=4 up=true
```

## Record / replay

`runtime.record` captures every datagram (`Recorder`) into a caller buffer and replays it
(`Replayer`) into a fresh endpoint - for offline debugging and asserting identical transmit
intents across runs (the determinism guarantee in action).

Runnable: [`examples/observability.zig`](../../examples/observability.zig).
