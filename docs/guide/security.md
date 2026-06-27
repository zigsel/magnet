# Security

Set `security.mode = .aead` and the connection is encrypted, authenticated, replay-protected,
and DoS-resistant. With `.none` (the default) all crypto compiles out. For the threat model
see [concepts/security-model](../concepts/security-model.md).

```zig
const Cfg = magnet.Config{
    .channels = Schema,
    .protocol_id = 0xC0FFEE,
    .security = .{ .mode = .aead }, // ChaCha20-Poly1305 default; .aes256gcm opt-in
};
const Endpoint = magnet.Endpoint(Cfg);
```

## Pre-shared key

The simplest identity - a shared secret plus a challenge secret on the server:

```zig
server.secSetup(psk, challenge_secret);     // server side
_ = client.connectTo(server_addr, psk);     // begins the handshake
```

The server holds **no per-client state** until the client echoes a valid stateless cookie,
so a spoofed-source `hello` flood allocates nothing.

## Tokens

A backend (matchmaker) signs short-lived connect tokens authorizing a client for specific
servers. Keys derive from the token; expired / forged / replayed tokens are rejected on the
wire. Enable with `security.tokens = true`:

```zig
const tok = magnet.proto.conn.token.issue(issuer_key, protocol_id, expire_s, nonce, .{ … });
server.secSetupTokens(issuer_key, challenge_secret, own_addr);
_ = client.connectToWithToken(server_addr, &tok);
```

## Certificates

Ed25519 certs + X25519 ECDH - no password to pre-share. Each side verifies the peer's
CA-signed cert and derives the same master key, which feeds the normal AEAD handshake:

```zig
const id = magnet.proto.conn.identity;
const master = try id.agree(my_x25519_kp, &my_cert, &peer_cert, ca_pubkey, now_s, initiator);
// feed `master` where a PSK would go: server.secSetup(master, …) / client.connectTo(addr, master)
```

## Connection IDs & migration

`security.connection_ids = true` addresses a peer by an opaque id instead of its IP, so a
session survives a NAT rebind or IP change. Same IP + new port keeps the path state; a new
IP re-validates the path with a challenge before resuming full send. The endpoint follows
the connection to its new address automatically.

Runnable: [`examples/encrypted.zig`](../../examples/encrypted.zig),
[`connect_tokens.zig`](../../examples/connect_tokens.zig),
[`cert_identity.zig`](../../examples/cert_identity.zig),
[`migration.zig`](../../examples/migration.zig).
