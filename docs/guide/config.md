# Config - the comptime spine

Every public type is `Thing(comptime cfg: Config)` and sizes itself from that one value.
Defaults are sensible; in practice you set `channels` and a few knobs.

```zig
const Cfg = magnet.Config{
    .channels = Schema,              // required - from magnet.proto.channels(.{…})
    .protocol_id = 0x1234,           // wire-compat gate (mismatch = silent drop)
    .congestion = null,              // null = NewReno; or proto.delivery.cc.{Cubic,Bbr,Fixed}
    .tracer = magnet.trace.Null,     // observability (zero cost by default)
    .security = .{ .mode = .none },  // .aead to encrypt
    .limits = .{},                   // ring/pool sizes (below)
    .delivery = .{},                 // acks / loss / fragmentation knobs
    .mtu = 1200,
    .enable_pmtud = false,
};
```

## Limits - what gets sized

These become comptime constants that size the rings and pools (zero allocation after init):

| Field | Default | Sizes |
|---|---|---|
| `max_connections` | 64 | the endpoint's connection table |
| `channel_cap` | 128 | per-channel reorder/dedup + reliable send window |
| `bridge_cap` | 1024 | packet→message map (the in-flight window) |
| `recvpn_cap` | 256 | received-pn window for ack generation |
| `max_payload` | 256 | largest single serialized message |
| `max_msgs_pkt` | 16 | reliable messages packed per datagram |
| `unconnected_cap` | 0 | connectionless queues (0 = feature off) |

## Sequence widths

`seq.packet_number` (default `u32`) and `seq.data_sequence` (`u16`) are comptime-chosen per
domain; one shared wrapping-compare helper handles all of them.

## Endpoint vs Session

- `magnet.proto.Session(cfg)` is one connection. Drive it with `feed` / `pollTransmit`.
- `magnet.Endpoint(cfg)` is a table of sessions demuxed by peer address - a server. It adds
  `sendTo` / `receiveFrom` / `broadcast` / `connectTo` and per-address routing.
- `magnet.open(cfg, allocator)` heap-allocates an Endpoint once (the hot path still never
  allocates); `magnet.close` frees it.

Full field table: [reference/config](../reference/config.md).
