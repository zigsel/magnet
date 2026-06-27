# Security model

magnet provides confidentiality, integrity, authenticity, and DoS resistance for game
traffic when `security.mode = .aead`. It is **not** a general secure transport and **not**
anti-cheat by itself - but it closes the network-level attack surface.

## Threats and mitigations

| Threat | Mitigation |
|---|---|
| Eavesdrop / tamper | per-packet AEAD; the cleartext header is authenticated as AAD |
| Spoofed-source reflection / amplification | 3× anti-amplification gate (always on) |
| State-exhaustion (half-open flood) | stateless SipHash challenge - no slot until a cookie is echoed |
| Replay | per-direction sliding replay window |
| Connection hijack | AEAD + connection IDs + path validation on migration |
| Optimistic-ack cwnd inflation | `PacketNumberFilter` (an ack of a skipped PN closes the peer) |
| Token forgery / reuse | backend-signed AEAD tokens, expiry, constant-time MAC dedup, address whitelist |
| Corruption-as-DoS | AEAD rejection is cheap; corrupt datagrams are dropped before touching state |

## Identity

Three a-la-carte ways to establish session keys, all feeding the same AEAD handshake:

- **Pre-shared key** - a shared secret; simplest, for trusted/LAN deployments.
- **Connect tokens** - a backend signs short-lived tokens authorizing a client for
  specific servers (the netcode model). See [security guide](../guide/security.md#tokens).
- **Ed25519 certificates** - each peer presents a CA-signed cert; both verify and derive a
  key by X25519 ECDH. No password to pre-share.

## Crypto

`std.crypto` only - ChaCha20-Poly1305 (default) or AES-256-GCM, Ed25519, X25519, HKDF-SHA256,
SipHash. No libsodium, no third-party dependency.

The nonce is derived from the packet number (no nonce bytes on the wire; uniqueness is
guaranteed by monotonic packet numbers). Keys are directional (`c2s` / `s2c`) and never
appear on the wire.
