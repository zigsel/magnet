# magnet

**A generic, zero-allocation UDP game-networking stack in Zig.**

Reliable channels, real congestion control, optional encryption, a compile-time bit-level
serializer, and a complete client-prediction / rollback replication layer - all
monomorphized from one `comptime Config`, and all *sans-IO*: the protocol never touches a
socket, a clock, or an allocator.

```zig
const magnet = @import("magnet");

const Update = union(enum) {
    spawn:  struct { id: u32, x: i16, y: i16 },
    damage: struct { id: u32, hp: i16 },
    chat:   magnet.wire.Bounded(u8, 64),
};
const Move = struct { dx: i8, dy: i8 };

const Schema = magnet.proto.channels(.{
    .updates = .{ .mode = .reliable_ordered,     .Message = Update },
    .moves   = .{ .mode = .unreliable_sequenced, .Message = Move },
});

const Cfg = magnet.Config{ .channels = Schema, .protocol_id = 0= .aead } };
const Endpoint = magnet.Endpoint(Cfg);

try server.sendTo(client, .updates, .{ .chat = .fromSlice("gg") });

var it = server.receive(.moves);
while (it.next()) |r| applyMove(r.addr, r.msg);
```

---

## Why magnet

- **Zero steady-state allocation.** Every ring, pool, and buffer is sized from the comptime
  config and allocated once. After init the hot path never sees an allocator; pool
  exhaustion is a defined, observable event, never a crash.
- **Pay only for what you use.** Comptime monomorphization compiles *out* the machinery you
  don't enable - an unreliable channel carries no retransmit state, `security.mode = .none`
  links no crypto, `replication = null` links none of L5.
- **Sans-IO.** The core is a pure `feed` / `pollTransmit` / `pollDeadline` state machine, so
  it runs single-threaded, sharded, fiber-per-connection, or polled from a game loop -
  whichever driver you pick - and is fully deterministic-testable over a simulated link.
- **Genre-agnostic.** No `fps` / `rts` / `mmo` modules. Genres are *configuration* over the
  same generic systems.
- **std-only.** `std.crypto`, `std.Io`, `std.mem`. No libsodium, no third-party
  dependencies.

## The stack

Six layers; take only what you need (unused layers are never linked):

```
L5  replication/   snapshots · prediction · rollback · interpolation · interest · lag-comp
L4  wire/          @typeInfo serde · bitpack · quantize · delta
L3  proto/channel/ reliability taxonomy · ordering streams · WFQ scheduler · packer
L2  proto/delivery/ packet numbers · ack-ranges · RACK · RTT/PTO · congestion · fragmentation
L1  proto/conn/    handshake · tokens · AEAD · replay · connection IDs · migration
L0  runtime/       std.Io drivers (poll · reactor · sharded · task) · network simulator
        core/      SequenceBuffer · seq · pool · ring · bitset · fixed
```

- **Stop at L3** for secure-optional reliable UDP with typed channels.
- **Stop at L4** to also get a comptime, bit-level serializer.
- **Go to L5** for the full prediction / rollback / interest machinery.

## Features

- Six reliability modes per channel, with independent ordering streams (no head-of-line
  blocking) and a weighted-fair scheduler.
- Decoupled packet numbers, RLE ack-ranges, RACK loss detection, integer RTT/PTO, and four
  pluggable congestion controllers (NewReno · CUBIC · BBR · Fixed) - all integer/fixed-point.
- Message fragmentation, path-MTU discovery, token-bucket pacing.
- AEAD encryption with a stateless SipHash challenge, sliding replay window, 3×
  anti-amplification, connect tokens, Ed25519 cert identity, and connection-ID migration.
- A `@typeInfo`-derived serializer (plain data needs no serde code), with quantization and
  bounded slices.
- L5: server-authoritative replication, client prediction + whole-world rollback, snapshot
  interpolation, rooms + spatial-grid interest, replication priority, lag compensation,
  client authority + transfer, lockstep and P2P-rollback authority, ICE-lite NAT punch.
- Real `std.Io` socket drivers plus a Linux backend (`sendmmsg`/`recvmmsg`, GSO/GRO), and a
  seeded deterministic network simulator for tests.
- A comptime, zero-cost tracer; live `stats()`; record/replay.

## Quick start

```sh
zig build test       # unit + integration + conformance + fuzz/soak
zig build examples   # build every example
zig build run-fps    # run one (try: echo, channels, encrypted, replicate, lockstep_rts …)
zig build bench      # perf benchmarks (ReleaseFast)
zig build docs       # API docs → zig-out/docs/
```

Requires Zig **0.16**.

## Documentation

Start with **[docs/readme.md](docs/readme.md)** and
**[docs/getting-started.md](docs/getting-started.md)**. There's a guide per layer, genre
recipes, concept explainers (sans-IO, comptime, the wire format, the security model), and a
config/error reference. Every guide links a runnable example in [`examples/`](examples).

## Status

Implemented across all six layers and hardened (fuzz, soak, golden conformance vectors,
zero-allocation proof, cross-driver equivalence; The remaining release step is
freezing the v1 wire format and tagging.

## Acknowledgements

magnet stands on a deep reading of the field. It fuses the classic game lineage's zero-alloc
data structures with QUIC's delivery engine, and owns the replication core lightyear charts -
all re-expressed through Zig's `comptime` and `std.Io`. With thanks to:

- **[reliable.io / netcode.io / yojimbo](https://github.com/networkprotocol)** (Glenn Fiedler)
  - the `SequenceBuffer`, redundant ack bitfield, stateless AEAD connect-token handshake, the
  unified bitpacked serializer, and the packet→message ack bridge.
- **[RakNet](https://github.com/facebookarchive/RakNet)** - the reliability taxonomy,
  independent ordering streams, the ordered+sequenced blend, DF-probe MTU discovery, and
  refcounted fragments.
- **[Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets)** -
  WFQ lanes, the packet-number-derived AEAD nonce, the SipHash SYN-cookie, token-bucket
  pacing, and the HKDF key schedule.
- **[quinn / QUIC](https://github.com/quinn-rs/quinn)** (RFC 9000/9002) - decoupled packet
  numbers, ack-ranges, RACK, the RTT/PTO estimator, the pluggable `Controller`, NAT-rebind
  migration and anti-amplification, and the sans-IO architecture itself.
- **[laminar](https://github.com/TimonPost/laminar)** - clean module boundaries and the
  injectable-transport test seam.
- **[Bevy lightyear](https://github.com/cBournhonesque/lightyear)** - the entire L5 toolkit:
  prediction, rollback, interpolation, input handling, interest management, priority,
  tick-sync, and prespawn reconciliation.

Standards: QUIC loss/recovery (RFC 9000, 9002), CUBIC (RFC 8312), ICE (RFC 8445), and serial
number arithmetic (RFC 1982).

The borrowed ideas are theirs; the bugs are ours.
