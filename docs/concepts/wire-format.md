# Wire format

A datagram is a small cleartext header followed by frames. When `security.mode = .aead`,
the frames region is sealed and the header is the authenticated associated data.

## Datagram

```
[ public header ]                       cleartext (and the AEAD AAD)
   flags: u8        bits0-1 = pn length−1 · bit5 = unconnected · bit6 = has-CID · bit7 = handshake
   [cid: 8 bytes]   present iff flags bit6 (connection migration)
   packet number    1–4 bytes, truncated against the largest acked
[ frames... ]                           parsed until the datagram ends (sealed when .aead)
[ AEAD tag: 16 ]                        present iff .aead
```

Packet numbers are monotonic and transmit-only; a retransmit rides a *new* packet number.
They are encoded truncated (1 byte in steady state) and reconstructed by windowing.

## Frames

| Frame | Carries |
|---|---|
| `data` | `[channel][dseq:u16][len:u16][payload]` - one channel message |
| `ack` | run-length ack ranges, newest→oldest, + ack-delay |
| `nak` | ranges of *missing* packet numbers (fast retransmit hint) |
| `fragment` | a fragment of a message larger than one datagram |
| `ping` / `pong` | `[nonce:u64]` - keepalive + RTT probe |
| `path_challenge` / `path_response` | `[token:u64]` - migration path validation |
| `padding` | the rest of the datagram is a PMTUD probe pad |
| `disconnect` | `[reason:u8]` - graceful close |

Handshake datagrams (flags bit7) are cleartext: `hello` / `challenge` / `response`.

## Versioning

`protocol_id` (a comptime `u64`) gates wire compatibility - a mismatched id is silently
dropped. `app_version` is negotiated in the handshake for app-level feature flags. The
golden vectors in `conformance.zig` pin the byte layout against accidental change.
