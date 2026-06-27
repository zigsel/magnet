# Layering

magnet is six layers. Imports go strictly downward, and **nothing imports the runtime** -
that's what makes the concurrency model a free choice (see [sans-io](sans-io.md)).

```
L5  replication/   snapshots · prediction · rollback · interpolation · interest · lag-comp
L4  wire/          @typeInfo serde · bitpack · quantize · delta
L3  proto/channel/ reliability taxonomy · ordering streams · WFQ scheduler · packer
L2  proto/delivery/ packet numbers · ack-ranges · RACK · RTT/PTO · congestion · fragmentation
L1  proto/conn/    handshake · tokens · AEAD · replay · connection IDs · migration
L0  runtime/       std.Io drivers (poll/reactor/sharded/task) · the simulator
        core/      SequenceBuffer · seq · pool · ring · bitset · fixed   (no deps)
```

`replication → wire → proto → core`; `runtime → {proto, wire, core}`; nothing → `runtime`.
The `enforce` build step checks this mechanically.

## Stopping points

You don't have to climb the whole stack:

- **Stop at L3** - secure-optional reliable UDP with typed channels. "Modern laminar."
- **Stop at L4** - also a comptime, bit-level serializer for your message types.
- **Go to L5** - prediction, rollback, interpolation, interest, lag-comp: the machinery a
  fast authoritative game needs, composed from generic systems.

You can also use a layer *standalone*: the [serializer](../guide/serialization.md) needs no
networking; the [interest grid](../guide/replication.md#interest) is just a spatial query.

## The keystone

The single load-bearing decision is at L2: **transmit-sequence ≠ data-sequence**. Packet
numbers are monotonic and transmit-only (a retransmit gets a *new* number), while ordering
runs on separate per-channel data sequences. This removes all "is this ack for the original
or the resend?" ambiguity, enables RACK loss detection, and yields the completeness signal
L5's rollback consumes. Its only cost is a small packet→message bridge.
