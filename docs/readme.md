# magnet

A generic, zero-allocation UDP game-networking stack in Zig. Reliable channels, real
congestion control, optional encryption, a derived bit-level serializer, and a complete
client-prediction / rollback replication layer - all monomorphized from one comptime
`Config`, and all sans-IO (the protocol never touches a socket, clock, or allocator).

```zig
const magnet = @import("magnet");

const Schema = magnet.proto.channels(.{
    .chat = .{ .mode = .reliable_ordered, .Message = []const u8 },
});
const Server = magnet.Endpoint(.{ .channels = Schema, .protocol_id = 0x1234 });
```

## Where do you stop?

magnet is six layers, and you take only what you need:

| Stop at | You get | Add |
|---|---|---|
| **L3** | secure-optional reliable UDP with typed channels | - |
| **L4** | …plus a comptime, bit-level serializer | `.Message` types |
| **L5** | …plus prediction, rollback, interpolation, interest, lag-comp | `magnet.replication` |

Unused machinery is *compiled out*, not skipped - an unreliable channel carries no
retransmit state; `replication = null` links none of L5; `security.mode = .none` links
no crypto.

## Start here

- **[getting-started](getting-started.md)** - a working client + server from zero.
- **[concepts/sans-io](concepts/sans-io.md)** - the one idea everything rests on.

## Guides (one per layer)

- [config](guide/config.md) - the comptime spine, every knob.
- [channels](guide/channels.md) - the reliability taxonomy.
- [serialization](guide/serialization.md) - the derived serializer + quantization.
- [delivery](guide/delivery.md) - acks, loss, congestion control, fragmentation.
- [security](guide/security.md) - AEAD, tokens, certs, migration.
- [runtime](guide/runtime.md) - drivers, the `std.Io` seam, the simulator.
- [replication](guide/replication.md) - the world-sync engine.
- [observability](guide/observability.md) - tracers, stats, record/replay.

## Recipes (genre = config)

[fps](recipes/fps.md) · [rts / lockstep](recipes/rts.md) · [mmo](recipes/mmo.md) ·
[p2p rollback](recipes/p2p.md) · [co-op](recipes/coop.md)

## Concepts

[sans-io](concepts/sans-io.md) · [comptime](concepts/comptime.md) ·
[layering](concepts/layering.md) · [wire format](concepts/wire-format.md) ·
[security model](concepts/security-model.md)

## Reference

[config fields](reference/config.md) · [errors](reference/errors.md) ·
API docs: `zig build docs` → `zig-out/docs/`.

## Examples

Every guide links a runnable example in [`../examples/`](../examples). Build them all
with `zig build examples`, run one with `zig build run-<name>` (e.g. `zig build run-fps`).
