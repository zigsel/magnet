//! big_transfer - a message larger than a datagram. Turn on fragmentation and a blob
//! is split into reliable fragments and reassembled byte-exact at the far end, even
//! when a third of the fragments are dropped on the way.

const std = @import("std");
const magnet = @import("magnet");

const Schema = magnet.proto.channels(.{ .file = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = magnet.Config{ .channels = Schema, .delivery = .{ .fragmentation = true, .max_fragments = 64 } };
const Session = magnet.proto.Session(Cfg);

pub fn main() void {
    var sender = Session{};
    sender.setup();
    var receiver = Session{};
    receiver.setup();

    var blob: [9000]u8 = undefined; // ~36 fragments at the default 256-byte payload
    for (&blob, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 7);

    sender.sendBlock(.file, &blob) catch unreachable;

    var out: [9000]u8 = undefined;
    var received: ?usize = null;
    var now: i64 = 0;
    while (received == null and now < 20_000) : (now += 5) {
        lossyRelay(&sender, &receiver, now); // forward, dropping ~1 in 3 fragments
        if (receiver.receiveBlock(.file, &out)) |len| received = len;
        relay(&receiver, &sender, now); // acks back, so dropped fragments resend
    }

    const ok = received != null and std.mem.eql(u8, &blob, out[0..received.?]);
    std.debug.print("big_transfer: 9000-byte blob reassembled byte-exact under loss = {}\n", .{ok});
}

var seen: usize = 0;
fn lossyRelay(from: *Session, to: *Session, now: i64) void {
    var buf: [1200]u8 = undefined;
    while (from.pollTransmit(&buf, now)) |len| {
        seen += 1;
        if (seen % 3 != 0) to.feed(buf[0..len], now);
    }
}
fn relay(from: *Session, to: *Session, now: i64) void {
    var buf: [1200]u8 = undefined;
    while (from.pollTransmit(&buf, now)) |len| to.feed(buf[0..len], now);
}
