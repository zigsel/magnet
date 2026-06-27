//! channels - the reliability taxonomy. Each channel picks its own guarantee; this
//! sends the same stream on three of them through a link that drops every 3rd datagram,
//! and reports what each delivered. Reliable channels resend; unreliable ones don't.

const std = @import("std");
const magnet = @import("magnet");

const Schema = magnet.proto.channels(.{
    .unreliable = .{ .mode = .unreliable, .Message = u32 }, // fire and forget
    .reliable = .{ .mode = .reliable_ordered, .Message = u32 }, // every one, in order
    .newest = .{ .mode = .reliable_sequenced, .Message = u32 }, // reliably, but only the latest
});
const Session = magnet.proto.Session(magnet.Config{ .channels = Schema });

pub fn main() void {
    var a = Session{};
    a.setup();
    var b = Session{};
    b.setup();

    var unreliable: usize = 0;
    var reliable: usize = 0;
    var ordered = true;
    var newest: u32 = 0;
    var sent: u32 = 0;
    var now: i64 = 0;
    for (0..400) |_| {
        if (sent < 12) { // one update per channel per tick, so loss spreads across them
            a.send(.unreliable, sent) catch {};
            a.send(.reliable, sent) catch {};
            a.send(.newest, sent) catch {};
            sent += 1;
        }
        lossyRelay(&a, &b, now); // forward: drops ~40% of datagrams
        while (b.receive(.unreliable)) |_| unreliable += 1;
        while (b.receive(.reliable)) |v| {
            if (v != reliable) ordered = false;
            reliable += 1;
        }
        while (b.receive(.newest)) |v| newest = v;
        lossyRelay(&b, &a, now); // back: acks, so the reliable channels can resend
        now += 5;
    }

    std.debug.print("channels (12 sent each, ~40% of datagrams dropped):\n", .{});
    std.debug.print("  unreliable: {d}/12 arrived (lost ones stay lost)\n", .{unreliable});
    std.debug.print("  reliable:   {d}/12 arrived, in order = {}\n", .{ reliable, ordered });
    std.debug.print("  newest:     latest seen = {d} (stale updates skipped)\n", .{newest});
}

var seen: usize = 0;
fn lossyRelay(from: *Session, to: *Session, now: i64) void {
    var buf: [1200]u8 = undefined;
    while (from.pollTransmit(&buf, now)) |len| {
        seen += 1;
        if (seen % 5 >= 2) to.feed(buf[0..len], now); // drop ~40%
    }
}
