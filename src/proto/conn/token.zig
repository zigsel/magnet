//! Connect tokens (netcode model). A backend/matchmaker (offline, over HTTPS)
//! issues a token with two halves:
//!   - a **private** half (`{ client_id, timeout, c2s_key, s2c_key, user_data }`)
//!     AEAD-sealed with a `private_key` shared backend↔dedicated-servers, AAD =
//!     `protocol_id ++ expire`;
//!   - a **public** wrapper carrying `protocol_id`, `expire`, the nonce, the sealed
//!     blob, and a *cleartext copy* of the session keys so the client can encrypt
//!     without reading the private half.
//! The dedicated server decrypts the private half, checks expiry, and dedups by the
//! sealed blob's trailing 16-byte MAC in **constant time** (no timing oracle).
//! Fixed-layout, zero-alloc; `XChaCha20Poly1305` would allow a random 24-byte nonce,
//! but we use ChaCha20Poly1305 with the explicit per-token nonce here.

const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
pub const user_data_len = 256;
pub const max_server_addrs = 4; // dedicated servers this token is valid for
pub const private_plain_len = 8 + 8 + 32 + 32 + user_data_len + 1 + max_server_addrs * 8;
pub const private_sealed_len = private_plain_len + Aead.tag_length;
pub const nonce_len = Aead.nonce_length;
pub const Key = [32]u8;

pub const Private = struct {
    client_id: u64,
    timeout_s: i64,
    c2s_key: Key,
    s2c_key: Key,
    user_data: [user_data_len]u8,
    /// The dedicated-server addresses this token authorizes (the whitelist). A server
    /// accepts the token only if its own address is listed; `num_server_addrs == 0`
    /// means "any server" (no whitelist).
    num_server_addrs: u8 = 0,
    server_addrs: [max_server_addrs]u64 = [_]u64{0} ** max_server_addrs,

    /// Is `addr` an authorized server for this token? (empty list ⇒ any).
    pub fn allowsServer(self: *const Private, addr: u64) bool {
        if (self.num_server_addrs == 0) return true;
        var i: usize = 0;
        while (i < self.num_server_addrs and i < max_server_addrs) : (i += 1) {
            if (self.server_addrs[i] == addr) return true;
        }
        return false;
    }
};

/// On-wire public token. Fixed layout; `encode`/`decode` are byte-exact.
pub const Token = struct {
    protocol_id: u64,
    expire_s: i64,
    nonce: [nonce_len]u8,
    sealed: [private_sealed_len]u8,
    // cleartext copies so the client can derive its session crypto:
    c2s_key: Key,
    s2c_key: Key,

    pub const wire_len = 8 + 8 + nonce_len + private_sealed_len + 32 + 32;

    pub fn encode(self: *const Token, out: []u8) usize {
        var p: usize = 0;
        std.mem.writeInt(u64, out[p..][0..8], self.protocol_id, .little);
        p += 8;
        std.mem.writeInt(i64, out[p..][0..8], self.expire_s, .little);
        p += 8;
        @memcpy(out[p..][0..nonce_len], &self.nonce);
        p += nonce_len;
        @memcpy(out[p..][0..private_sealed_len], &self.sealed);
        p += private_sealed_len;
        @memcpy(out[p..][0..32], &self.c2s_key);
        p += 32;
        @memcpy(out[p..][0..32], &self.s2c_key);
        p += 32;
        return p;
    }

    pub fn decode(bytes: []const u8) ?Token {
        if (bytes.len < wire_len) return null;
        var t: Token = undefined;
        var p: usize = 0;
        t.protocol_id = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        t.expire_s = std.mem.readInt(i64, bytes[p..][0..8], .little);
        p += 8;
        @memcpy(&t.nonce, bytes[p..][0..nonce_len]);
        p += nonce_len;
        @memcpy(&t.sealed, bytes[p..][0..private_sealed_len]);
        p += private_sealed_len;
        @memcpy(&t.c2s_key, bytes[p..][0..32]);
        p += 32;
        @memcpy(&t.s2c_key, bytes[p..][0..32]);
        return t;
    }
};

