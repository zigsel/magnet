//! typed_messages - channels carry typed values, serialized for you. Pick a message
//! type per channel; `send`/`receive` are type-checked and bit-packed automatically.

const std = @import("std");
const magnet = @import("magnet");

const Chat = struct { from: u8, text: magnet.wire.Bounded(u8, 24) };
const Move = struct { dx: i8, dy: i8 };

const Schema = magnet.proto.channels(.{
    .chat = .{ .mode = .reliable_ordered, .Message = Chat },
    .moves = .{ .mode = .unreliable_sequenced, .Message = Move },
});
const Session = magnet.proto.Session(magnet.Config{ .channels = Schema });

pub fn main() void {
    var alice = Session{};
    alice.setup();
    var bob = Session{};
    bob.setup();

    alice.send(.chat, .{ .from = 1, .text = .fromSlice("hello") }) catch {};
    alice.send(.chat, .{ .from = 1, .text = .fromSlice("gg") }) catch {};
    alice.send(.moves, .{ .dx = 1, .dy = 0 }) catch {};

    relay(&alice, &bob);

    while (bob.receive(.chat)) |m| std.debug.print("  chat from {d}: {s}\n", .{ m.from, m.text.slice() });
    while (bob.receive(.moves)) |m| std.debug.print("  move ({d},{d})\n", .{ m.dx, m.dy });
    std.debug.print("typed_messages: a typed chat + move stream over two channels\n", .{});
}

fn relay(from: *Session, to: *Session) void {
    var buf: [1200]u8 = undefined;
    while (from.pollTransmit(&buf, 0)) |len| to.feed(buf[0..len], 0);
}
