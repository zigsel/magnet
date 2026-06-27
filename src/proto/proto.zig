//! `proto` module barrel - sans-IO protocol core (conn · delivery · channel +
//! the Endpoint table). The module root: imported by name (`@import("proto")`); it
//! **cannot** import `runtime`/`replication` (the module graph forbids it). Deps: core,
//! wire, config, trace.

pub const endpoint = @import("endpoint.zig");
pub const Endpoint = endpoint.Endpoint;
pub const session = @import("channel/session.zig");
pub const Session = session.Session;
pub const schema = @import("channel/schema.zig");
pub const channels = schema.channels;
/// Ordered+sequenced single-stream blend (RakNet two-level key). A standalone primitive
/// you drive over one reliable channel - not a `channels(.{...})` mode. See `blend.zig`.
pub const blend = @import("channel/blend.zig");
pub const BlendReceiver = blend.BlendReceiver;

/// Security primitives (engaged when `Config.security.mode = .aead`).
pub const conn = struct {
    pub const crypto = @import("conn/crypto.zig");
    pub const Aead = crypto.Aead;
    pub const replay = @import("conn/replay.zig");
    pub const Replay = replay.Replay;
    pub const challenge = @import("conn/challenge.zig");
    pub const Challenger = challenge.Challenger;
    pub const token = @import("conn/token.zig");
    pub const handshake = @import("conn/handshake.zig");
    pub const cid = @import("conn/cid.zig");
    pub const identity = @import("conn/identity.zig");
    pub const ice = @import("conn/ice.zig");
};

/// Delivery primitives.
pub const delivery = struct {
    pub const ack = @import("delivery/ack.zig");
    pub const ackbits = @import("delivery/ackbits.zig");
    pub const loss = @import("delivery/loss.zig");
    pub const rtt = @import("delivery/rtt.zig");
    pub const frag = @import("delivery/frag.zig");
    pub const mtu = @import("delivery/mtu.zig");
    pub const pacing = @import("delivery/pacing.zig");
    pub const bandwidth = @import("delivery/bandwidth.zig");
    /// Pluggable congestion controllers (`Config.congestion = …`). All integer/fixed-point.
    pub const cc = struct {
        pub const Reno = @import("delivery/cc/reno.zig").Reno; // default (NewReno)
        pub const Fixed = @import("delivery/cc/fixed.zig").Fixed;
        pub const Cubic = @import("delivery/cc/cubic.zig").Cubic;
        pub const Bbr = @import("delivery/cc/bbr.zig").Bbr;
    };
};

test {
    _ = @import("endpoint.zig");
    _ = @import("channel/schema.zig");
    _ = @import("channel/block.zig");
    _ = @import("channel/packer.zig");
    _ = @import("channel/ordering.zig");
    _ = @import("channel/blend.zig");
    _ = @import("channel/scheduler.zig");
    _ = @import("channel/channel.zig");
    _ = @import("channel/bridge.zig");
    _ = @import("channel/session.zig");
    _ = @import("conn/crypto.zig");
    _ = @import("conn/replay.zig");
    _ = @import("conn/challenge.zig");
    _ = @import("conn/token.zig");
    _ = @import("conn/handshake.zig");
    _ = @import("conn/cid.zig");
    _ = @import("conn/identity.zig");
    _ = @import("conn/ice.zig");
    _ = @import("delivery/ack.zig");
    _ = @import("delivery/ackbits.zig");
    _ = @import("delivery/loss.zig");
    _ = @import("delivery/rtt.zig");
    _ = @import("delivery/pacing.zig");
    _ = @import("delivery/bandwidth.zig");
    _ = @import("delivery/frag.zig");
    _ = @import("delivery/mtu.zig");
    _ = @import("delivery/cc/controller.zig");
    _ = @import("delivery/cc/reno.zig");
    _ = @import("delivery/cc/fixed.zig");
    _ = @import("delivery/cc/cubic.zig");
    _ = @import("delivery/cc/bbr.zig");
}
