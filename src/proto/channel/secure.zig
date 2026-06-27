//! Security overlay for `Session` - the per-connection AEAD/handshake state, split
//! out of the session state machine. `Session` embeds `SecState(cfg)` (compiled to a
//! zero-sized `void` when `security.mode = .none`) and drives the handshake/seal/open
//! around it; the *data* and the pure key-schedule pickers live here.

const crypto = @import("../conn/crypto.zig");
const handshake = @import("../conn/handshake.zig");
const replay = @import("../conn/replay.zig");
const cidmod = @import("../conn/cid.zig");
const token = @import("../conn/token.zig");
const Config = @import("config").Config;

/// The AEAD selected by `Config.security.aead`.
pub fn Aead(comptime cfg: Config) type {
    return crypto.Aead(@field(crypto.Which, @tagName(cfg.security.aead)));
}

/// Per-connection security state. `initiator` = the connecting (client) side, which
/// seals with the c2s material and opens with s2c.
pub fn SecState(comptime cfg: Config) type {
    const tokens_on = cfg.security.tokens;
    const TokenLen = token.Token.wire_len;
    return struct {
        const Self = @This();

        state: handshake.State = .idle,
        initiator: bool = false,
        keys: handshake.Keys = undefined,
        amp: handshake.Amplification = .{},
        rwin: replay.Replay(cfg.security.replay_window, cfg.seq.packet_number) = .{},
        echo: handshake.Cookie = .{ .coarse = 0, .cookie = 0 },
        force_keepalive: bool = false,
        hs_sent: bool = false, // a handshake datagram emitted this retransmit round
        hs_at: i64 = 0, // time of the last handshake emission
        // connection IDs + migration (only meaningful when `connection_ids`)
        local_cid: cidmod.Cid = cidmod.none, // peer addresses us by this
        remote_cid: cidmod.Cid = cidmod.none, // we stamp this on outgoing
        path: cidmod.PathValidator = .{},
        send_challenge: bool = false, // owe a PATH_CHALLENGE
        send_response: bool = false, // owe a PATH_RESPONSE
        path_token: u64 = 0,
        // connect token to echo in the response (client side), when tokens are on
        token_bytes: if (tokens_on) [TokenLen]u8 else void = undefined,

        // directional key/IV pickers (pure: chosen by `initiator`).
        pub fn sealKey(self: *const Self) [32]u8 {
            return if (self.initiator) self.keys.c2s_key else self.keys.s2c_key;
        }
        pub fn sealIv(self: *const Self) [12]u8 {
            return if (self.initiator) self.keys.c2s_iv else self.keys.s2c_iv;
        }
        pub fn openKey(self: *const Self) [32]u8 {
            return if (self.initiator) self.keys.s2c_key else self.keys.c2s_key;
        }
        pub fn openIv(self: *const Self) [12]u8 {
            return if (self.initiator) self.keys.s2c_iv else self.keys.c2s_iv;
        }
    };
}
