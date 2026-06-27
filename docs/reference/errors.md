# Errors & degrade

magnet returns typed errors; steady state never panics. Pool exhaustion is a defined,
observable event, never a crash.

## Send errors (`session.SendError`)

| Error | When |
|---|---|
| `error.MessageTooLarge` | the serialized message exceeds `max_payload` (or a block exceeds `max_payload × max_fragments`) |
| `error.Backpressure` | the channel's send window is full and the degrade policy is `.backpressure` |

```zig
session.send(.chat, msg) catch |e| switch (e) {
    error.Backpressure => { /* try again next tick */ },
    error.MessageTooLarge => { /* split it, or raise max_payload */ },
};
```

## Degrade policies

When a queue fills, `Config.degrade` decides the behaviour instead of erroring:

- `on_send_queue_full`: `.backpressure` (return the error), `.drop_new` (silently drop this
  message), or `.drop_oldest` (evict the oldest unacked to make room).
- `on_reassembly_full`: `.drop` or `.error_out`.

Every drop calls `tracer.onDrop(peer, reason)` - so "silently fell behind" is observable,
never silent. Reasons: `send_queue_full`, `inbox_full`, `reassembly_full`, `malformed`,
`replay`, `too_old`.

## Protocol violations

A protocol violation (an ack of an unsent/filtered packet number, a replayed datagram, a
malformed frame) drops the datagram or closes the connection with a counted reason - it
never crashes. `session.isClosed()` reports a closed connection; `endpoint.reapClosed()`
frees the slot and emits a `disconnected` event.

## Token verification (`proto.conn.token.VerifyError`)

`error.BadProtocol` · `error.Expired` · `error.BadToken` - returned when the server opens a
connect token.

## Identity (`proto.conn.identity.VerifyError`)

`error.BadSignature` · `error.Expired` - returned when verifying an Ed25519 cert.
