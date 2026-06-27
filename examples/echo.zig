//! echo - the smallest round-trip. Two peers, one unreliable channel, a message there
//! and back. The transport is sans-IO: feed it bytes, poll it for bytes.

const std = @import("std");
const magnet = @import("magnet");

const Schema = magnet.proto.channels(.{ .ping = .{ .mode = .unreliable, .Message = u32 } });
const Session = magnet.proto.Session(magnet.Config{ .channels = Schema });

pub fn main() void {
    var client = Session{};
    client.setup();
    var server = Session{};
    server.setup();

    var got: u32 = 0;
    var n: u32 = 0;
    while (n < 5) : (n += 1) {
        client.send(.ping, n) catch {};
        relay(&client, &server); // client → server
        while (server.receive(.ping)) |v| server.send(.ping, v) catch {}; // bounce it back
        relay(&server, &client); // server → client
        while (client.receive(.ping)) |v| {
            std.debug.print("  echo {d}\n", .{v});
            got += 1;
        }
    }
    std.debug.print("echo: {d}/5 round-tripped\n", .{got});
}

// move every queued datagram from one peer to the other
fn relay(from: *Session, to: *Session) void {
    var buf: [1200]u8 = undefined;
    while (from.pollTransmit(&buf, 0)) |len| to.feed(buf[0..len], 0);
}
