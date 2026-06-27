//! The comptime `Config` - the spine of the library. Every public transport type
//! (`Session`, `Endpoint`) is `Thing(comptime cfg: Config)` and derives all of its
//! buffer sizes, channel set, congestion controller, and tracer from it. Lower-level
//! primitives stay parameterized by raw comptime values; `Config` is the top-level
//! knob that wires them together.

const std = @import("std");
const trace = @import("trace");
// NOTE: `config` deliberately imports nothing from `proto/` - it is the low-level spine.
// The default congestion controller is a `null` sentinel resolved in `Session` (which is
// where `proto/delivery/cc/` legitimately lives), so there is no `config ↔ proto` cycle.

/// Fixed sizing - all become comptime constants that size the rings/pools.
pub const Limits = struct {
    max_connections: u32 = 64,
    channel_cap: usize = 128, // per-channel reorder/dedup + reliable send window
    bridge_cap: usize = 1024, // packetSeq→messageId map (acks must survive until processed)
    recvpn_cap: usize = 256, // received-pn window for ack-range generation
    max_payload: usize = 256, // max serialized message size
    max_msgs_pkt: usize = 16, // reliable messages packed per datagram
    /// Connectionless (pre-connection) message queues: ring size each way. 0 = the
    /// feature compiles out. Must be a power of two when > 0. Enables `Endpoint`'s
    /// `sendUnconnected`/`receiveUnconnected` for discovery / server-info / NAT-punch.
    unconnected_cap: usize = 0,
};

/// Security. `mode = .none` compiles crypto out.
pub const Security = struct {
    mode: enum { none, aead } = .none,
    aead: enum { chacha20poly1305, aes256gcm } = .chacha20poly1305,
    replay_window: u32 = 1024,
    /// Require backend-signed connect tokens in the handshake (keys derive from the
    /// token instead of a raw pre-shared key). See `proto/conn/token.zig`.
    tokens: bool = false,
    /// Connection IDs + migration (a-la-carte; requires `mode = .aead`). Lets a
    /// connection survive NAT rebinding / IP change. See `proto/conn/cid.zig`.
    connection_ids: bool = false,
};

/// Delivery knobs (RACK / acks / PTO / fragmentation). All comptime.
pub const Delivery = struct {
    ack_blocks_max: usize = 16, // RLE ack-range blocks per ACK frame (fits an MTU)
    loss_packet_threshold: u16 = 3, // RACK packet threshold
    loss_time_num: i64 = 9, // RACK time threshold = num/den · max(smoothed, latest)
    loss_time_den: i64 = 8,
    nack_delay_ms: i64 = 3, // receiver fast-NAK delay (absorbs reorder)
    ping_interval_ms: i64 = 1000, // idle keepalive / RTT-probe cadence
    /// Close a connection that has received no datagram for this long (ms). 0 = off.
    /// Liveness is maintained by the keepalive ping, so this trips only on a dead peer.
    idle_timeout_ms: i64 = 0,
    reassembly_slots: usize = 4, // concurrent fragmented messages in flight
    max_fragments: usize = 64, // per message
    /// Enable fragmentation: messages larger than `max_payload` are split into
    /// reliable fragments and reassembled. Adds a per-session reassembly buffer
    /// (`max_payload × max_fragments`), so it is opt-in. `sendBlock`/`receiveBlock`.
    fragmentation: bool = false,
    /// Optimistic-ack defense: skip ~1/N outgoing PNs; an ack of a skipped PN is a
    /// protocol violation. 0 disables. (`PacketNumberFilter`.)
    pn_skip_period: u32 = 0,
};

/// Token-bucket pacing on the reliable send path.
pub const Pacing = struct {
    enabled: bool = true,
    burst_bytes: i64 = 16 * 1200,
};

/// Comptime-chosen wrap widths per domain.
pub const SeqWidths = struct {
    packet_number: type = u32, // transmit-order PN (wrapping-compared; far above the in-flight window)
    data_sequence: type = u16, // per-channel message numbers
};

/// What to do on pool exhaustion (pool exhaustion is observable, never a crash).
pub const Degrade = struct {
    on_send_queue_full: enum { backpressure, drop_oldest, drop_new } = .backpressure,
    on_reassembly_full: enum { drop, error_out } = .drop,
};

pub const Config = struct {
    /// Wire-compat gate (comptime). Mismatch ⇒ silently reject.
    protocol_id: u64 = 0,
    /// App-level version negotiated in the handshake (informational / feature flags).
    /// A server with a nonzero `app_version` rejects a client whose version differs;
    /// 0 accepts any. See the handshake hello.
    app_version: u32 = 0,
    /// The channel schema: result of `magnet.channels(.{…})`. Required.
    channels: type,
    /// Congestion controller type (comptime-pluggable). `null` ⇒ the default NewReno,
    /// resolved in `Session` (keeps `config` free of any `proto/` import).
    congestion: ?type = null,
    /// Observability tracer type. Default = zero-cost Null.
    tracer: type = trace.Null,
    /// Replication engine (`magnet.replication(.{…})`); null ⇒ no replication code linked.
    replication: ?type = null,
    limits: Limits = .{},
    security: Security = .{},
    delivery: Delivery = .{},
    seq: SeqWidths = .{},
    degrade: Degrade = .{},
    /// Conservative datagram budget (PMTUD may raise it up to `max_datagram`).
    mtu: u16 = 1200,
    max_datagram: u16 = 1400,
    enable_pmtud: bool = false,
    /// Token-bucket pacing on the reliable send path (bool kept for ergonomics;
    /// `pacing_opts` carries the burst tuning).
    pacing: bool = true,
    pacing_opts: Pacing = .{},
};
