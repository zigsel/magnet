# Sans-IO

The protocol core - `Session` and `Endpoint` - is a pure state machine. It never touches
a socket, a clock, or an allocator. Its entire contract is three methods:

```zig
session.feed(bytes, now)        // bytes arrived
session.pollTransmit(buf, now)  // give me the next datagram to send (or null)
session.pollDeadline(now)       // when do I next need to be polled? (or null = idle)
```

`now` is an `i64` of milliseconds - you pass time *in*; the core never reads a clock.

## The socket lives elsewhere

The actual socket is in a thin **driver** (`runtime/io.zig` - the only file that imports
`std.Io`). The driver does the boring loop:

```
receive a datagram → feed it
drain pollTransmit → send each datagram
arm a timer at pollDeadline
```

The layering enforces the separation: `proto/` is *forbidden* from importing `runtime/`
(checked by the `enforce` build step). The protocol is provably independent of how bytes
move.

## Why it's worth it

- **Determinism & testing.** Because the core is `(bytes, now) → datagrams`, you can drive
  the *real* session over a *simulated* link with a virtual clock and seeded loss - fully
  reproducible. Every example pumps in-process or over the sim; same code path as a socket.
- **Concurrency-model freedom.** The same core runs blocking, in a reactor, sharded across
  cores, thread-per-connection, or polled from your game loop - just pick a driver. No
  async coloring leaks into the protocol.
- **Portability.** Swap io_uring / epoll / kqueue / `std.Io` / the simulator without the
  protocol noticing.

So a socket being separate from the session isn't an inconvenience - it's the design that
makes magnet testable, model-agnostic, and portable.

See also: [layering](layering.md), [runtime](../guide/runtime.md).