fn aad(protocol_id: u64, expire_s: i64) [16]u8 {
    var a: [16]u8 = undefined;
    std.mem.writeInt(u64, a[0..8], protocol_id, .little);
    std.mem.writeInt(i64, a[8..16], expire_s, .little);
    return a;
}

/// Backend side: seal a private half into a public token.
pub fn issue(private_key: Key, protocol_id: u64, expire_s: i64, nonce: [nonce_len]u8, p: Private) Token {
    var plain: [private_plain_len]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, plain[off..][0..8], p.client_id, .little);
    off += 8;
    std.mem.writeInt(i64, plain[off..][0..8], p.timeout_s, .little);
    off += 8;
    @memcpy(plain[off..][0..32], &p.c2s_key);
    off += 32;
    @memcpy(plain[off..][0..32], &p.s2c_key);
    off += 32;
    @memcpy(plain[off..][0..user_data_len], &p.user_data);
    off += user_data_len;
    plain[off] = p.num_server_addrs;
    off += 1;
    for (p.server_addrs) |a| {
        std.mem.writeInt(u64, plain[off..][0..8], a, .little);
        off += 8;
    }

    var t: Token = undefined;
    t.protocol_id = protocol_id;
    t.expire_s = expire_s;
    t.nonce = nonce;
    t.c2s_key = p.c2s_key;
    t.s2c_key = p.s2c_key;
    var tag: [Aead.tag_length]u8 = undefined;
    const ad = aad(protocol_id, expire_s);
    Aead.encrypt(t.sealed[0..private_plain_len], &tag, &plain, &ad, nonce, private_key);
    @memcpy(t.sealed[private_plain_len..], &tag);
    return t;
}

pub const VerifyError = error{ BadProtocol, Expired, BadToken };

/// Dedicated-server side: open the private half. `now_s` from the server clock.
pub fn verify(private_key: Key, protocol_id: u64, now_s: i64, t: *const Token) VerifyError!Private {
    if (t.protocol_id != protocol_id) return error.BadProtocol;
    if (now_s >= t.expire_s) return error.Expired;
    var plain: [private_plain_len]u8 = undefined;
    var tag: [Aead.tag_length]u8 = undefined;
    @memcpy(&tag, t.sealed[private_plain_len..]);
    const ad = aad(protocol_id, t.expire_s);
    Aead.decrypt(&plain, t.sealed[0..private_plain_len], tag, &ad, t.nonce, private_key) catch return error.BadToken;
    var p: Private = undefined;
    var off: usize = 0;
    p.client_id = std.mem.readInt(u64, plain[off..][0..8], .little);
    off += 8;
    p.timeout_s = std.mem.readInt(i64, plain[off..][0..8], .little);
    off += 8;
    @memcpy(&p.c2s_key, plain[off..][0..32]);
    off += 32;
    @memcpy(&p.s2c_key, plain[off..][0..32]);
    off += 32;
    @memcpy(&p.user_data, plain[off..][0..user_data_len]);
    off += user_data_len;
    p.num_server_addrs = plain[off];
    off += 1;
    for (&p.server_addrs) |*a| {
        a.* = std.mem.readInt(u64, plain[off..][0..8], .little);
        off += 8;
    }
    return p;
}

/// The token's MAC (trailing 16 bytes of the sealed blob) - a unique handle for
/// constant-time replay dedup of already-accepted tokens.
pub fn mac(t: *const Token) [16]u8 {
    var m: [16]u8 = undefined;
    @memcpy(&m, t.sealed[private_plain_len..]);
    return m;
}

