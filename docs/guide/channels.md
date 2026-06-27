# Channels

A channel is an independent stream with a reliability guarantee and a message type. You
declare a set; each gets a stable wire id and exactly the state its mode needs.

```zig
const Schema = magnet.proto.channels(.{
    .moves = .{ .mode = .unreliable_sequenced, .Message = MoveCmd, .priority = 3 },
    .chat  = .{ .mode = .reliable_ordered,     .Message = ChatMsg, .priority = 0 },
});
```

Channels are selected by enum literal (`.chat`) and resolved at compile time.

## The reliability taxonomy

| Mode | Keeps until acked | Delivery |
|---|---|---|
| `unreliable` | no | as it arrives (dups pass) |
| `unreliable_sequenced` | no | newest only; older dropped |
| `reliable_unordered` | yes | deduped, as it arrives |
| `reliable_ordered` | yes | deduped, strictly in order, exactly once |
| `reliable_sequenced` | yes | reliably deduped, but only the newest delivered |
| `reliable_ordered_sequenced` | yes | ordered + sequenced blended on one stream |

An `unreliable` channel compiles out the retransmit window *and* the reorder buffer - it's
near-zero state. Reliable modes carry the machinery. Different channels never block each
other (no cross-channel head-of-line blocking).

## Sending and receiving

```zig
try session.send(.chat, msg);           // typed, serialized for you
while (session.receive(.chat)) |m| { … }

try session.sendRaw(.chat, bytes);      // pre-serialized bytes
_ = session.receiveRaw(.chat, &out);
```

For the blended mode, `send` is the ordered message and `sendSequenced` is a sequenced
update riding the current slot.

## Priority & weight

`priority` (strict classes) and `weight` (fair-share within a class) drive a WFQ scheduler
that packs across channels with anti-starvation. Adjust at runtime with
`session.setPriority(.chat, priority, weight)`.

Runnable: [`examples/channels.zig`](../../examples/channels.zig),
[`examples/typed_messages.zig`](../../examples/typed_messages.zig).
