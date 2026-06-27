# Runtime - drivers and IO

The protocol is sans-IO ([why](../concepts/sans-io.md)); a **driver** moves bytes between
the socket and the session. `runtime/io.zig` is the only place `std.Io` appears.

## Real sockets

The simplest driver blocks on one socket and pumps an endpoint:

```zig
var threaded = std.Io.Threaded.init(allocator, .{});
const io = threaded.io();
var sock = try magnet.runtime.io.bindUdp(io, my_addr_u64);
try magnet.serve(io, &sock, endpoint, &stop);   // = runtime.io.runBlocking
```

`runReactor` instead races a receive against a timer at `pollDeadline` (so an idle
connection wakes on schedule). Addresses are encoded as `u64` (`ip<<32 | port` for IPv4;
IPv6 gets a stable hashed key recovered via `io.AddrTable`).

Picking a driver:

| Driver | Model | Use for |
|---|---|---|
| `io.runBlocking` | one thread, blocking | tools, clients, small servers |
| `io.runReactor` | one loop, `io.select` timers | small/medium servers |
| `runtime.sharded` | M shards, shared-nothing | high-scale servers |
| `runtime.task` | one task/connection + SPSC bridge | high-throughput, app↔net split |
| `runtime.poll` | drained from your game loop | engine-integrated clients/servers |

On Linux, `runtime/io_linux.zig` adds `sendmmsg`/`recvmmsg` batch I/O, GSO/GRO, and
deadline-bounded recv.

## The simulator

For tests and examples, `runtime.sim` is a seeded virtual-clock link with latency, jitter,
loss, reorder, and duplication - driving the *real* endpoints, fully reproducible:

```zig
var link = magnet.runtime.sim.DefaultLink.init(.{ .latency_ms = 50, .loss_permille = 200, .seed = 1 });
// pump: a.pollTransmit → link.send(.to_b) → link.poll(.to_b) → b.feed
```

`runtime.poll` gives `recvAll` / `flushAll` helpers over any duck-typed transport, and
`runtime.record` captures every datagram for offline replay.

Runnable: [`examples/udp_server.zig`](../../examples/udp_server.zig),
[`sharded_server.zig`](../../examples/sharded_server.zig).
