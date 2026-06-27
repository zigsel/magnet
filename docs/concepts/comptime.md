# Comptime monomorphization

magnet specializes itself at compile time from one `Config`. There are no vtables, no
`dyn` dispatch, no runtime feature flags on the hot path - the machinery you don't use is
*compiled out*, and the machinery you do use is inlined for your exact types.

## À-la-carte, by construction

- An `unreliable` channel has **no** retransmit window, dedup, or reorder buffer - the
  receiver type for that mode is literally zero-sized.
- `security.mode = .none` compiles away every crypto/handshake/replay field and branch;
  the transport is byte-identical to a build with no security code at all.
- `replication = null` links none of L5.
- The congestion controller is a comptime *type* (`Config.congestion`), selected with no
  indirect call.

## The zero-cost tracer

Observability is a comptime `Tracer` type whose methods the transport calls at every
event. The default `trace.Null` has empty bodies - they optimize to nothing, and the
tracer is zero-sized:

```zig
comptime std.debug.assert(@sizeOf(magnet.trace.Null) == 0);
```

Swap in `trace.Counters` (or your own) only when you want telemetry; you pay exactly for
what you ask for.

## Derived, not hand-written

The serializer walks your types with `@typeInfo`, so plain data needs no serde code at
all. Channel and component sets are iterated with `inline for` over comptime tuples, so
the per-channel / per-component dispatch is unrolled and type-checked.

The upshot: the public API is generic (`send(comptime ch, value)`), but every call site
resolves to concrete, specialized code - the ergonomics of a dynamic library with the
output of a hand-written one.

See also: [config](../guide/config.md), [serialization](../guide/serialization.md).
