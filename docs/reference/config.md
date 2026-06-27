# Config reference

The exhaustive field table. Generated API docs (`zig build docs`) cover the methods; this
covers the comptime configuration. See the [config guide](../guide/config.md) for prose.

## `Config`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `protocol_id` | `u64` | `0` | wire-compat gate; mismatch = silent drop |
| `app_version` | `u32` | `0` | negotiated in the handshake (0 = accept any) |
| `channels` | `type` | - | result of `magnet.proto.channels(.{…})` (required) |
| `congestion` | `?type` | `null` | controller type; `null` → NewReno |
| `tracer` | `type` | `trace.Null` | observability tracer |
| `replication` | `?type` | `null` | L5 engine; `null` links no replication code |
| `limits` | `Limits` | `.{}` | ring/pool sizes |
| `security` | `Security` | `.{}` | encryption / handshake |
| `delivery` | `Delivery` | `.{}` | ack / loss / fragmentation knobs |
| `seq` | `SeqWidths` | `.{}` | wrap widths per domain |
| `degrade` | `Degrade` | `.{}` | pool-exhaustion policy |
| `mtu` | `u16` | `1200` | conservative datagram budget |
| `max_datagram` | `u16` | `1400` | hard cap (PMTUD may raise the working MTU to here) |
| `enable_pmtud` | `bool` | `false` | live path-MTU discovery |
| `pacing` | `bool` | `true` | token-bucket pacing on the reliable path |

## `Limits`

| Field | Default | Sizes |
|---|---|---|
| `max_connections` | `64` | endpoint connection table |
| `channel_cap` | `128` | per-channel reorder/dedup + reliable send window |
| `bridge_cap` | `1024` | packet→message map (in-flight window) |
| `recvpn_cap` | `256` | received-pn window for ack generation |
| `max_payload` | `256` | max single serialized message |
| `max_msgs_pkt` | `16` | reliable messages packed per datagram |
| `unconnected_cap` | `0` | connectionless queue size (0 = off; power of two when >0) |

## `Security`

| Field | Default | Meaning |
|---|---|---|
| `mode` | `.none` | `.aead` to encrypt |
| `aead` | `.chacha20poly1305` | or `.aes256gcm` |
| `replay_window` | `1024` | sliding replay window (bits) |
| `tokens` | `false` | require backend-signed connect tokens |
| `connection_ids` | `false` | connection IDs + migration (requires `.aead`) |

## `Delivery`

| Field | Default | Meaning |
|---|---|---|
| `ack_blocks_max` | `16` | RLE ack-range blocks per frame |
| `loss_packet_threshold` | `3` | RACK packet threshold |
| `loss_time_num` / `loss_time_den` | `9` / `8` | RACK time threshold = num/den × RTT |
| `nack_delay_ms` | `3` | receiver fast-NAK delay |
| `ping_interval_ms` | `1000` | idle keepalive / RTT cadence |
| `idle_timeout_ms` | `0` | close a silent peer (0 = off) |
| `reassembly_slots` | `4` | concurrent fragmented messages |
| `max_fragments` | `64` | fragments per message |
| `fragmentation` | `false` | enable `sendBlock` / `receiveBlock` |
| `pn_skip_period` | `0` | `PacketNumberFilter` (0 = off) |

## `SeqWidths`

| Field | Default | Domain |
|---|---|---|
| `packet_number` | `u32` | transmit-order packet number |
| `data_sequence` | `u16` | per-channel message number |

## `Degrade`

| Field | Default | On exhaustion |
|---|---|---|
| `on_send_queue_full` | `.backpressure` | `.backpressure` / `.drop_oldest` / `.drop_new` |
| `on_reassembly_full` | `.drop` | `.drop` / `.error_out` |