/// A fixed-capacity ring of accepted token MACs; constant-time membership so a
/// replayed token is rejected without leaking timing.
pub fn MacDedup(comptime cap: usize) type {
    return struct {
        const Self = @This();
        macs: [cap][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** cap,
        used: [cap]bool = [_]bool{false} ** cap,
        next: usize = 0,

        pub fn seen(self: *const Self, m: [16]u8) bool {
            var found = false;
            for (self.macs, self.used) |stored, u| {
                const eq = std.crypto.timing_safe.eql([16]u8, stored, m);
                found = found or (u and eq);
            }
            return found;
        }
        pub fn record(self: *Self, m: [16]u8) void {
            self.macs[self.next] = m;
            self.used[self.next] = true;
            self.next = (self.next + 1) % cap;
        }
    };
}

const testing = std.testing;

const test_priv_key: Key = [_]u8{0x5A} ** 32;
const proto: u64 = 0x0A17_4747;

fn sampleToken(expire_s: i64) Token {
    const p = Private{
        .client_id = 1234,
        .timeout_s = 30,
        .c2s_key = [_]u8{0x11} ** 32,
        .s2c_key = [_]u8{0x22} ** 32,
        .user_data = [_]u8{0xCD} ** user_data_len,
    };
    return issue(test_priv_key, proto, expire_s, [_]u8{0x07} ** nonce_len, p);
}

test "issue → encode/decode → verify recovers the private half" {
    const t = sampleToken(1000);
    var buf: [Token.wire_len]u8 = undefined;
    const n = t.encode(&buf);
    try testing.expectEqual(Token.wire_len, n);
    const back = Token.decode(buf[0..n]).?;
    const p = try verify(test_priv_key, proto, 500, &back);
    try testing.expectEqual(@as(u64, 1234), p.client_id);
    try testing.expectEqualSlices(u8, &([_]u8{0x11} ** 32), &p.c2s_key);
}

test "wrong protocol, expiry, tampered token rejected" {
    const t = sampleToken(1000);
    try testing.expectError(error.BadProtocol, verify(test_priv_key, proto + 1, 500, &t));
    try testing.expectError(error.Expired, verify(test_priv_key, proto, 1000, &t));
    var bad = t;
    bad.sealed[0] ^= 0xFF;
    try testing.expectError(error.BadToken, verify(test_priv_key, proto, 500, &bad));
    var wrongkey: Key = test_priv_key;
    wrongkey[0] ^= 1;
    try testing.expectError(error.BadToken, verify(wrongkey, proto, 500, &t));
}

test "MAC dedup rejects a replayed token" {
    const t = sampleToken(1000);
    var dd = MacDedup(64){};
    const m = mac(&t);
    try testing.expect(!dd.seen(m));
    dd.record(m);
    try testing.expect(dd.seen(m)); // replay
    const t2 = issue(test_priv_key, proto, 1000, [_]u8{0x08} ** nonce_len, .{
        .client_id = 5,
        .timeout_s = 1,
        .c2s_key = [_]u8{0} ** 32,
        .s2c_key = [_]u8{0} ** 32,
        .user_data = [_]u8{0} ** user_data_len,
    });
    try testing.expect(!dd.seen(mac(&t2))); // different token, different nonce → different MAC
}

test "server-address whitelist: token authorizes only listed servers" {
    var p = Private{
        .client_id = 1,
        .timeout_s = 30,
        .c2s_key = [_]u8{0} ** 32,
        .s2c_key = [_]u8{0} ** 32,
        .user_data = [_]u8{0} ** user_data_len,
        .num_server_addrs = 2,
        .server_addrs = .{ 100, 200, 0, 0 },
    };
    try testing.expect(p.allowsServer(100));
    try testing.expect(p.allowsServer(200));
    try testing.expect(!p.allowsServer(300)); // not whitelisted
    var any = p;
    any.num_server_addrs = 0;
    try testing.expect(any.allowsServer(999)); // empty list ⇒ any server

    // survives the seal/verify roundtrip
    const t = issue(test_priv_key, proto, 1000, [_]u8{9} ** nonce_len, p);
    const back = try verify(test_priv_key, proto, 500, &t);
    try testing.expectEqual(@as(u8, 2), back.num_server_addrs);
    try testing.expect(back.allowsServer(200) and !back.allowsServer(300));
}
