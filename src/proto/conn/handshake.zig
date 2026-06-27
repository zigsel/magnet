//! Handshake: the sans-IO state machine, key schedule, and anti-amplification
//! gate that sit in front of the delivery engine when `security.mode = .aead`.
//!
//! Wire (handshake datagrams are cleartext; flags bit7 = 1, low 2 bits = type):
//!   hello     → `[flags][protocol_id:u64]`
//!   challenge → `[flags][coarse:u32][cookie:u64]`     (server, stateless)
//!   response  → `[flags][coarse:u32][cookie:u64]`     (client echoes the cookie)
//! Data datagrams have bit7 = 0 and are AEAD-sealed (see `crypto.zig`).
//!
//! Keys are derived from a shared master secret (a pre-shared key, or the session
//! keys carried in a connect token) via HKDF-SHA256 into directional key+IV pairs,
//! so both ends compute the same `c2s`/`s2c` material with no key bytes on the wire.

const std = @import("std");
const cidmod = @import("cid.zig");
const tokenmod = @import("token.zig");

pub const hs_flag: u8 = 0x80; // bit7 marks a handshake datagram
pub const Type = enum(u2) { hello = 0, challenge = 1, response = 2 };

pub const State = enum { idle, hello_sent, challenged, response_sent, connected };

pub const Keys = struct {
    c2s_key: [32]u8,
    s2c_key: [32]u8,
    c2s_iv: [12]u8,
    s2c_iv: [12]u8,
};

/// Derive directional key+IV material from a 32-byte master secret + a salt
/// (e.g. the protocol id). Deterministic and identical on both ends.
pub fn derive(master: [32]u8, salt: []const u8) Keys {
    const H = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = H.extract(salt, &master);
    var k: Keys = undefined;
    H.expand(&k.c2s_key, "magnet c2s key", prk);
    H.expand(&k.s2c_key, "magnet s2c key", prk);
    H.expand(&k.c2s_iv, "magnet c2s iv", prk);
    H.expand(&k.s2c_iv, "magnet s2c iv", prk);
    return k;
}

/// 3× anti-amplification gate (QUIC): until the peer's address is validated, never
/// send more than 3× the bytes received on the path. Defeats spoofed-source
/// reflection. Two counters + one check; always on while unvalidated.
pub const Amplification = struct {
    recv_bytes: u64 = 0,
    sent_bytes: u64 = 0,
    validated: bool = false,

    pub fn onRecv(self: *Amplification, n: usize) void {
        self.recv_bytes += n;
    }
    pub fn onSent(self: *Amplification, n: usize) void {
        self.sent_bytes += n;
    }
    /// May we send `n` more bytes right now?
    pub fn canSend(self: *const Amplification, n: usize) bool {
        return self.validated or (self.sent_bytes + n <= self.recv_bytes * 3);
    }
    pub fn validate(self: *Amplification) void {
        self.validated = true;
    }
};

// ---- handshake datagram (de)serialization ----

pub fn writeHello(buf: []u8, protocol_id: u64, app_version: u32) usize {
    buf[0] = hs_flag | @intFromEnum(Type.hello);
    std.mem.writeInt(u64, buf[1..9], protocol_id, .little);
    std.mem.writeInt(u32, buf[9..13], app_version, .little);
    return 13;
}
pub fn readAppVersion(bytes: []const u8) ?u32 {
    if (bytes.len < 13) return null;
    return std.mem.readInt(u32, bytes[9..13], .little);
}

pub const Cookie = struct { coarse: u32, cookie: u64 };

fn writeCookie(buf: []u8, t: Type, c: Cookie) usize {
    buf[0] = hs_flag | @intFromEnum(t);
    std.mem.writeInt(u32, buf[1..5], c.coarse, .little);
    std.mem.writeInt(u64, buf[5..13], c.cookie, .little);
    return 13;
}
pub fn writeChallenge(buf: []u8, c: Cookie) usize {
    return writeCookie(buf, .challenge, c);
}
pub fn writeResponse(buf: []u8, c: Cookie) usize {
    return writeCookie(buf, .response, c);
}

pub fn typeOf(bytes: []const u8) ?Type {
    if (bytes.len < 1 or bytes[0] & hs_flag == 0) return null;
    return switch (@as(u2, @truncate(bytes[0]))) {
        0 => .hello,
        1 => .challenge,
        2 => .response,
        else => null,
    };
}
pub fn isHandshake(bytes: []const u8) bool {
    return bytes.len >= 1 and (bytes[0] & hs_flag) != 0;
}
pub fn readHello(bytes: []const u8) ?u64 {
    if (bytes.len < 9) return null;
    return std.mem.readInt(u64, bytes[1..9], .little);
}
pub fn readCookie(bytes: []const u8) ?Cookie {
    if (bytes.len < 13) return null;
    return .{
        .coarse = std.mem.readInt(u32, bytes[1..5], .little),
        .cookie = std.mem.readInt(u64, bytes[5..13], .little),
    };
}

