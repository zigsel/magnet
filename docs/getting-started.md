# Getting started

A client and a server exchanging typed messages. We'll use the in-process pump so it
runs without a socket; swapping in a real socket is one driver away (see
[runtime](guide/runtime.md)).

## 1. Describe your channels

A channel is a stream with a reliability guarantee and a message type. The schema is a
comptime value:

```zig
const magnet = @import("magnet");

const Chat = struct { from: u8, text: magnet.wire.Bounded(u8, 24) };

const Schema = magnet.proto.channels(.{
    .chat = .{ .mode = .reliable_ordered, .Message = Chat },
    .moves = .{ .mode = .unreliable_sequenced, .Message = struct { dx: i8, dy: i8 } },
});
```

## 2. Make a session type

Everything derives from one `Config`. Defaults are sensible, so `channels` is often all
you set:

```zig
const Session = magnet.proto.Session(.{ .channels = Schema });
```

## 3. Send and receive

`send` / `receive` are typed against the channel - the message is serialized for you:

```zig
var alice = Session{};  alice.setup();
var bob   = Session{};  bob.setup();

try alice.send(.chat, .{ .from = 1, .text = .fromSlice("hello") });

// move datagrams from alice to bob (a real driver does this over a socket)
var buf: [1200]u8 = undefined;
while (alice.pollTransmit(&buf, 0)) |len| bob.feed(buf[0..len], 0);

while (bob.receive(.chat)) |m| std.debug.print("{d}: {s}\n", .{ m.from, m.text.slice() });
```

That's the whole contract: `feed` bytes in, `pollTransmit` bytes out, `send` / `receive`
your messages. The session decides *what* to put on the wire and *when*; you decide how
the bytes travel.

## Next

- Many peers, not just two → an [`Endpoint`](guide/config.md#endpoint).
- Run it over a real socket → [runtime](guide/runtime.md).
- Encrypt it → [security](guide/security.md).
- Sync a whole game world → [replication](guide/replication.md).

Runnable: [`examples/echo.zig`](../examples/echo.zig),
[`examples/typed_messages.zig`](../examples/typed_messages.zig).
