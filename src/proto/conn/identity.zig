//! Identity backend: Ed25519 cert chains + X25519 ECDH, the a-la-carte
//! alternative to the raw-PSK / connect-token key sources. A peer presents a `Cert`
//! (its X25519 public key + an expiry, signed by a trusted CA's Ed25519 key); the
//! other side verifies the signature and freshness, then both derive the same session
//! master secret by `X25519(my_priv, peer_pub)` → HKDF. This authenticates *who* the
//! peer is (not just that it holds a shared secret), without a backend matchmaker.
//! All `std.crypto`; no libsodium.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const CaPublic = [32]u8; // Ed25519 public key of the certificate authority
pub const DhPublic = [32]u8; // X25519 public key
pub const DhSecret = [32]u8;

/// A peer's certificate: its X25519 public key + an expiry, signed by the CA.
pub const Cert = struct {
    dh_public: DhPublic,
    expire_s: i64,
    sig: [Ed25519.Signature.encoded_length]u8,

    /// Bytes the CA signs (everything but the signature itself).
    fn signed(self: *const Cert) [40]u8 {
        var b: [40]u8 = undefined;
        @memcpy(b[0..32], &self.dh_public);
        std.mem.writeInt(i64, b[32..40], self.expire_s, .little);
        return b;
    }
};

/// CA side: issue a cert binding `dh_public` to `expire_s`, signed by `ca`.
pub fn issue(ca: Ed25519.KeyPair, dh_public: DhPublic, expire_s: i64) !Cert {
    var c: Cert = .{ .dh_public = dh_public, .expire_s = expire_s, .sig = undefined };
    const sig = try ca.sign(&c.signed(), null);
    c.sig = sig.toBytes();
    return c;
}

pub const VerifyError = error{ BadSignature, Expired };

/// Verify a peer cert against the trusted CA public key and the current time.
pub fn verify(ca_pub: CaPublic, now_s: i64, c: *const Cert) VerifyError!void {
    if (now_s >= c.expire_s) return error.Expired;
    const pk = Ed25519.PublicKey.fromBytes(ca_pub) catch return error.BadSignature;
    const sig = Ed25519.Signature.fromBytes(c.sig);
    sig.verify(&c.signed(), pk) catch return error.BadSignature;
}

/// Both ends compute the same 32-byte master secret from the ECDH shared point.
/// `initiator` orders the two public keys into the HKDF salt so the two sides agree.
pub fn masterSecret(my_secret: DhSecret, peer_public: DhPublic, my_public: DhPublic, initiator: bool) ![32]u8 {
    const shared = try X25519.scalarmult(my_secret, peer_public);
    var salt: [64]u8 = undefined;
    const lo = if (initiator) my_public else peer_public;
    const hi = if (initiator) peer_public else my_public;
    @memcpy(salt[0..32], &lo);
    @memcpy(salt[32..64], &hi);
    const prk = Hkdf.extract(&salt, &shared);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, "magnet identity master", prk);
    return out;
}

/// One-call key agreement for the cert auth mode: verify the `peer` cert against the
/// trusted CA + clock, then derive the shared session master via ECDH. The 32-byte
/// master is fed straight into the live AEAD handshake (`Session.secSetup` /
/// `Endpoint.connectTo` take it where a raw PSK would go), so cert-authenticated
/// identity rides the existing encrypted transport with no PSK to pre-share.
pub fn agree(my: X25519.KeyPair, my_cert: *const Cert, peer: *const Cert, ca_pub: CaPublic, now_s: i64, initiator: bool) (VerifyError || std.crypto.errors.IdentityElementError)![32]u8 {
    try verify(ca_pub, now_s, peer);
    return masterSecret(my.secret_key, peer.dh_public, my_cert.dh_public, initiator);
}

const testing = std.testing;

test "agree: cert-verified ECDH yields the same master on both ends (rejects bad cert)" {
    const ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x44} ** 32);
    const ck = try X25519.KeyPair.generateDeterministic([_]u8{0xC1} ** 32);
    const sk = try X25519.KeyPair.generateDeterministic([_]u8{0x51} ** 32);
    const cc = try issue(ca, ck.public_key, 1000);
    const sc = try issue(ca, sk.public_key, 1000);
    const cm = try agree(ck, &cc, &sc, ca.public_key.toBytes(), 500, true); // client
    const sm = try agree(sk, &sc, &cc, ca.public_key.toBytes(), 500, false); // server
    try testing.expectEqualSlices(u8, &cm, &sm); // identical session master
    const bad_ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x99} ** 32);
    try testing.expectError(error.BadSignature, agree(ck, &cc, &sc, bad_ca.public_key.toBytes(), 500, true));
}

test "issue → verify a cert against the CA; tamper and expiry rejected" {
    const ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x11} ** 32);
    const peer = try X25519.KeyPair.generateDeterministic([_]u8{0x22} ** 32);
    const cert = try issue(ca, peer.public_key, 1000);
    try verify(ca.public_key.toBytes(), 500, &cert); // valid + fresh

    try testing.expectError(error.Expired, verify(ca.public_key.toBytes(), 1000, &cert));
    var bad = cert;
    bad.dh_public[0] ^= 1; // signature no longer covers the key
    try testing.expectError(error.BadSignature, verify(ca.public_key.toBytes(), 500, &bad));
    const other_ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x33} ** 32);
    try testing.expectError(error.BadSignature, verify(other_ca.public_key.toBytes(), 500, &cert)); // wrong CA
}

test "both ends derive the same master secret from authenticated ECDH" {
    const a = try X25519.KeyPair.generateDeterministic([_]u8{0xA1} ** 32);
    const b = try X25519.KeyPair.generateDeterministic([_]u8{0xB2} ** 32);
    const ma = try masterSecret(a.secret_key, b.public_key, a.public_key, true);
    const mb = try masterSecret(b.secret_key, a.public_key, b.public_key, false);
    try testing.expectEqualSlices(u8, &ma, &mb); // identical session master
    // a different peer yields a different secret
    const c = try X25519.KeyPair.generateDeterministic([_]u8{0xC3} ** 32);
    const mc = try masterSecret(a.secret_key, c.public_key, a.public_key, true);
    try testing.expect(!std.mem.eql(u8, &ma, &mc));
}
