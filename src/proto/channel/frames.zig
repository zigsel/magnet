//! Wire frame types + the CID flag bit for the session datagram format. Constants only;
//! the (de)serialization stays in `session.zig` (it is interleaved with the transport state
//! machine). Public header: `[flags:u8][cid:8 if flags&0x40][pn:1–4 B truncated]`
//! (flags bits0-1 = pn_len-1; bit5 = unconnected [endpoint]; bit6 = has-CID; bit7 = handshake).
//! Frame types live in the (AEAD-sealed when `.aead`) payload, parsed until end:
//!   data 0 · ack 2 · path_challenge 3 · path_response 4 · fragment 5 · ping 6 · pong 7 ·
//!   nak 8 · disconnect 9.

pub const data: u8 = 0;
pub const ack: u8 = 2;
pub const path_challenge: u8 = 3;
pub const path_response: u8 = 4;
pub const fragment: u8 = 5;
pub const ping: u8 = 6;
pub const pong: u8 = 7;
pub const nak: u8 = 8;
pub const disconnect: u8 = 9;
/// Padding: the rest of the datagram is ignored. Used to inflate a PMTUD probe to a
/// candidate size (`mtu.zig`) without carrying real frames past it.
pub const padding: u8 = 10;

/// Public-header flag bit: a connection id follows the flags byte.
pub const has_cid_bit: u8 = 0x40;
