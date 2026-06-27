//! Per-packet AEAD. The whole frames region of a datagram is sealed; the
//! cleartext public header (flags + packet number) is the AAD, binding it to the
//! ciphertext (improving on GNS, which omits AAD). The nonce is **derived from the
//! packet number** (GNS trick): base IV with the pn folded into its low 8 bytes -
//! no nonce bytes on the wire, uniqueness guaranteed by monotonic packet numbers.
//!
//! `Aead(.chacha20poly1305)` is the default; `.aes256gcm` is the opt-in. Both are
//! `std.crypto` (no libsodium). Selected at comptime from `Security.aead`.

const std = @import("std");

pub const Which = enum { chacha20poly1305, aes256gcm };

pub fn Aead(comptime which: Which) type {
    const A = switch (which) {
        .chacha20poly1305 => std.crypto.aead.chacha_poly.ChaCha20Poly1305,
        .aes256gcm => std.crypto.aead.aes_gcm.Aes256Gcm,
    };
    return struct {
        pub const key_len = A.key_length;
        pub const tag_len = A.tag_length;
        pub const nonce_len = A.nonce_length;
        pub const Key = [key_len]u8;
        pub const Iv = [nonce_len]u8;

        /// base IV with the 64-bit packet number folded into its low 8 bytes.
        fn nonce(base: Iv, pn: u64) Iv {
            var n = base;
            var i: usize = 0;
            while (i < 8) : (i += 1) n[nonce_len - 8 + i] ^= @truncate(pn >> @intCast(i * 8));
            return n;
        }

        /// Seal `plain` into `out` (= ciphertext ++ 16-byte tag); returns bytes written.
        /// `out` must be at least `plain.len + tag_len`.
        pub fn seal(key: Key, base_iv: Iv, pn: u64, aad: []const u8, plain: []const u8, out: []u8) usize {
            var tag: [tag_len]u8 = undefined;
            A.encrypt(out[0..plain.len], &tag, plain, aad, nonce(base_iv, pn), key);
            @memcpy(out[plain.len .. plain.len + tag_len], &tag);
            return plain.len + tag_len;
        }

        /// Open `sealed` (= ciphertext ++ tag) into `out`; returns plaintext length,
        /// or null on auth failure (tamper / wrong key / wrong pn).
        pub fn open(key: Key, base_iv: Iv, pn: u64, aad: []const u8, sealed: []const u8, out: []u8) ?usize {
            if (sealed.len < tag_len) return null;
            const clen = sealed.len - tag_len;
            var tag: [tag_len]u8 = undefined;
            @memcpy(&tag, sealed[clen..]);
            A.decrypt(out[0..clen], sealed[0..clen], tag, aad, nonce(base_iv, pn), key) catch return null;
            return clen;
        }
    };
}

const testing = std.testing;

test "seal/open roundtrip with header as AAD" {
    const E = Aead(.chacha20poly1305);
    const key: E.Key = [_]u8{0x42} ** 32;
    const iv: E.Iv = [_]u8{0x11} ** 12;
    const hdr = [_]u8{ 0x00, 0x05 }; // flags + 1-byte pn
    const msg = "the quick brown fox";
    var sealed: [64]u8 = undefined;
    const n = E.seal(key, iv, 5, &hdr, msg, &sealed);
    try testing.expectEqual(msg.len + E.tag_len, n);
    var out: [64]u8 = undefined;
    const m = E.open(key, iv, 5, &hdr, sealed[0..n], &out).?;
    try testing.expectEqualSlices(u8, msg, out[0..m]);
}

test "tamper, wrong pn, wrong aad all reject" {
    const E = Aead(.chacha20poly1305);
    const key: E.Key = [_]u8{1} ** 32;
    const iv: E.Iv = [_]u8{2} ** 12;
    const hdr = [_]u8{ 0, 9 };
    var sealed: [64]u8 = undefined;
    const n = E.seal(key, iv, 9, &hdr, "secret-payload", &sealed);
    var out: [64]u8 = undefined;
    // tampered ciphertext
    sealed[0] ^= 0x80;
    try testing.expect(E.open(key, iv, 9, &hdr, sealed[0..n], &out) == null);
    sealed[0] ^= 0x80; // restore
    // wrong packet number → wrong nonce
    try testing.expect(E.open(key, iv, 10, &hdr, sealed[0..n], &out) == null);
    // wrong AAD (header)
    const bad_hdr = [_]u8{ 0, 8 };
    try testing.expect(E.open(key, iv, 9, &bad_hdr, sealed[0..n], &out) == null);
    // correct still opens
    try testing.expect(E.open(key, iv, 9, &hdr, sealed[0..n], &out) != null);
}

test "aes256gcm variant also roundtrips" {
    const E = Aead(.aes256gcm);
    const key: E.Key = [_]u8{7} ** 32;
    const iv: E.Iv = [_]u8{3} ** 12;
    var sealed: [48]u8 = undefined;
    const n = E.seal(key, iv, 1, "h", "datagram", &sealed);
    var out: [48]u8 = undefined;
    const m = E.open(key, iv, 1, "h", sealed[0..n], &out).?;
    try testing.expectEqualSlices(u8, "datagram", out[0..m]);
}

test "distinct packet numbers produce distinct nonces (ciphertext differs)" {
    const E = Aead(.chacha20poly1305);
    const key: E.Key = [_]u8{9} ** 32;
    const iv: E.Iv = [_]u8{0} ** 12;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const na = E.seal(key, iv, 1, "", "same-plaintext", &a);
    const nb = E.seal(key, iv, 2, "", "same-plaintext", &b);
    try testing.expectEqual(na, nb);
    try testing.expect(!std.mem.eql(u8, a[0..na], b[0..nb])); // nonce reuse would make them equal
}