// CID-carrying variants (used when `Security.connection_ids` is set): an 8-byte
// connection id is appended after the cookie. The challenge carries the server's
// local CID (so the client learns whom to address); the response carries the
// client's local CID (so the stateless server learns whom to address back).
pub fn writeChallengeCid(buf: []u8, c: Cookie, conn_id: cidmod.Cid) usize {
    const n = writeChallenge(buf, c);
    std.mem.writeInt(u64, buf[n..][0..8], conn_id, .little);
    return n + 8;
}
pub fn writeResponseCid(buf: []u8, c: Cookie, conn_id: cidmod.Cid) usize {
    const n = writeResponse(buf, c);
    std.mem.writeInt(u64, buf[n..][0..8], conn_id, .little);
    return n + 8;
}
pub fn readConnId(bytes: []const u8) ?cidmod.Cid {
    if (bytes.len < 21) return null;
    return std.mem.readInt(u64, bytes[13..21], .little);
}

// Connect-token handshake (when `Security.tokens`): the client echoes the cookie AND
// the connect token in the response; the server verifies the token and derives the
// session keys from it. Layout: `[flags][coarse:4][cookie:8][token: Token.wire_len]`.
pub fn writeResponseToken(buf: []u8, c: Cookie, token_bytes: []const u8) usize {
    const n = writeResponse(buf, c);
    @memcpy(buf[n .. n + token_bytes.len], token_bytes);
    return n + token_bytes.len;
}
pub fn readResponseToken(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 13 + tokenmod.Token.wire_len) return null;
    return bytes[13 .. 13 + tokenmod.Token.wire_len];
}

/// Derive the directional key schedule from a connect token's session keys (both
/// ends compute the same `Keys`: the client from the cleartext copy, the server from
/// the verified sealed private half).
pub fn keysFromToken(c2s_key: [32]u8, s2c_key: [32]u8) Keys {
    const H = std.crypto.kdf.hkdf.HkdfSha256;
    var k: Keys = undefined;
    k.c2s_key = c2s_key;
    k.s2c_key = s2c_key;
    H.expand(&k.c2s_iv, "magnet c2s iv", H.extract("magnet-iv", &c2s_key));
    H.expand(&k.s2c_iv, "magnet s2c iv", H.extract("magnet-iv", &s2c_key));
    return k;
}

const testing = std.testing;

test "key derivation is symmetric and directional" {
    const psk = [_]u8{0x33} ** 32;
    const a = derive(psk, "proto-1");
    const b = derive(psk, "proto-1");
    try testing.expectEqualSlices(u8, &a.c2s_key, &b.c2s_key);
    try testing.expectEqualSlices(u8, &a.s2c_iv, &b.s2c_iv);
    // directions differ
    try testing.expect(!std.mem.eql(u8, &a.c2s_key, &a.s2c_key));
    // different salt → different keys
    const c = derive(psk, "proto-2");
    try testing.expect(!std.mem.eql(u8, &a.c2s_key, &c.c2s_key));
}

test "anti-amplification caps unvalidated send at 3x recv" {
    var amp = Amplification{};
    amp.onRecv(100);
    try testing.expect(amp.canSend(300));
    try testing.expect(!amp.canSend(301));
    amp.onSent(300);
    try testing.expect(!amp.canSend(1));
    amp.onRecv(50); // now 150 recv → 450 budget, 300 sent
    try testing.expect(amp.canSend(150));
    amp.validate();
    try testing.expect(amp.canSend(1_000_000)); // gate lifted once validated
}

test "handshake datagram roundtrips" {
    var buf: [16]u8 = undefined;
    const n = writeHello(&buf, 0xABCD, 7);
    try testing.expect(isHandshake(buf[0..n]));
    try testing.expectEqual(Type.hello, typeOf(buf[0..n]).?);
    try testing.expectEqual(@as(u64, 0xABCD), readHello(buf[0..n]).?);

    const c = Cookie{ .coarse = 12345, .cookie = 0xDEAD_BEEF_CAFE };
    const m = writeChallenge(&buf, c);
    try testing.expectEqual(Type.challenge, typeOf(buf[0..m]).?);
    const back = readCookie(buf[0..m]).?;
    try testing.expectEqual(c.coarse, back.coarse);
    try testing.expectEqual(c.cookie, back.cookie);

    // a data datagram (bit7 clear) is not a handshake
    const data = [_]u8{ 0x00, 0x05 };
    try testing.expect(!isHandshake(&data));
    try testing.expect(typeOf(&data) == null);
}
