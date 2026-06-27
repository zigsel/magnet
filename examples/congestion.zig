//! congestion - the transport adapts its send rate to the path. This pushes a reliable
//! stream through a 20%-loss, 100ms link under two controllers and reports what each
//! learned. The controller is a comptime choice - swap `Config.congestion` and nothing
//! else changes.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const cc = magnet.proto.delivery.cc;

const Schema = magnet.proto.channels(.{ .bulk = .{ .mode = .reliable_ordered, .Message = u32 } });

fn run(comptime Controller: type, label: []const u8) !void {
    const Cfg = magnet.Config{ .channels = Schema, .congestion = Controller };
    const Session = magnet.proto.Session(Cfg);
    const gpa = std.heap.page_allocator;

    const link = try gpa.create(sim.DefaultLink);
    defer gpa.destroy(link);
    link.* = sim.DefaultLink.init(.{ .latency_ms = 50, .jitter_ms = 20, .loss_permille = 200, .seed = 1 });
    var client = Session{};
    client.setup();
    var server = Session{};
    server.setup();

    const N: u32 = 600;
    var buf: [1200]u8 = undefined;
    var sent: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    while (delivered < N and now < 200_000) : (now += 5) {
        while (sent < N) : (sent += 1) client.send(.bulk, sent) catch break;
        while (client.pollTransmit(&buf, now)) |n| link.send(.to_b, buf[0..n], now);
        while (link.poll(.to_b, now, &buf)) |n| server.feed(buf[0..n], now);
        while (server.receive(.bulk)) |_| delivered += 1;
        while (server.pollTransmit(&buf, now)) |n| link.send(.to_a, buf[0..n], now);
        while (link.poll(.to_a, now, &buf)) |n| client.feed(buf[0..n], now);
    }

    var line: [128]u8 = undefined;
    std.debug.print("  {s:<8} {d} delivered - {s}\n", .{ label, delivered, client.stats().line(&line) });
}

pub fn main() !void {
    std.debug.print("congestion (600 reliable msgs over a 20%-loss, ~100ms RTT link):\n", .{});
    try run(cc.Reno, "NewReno");
    try run(cc.Cubic, "CUBIC");
}
