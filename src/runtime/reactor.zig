//! Single-thread **reactor** driver: one loop services many endpoints, each over
//! its own transport. This is the cooperative model for small/medium servers -
//! every connection is touched by exactly one executor, so there are no locks.
//!
//! The driver is generic over the transport (`recv(buf, now) ?{addr,len}` /
//! `send(addr, bytes, now)`) and the clock, so the *same* code runs over the
//! deterministic sim (virtual clock) and over a real `std.Io` socket (where a tick
//! blocks on recv raced against the earliest `pollDeadline` timer). The sans-IO
//! core is identical across every driver - that model-agnosticism is the point.

const std = @import("std");

/// Pump one endpoint over one transport once: drain all ready inbound datagrams,
/// then flush all queued outbound ones. The unit of work every driver is built on.
pub fn pump(ep: anytype, transport: anytype, scratch: []u8, now: i64) void {
    while (transport.recv(scratch, now)) |r| ep.feedFrom(r.addr, scratch[0..r.len], now);
    while (ep.pollTransmit(scratch, now)) |d| transport.send(d.addr, scratch[0..d.len], now);
}

/// The earliest time any registered endpoint wants to be polled again (min over
/// `pollDeadline`), or null if all are idle. A real driver arms a timer at this.
pub fn Reactor(comptime EpT: type, comptime TrT: type, comptime max: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct { ep: *EpT, tr: *TrT };

        entries: [max]Entry = undefined,
        n: usize = 0,

        pub fn add(self: *Self, ep: *EpT, tr: *TrT) void {
            self.entries[self.n] = .{ .ep = ep, .tr = tr };
            self.n += 1;
        }

        /// One cooperative pass over every registered endpoint.
        pub fn tick(self: *Self, scratch: []u8, now: i64) void {
            for (self.entries[0..self.n]) |e| pump(e.ep, e.tr, scratch, now);
        }

        /// Earliest `pollDeadline` across endpoints whose connections expose it.
        pub fn deadline(self: *Self, now: i64) ?i64 {
            var earliest: ?i64 = null;
            for (self.entries[0..self.n]) |e| {
                for (e.ep.conns[0..], e.ep.used[0..]) |*c, u| {
                    if (!u) continue;
                    if (c.pollDeadline(now)) |d| earliest = if (earliest) |x| @min(x, d) else d;
                }
            }
            return earliest;
        }
    };
}

const testing = std.testing;
const sim = @import("sim.zig");
const Config = @import("config").Config;
const Endpoint = @import("proto").endpoint.Endpoint;
const channels = @import("proto").schema.channels;
const session = @import("proto").session;

const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = Config{ .channels = Schema, .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };
const TestEndpoint = Endpoint(Cfg);

test "reactor services client+server in one loop, reliable delivery over loss" {
    const alloc = testing.allocator;
    const link = try alloc.create(sim.DefaultLink);
    defer alloc.destroy(link);
    link.* = .{ .params = .{ .latency_ms = 40, .jitter_ms = 20, .loss_permille = 200, .seed = 0x9 }, .prng = std.Random.DefaultPrng.init(0x9) };
    const client = try alloc.create(TestEndpoint);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(TestEndpoint);
    defer alloc.destroy(server);
    server.* = .{};

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = 2 };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = 1 };

    var r = Reactor(TestEndpoint, sim.Transport(sim.DefaultLink), 2){};
    r.add(client, &ctx);
    r.add(server, &stx);

    const N: u32 = 100;
    var scratch: [session.mtu]u8 = undefined;
    var out: [64]u8 = undefined;
    var queued: u32 = 0;
    var got: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 4000 and got < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(2, .rel, &b) catch break;
        }
        r.tick(&scratch, now);
        while (server.receiveRawFrom(1, .rel, &out)) |_| got += 1;
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), got);
}
