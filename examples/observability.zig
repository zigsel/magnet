//! observability - see what the transport is doing. A comptime tracer is called at every
//! interesting event (zero cost when it's the Null tracer); here we compose a counter
//! with a structured event log, and read a one-line live stats snapshot off a connection.

const std = @import("std");
const magnet = @import("magnet");
const trace = magnet.trace;
const sim = magnet.runtime.sim;

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
// the tracer is part of the type: Counters + a 64-event ring, fanned out together.
const Cfg = magnet.Config{ .channels = Schema, .tracer = trace.Multi(trace.Counters, trace.Log(64)) };
const Session = magnet.proto.Session(Cfg);

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const link = try gpa.create(sim.DefaultLink);
    defer gpa.destroy(link);
    link.* = sim.DefaultLink.init(.{ .latency_ms = 50, .jitter_ms = 20, .loss_permille = 250, .seed = 1 });
    var a = Session{};
    a.setup();
    var b = Session{};
    b.setup();

    var buf: [1200]u8 = undefined;
    var sent: u32 = 0;
    var got: usize = 0;
    var now: i64 = 0;
    while (got < 200 and now < 20_000) : (now += 5) {
        while (sent < 200) : (sent += 1) a.send(.rel, sent) catch break;
        while (a.pollTransmit(&buf, now)) |n| link.send(.to_b, buf[0..n], now);
        while (link.poll(.to_b, now, &buf)) |n| b.feed(buf[0..n], now);
        while (b.receive(.rel)) |_| got += 1;
        while (b.pollTransmit(&buf, now)) |n| link.send(.to_a, buf[0..n], now);
        while (link.poll(.to_a, now, &buf)) |n| a.feed(buf[0..n], now);
    }

    const counters = &a.tracer.a; // the Counters half of the Multi tracer
    std.debug.print("observability: {d} packets sent, {d} acked-bytes, {d} losses, {d} retransmits\n", .{
        counters.packets_sent, counters.acked_bytes, counters.losses, counters.retransmits,
    });

    var evbuf: [64]trace.Event = undefined;
    std.debug.print("  the event log captured {d} recent events\n", .{a.tracer.b.drain(&evbuf)});
    var line: [128]u8 = undefined;
    std.debug.print("  live: {s}\n", .{a.stats().line(&line)});
}
