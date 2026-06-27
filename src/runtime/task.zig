//! **Task** driver: one logical task per connection (a fiber or OS thread under a
//! real `std.Io`). A connection's state is owned by exactly one task, so its hot
//! path stays lock-free. When the application and network run on *different* tasks,
//! they hand off across a single lock-free SPSC queue (`core/spsc.zig`) - the only
//! cross-thread structure in magnet. This file provides that boundary and the
//! per-connection pump; the actual task spawning is the `std.Io` runtime's job.

const std = @import("std");
const Spsc = @import("core").Spsc;

/// Pump a single connection (`Session`) over a single-peer transport once:
/// `transport.recvOne(buf, now) ?usize` / `transport.sendOne(bytes, now)`.
pub fn pumpSession(s: anytype, transport: anytype, scratch: []u8, now: i64) void {
    while (transport.recvOne(scratch, now)) |len| s.feed(scratch[0..len], now);
    while (s.pollTransmit(scratch, now)) |len| transport.sendOne(scratch[0..len], now);
}

/// The app↔net boundary when topology separates them: the application thread
/// enqueues outbound messages and drains inbound ones; the network thread does the
/// mirror. Bounded and lock-free (one producer + one consumer per direction).
pub fn Bridge(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        to_net: Spsc(T, cap) = .{}, // app → net (outbound intents)
        to_app: Spsc(T, cap) = .{}, // net → app (received messages)

        // application side
        pub fn send(self: *Self, msg: T) bool {
            return self.to_net.push(msg);
        }
        pub fn poll(self: *Self) ?T {
            return self.to_app.pop();
        }
        // network side
        pub fn nextOutbound(self: *Self) ?T {
            return self.to_net.pop();
        }
        pub fn deliver(self: *Self, msg: T) bool {
            return self.to_app.push(msg);
        }
    };
}

const testing = std.testing;

test "app↔net bridge round-trips both directions" {
    var b = Bridge(u32, 16){};
    // app sends → net drains
    try testing.expect(b.send(7));
    try testing.expect(b.send(8));
    try testing.expectEqual(@as(u32, 7), b.nextOutbound().?);
    try testing.expectEqual(@as(u32, 8), b.nextOutbound().?);
    try testing.expect(b.nextOutbound() == null);
    // net delivers → app polls
    try testing.expect(b.deliver(42));
    try testing.expectEqual(@as(u32, 42), b.poll().?);
    try testing.expect(b.poll() == null);
}

const BridgeT = Bridge(u32, 1024);
const stress_n: u32 = 100_000;

fn producer(b: *BridgeT) void {
    var i: u32 = 0;
    while (i < stress_n) : (i += 1) {
        while (!b.send(i)) {}
    }
}

test "app↔net bridge: threaded handoff preserves order and count" {
    var b = BridgeT{};
    const t = try std.Thread.spawn(.{}, producer, .{&b});
    var expect: u32 = 0;
    while (expect < stress_n) {
        if (b.nextOutbound()) |v| {
            try testing.expectEqual(expect, v); // strict FIFO across the thread boundary
            expect += 1;
        }
    }
    t.join();
}

// ---- per-connection pump over the sim, modeling one task per connection ----

const sim = @import("sim.zig");
const Config = @import("config").Config;
const channels = @import("proto").schema.channels;
const session = @import("proto").session;

const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = Config{ .channels = Schema, .limits = .{ .max_connections = 1, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };
const Sess = session.Session(Cfg);

// adapts one side of a sim Link to the single-peer `recvOne`/`sendOne` contract.
fn LinkSide(comptime LinkT: type) type {
    return struct {
        link: *LinkT,
        recv_dir: sim.Dir,
        send_dir: sim.Dir,
        pub fn recvOne(self: *@This(), buf: []u8, now: i64) ?usize {
            return self.link.poll(self.recv_dir, now, buf);
        }
        pub fn sendOne(self: *@This(), bytes: []const u8, now: i64) void {
            self.link.send(self.send_dir, bytes, now);
        }
    };
}

test "task pump drives two per-connection sessions to reliable delivery" {
    const alloc = testing.allocator;
    const link = try alloc.create(sim.DefaultLink);
    defer alloc.destroy(link);
    link.* = .{ .params = .{ .latency_ms = 30, .jitter_ms = 10, .loss_permille = 150, .seed = 0x7A }, .prng = std.Random.DefaultPrng.init(0x7A) };
    const a = try alloc.create(Sess);
    defer alloc.destroy(a);
    a.* = .{};
    a.setup();
    const b = try alloc.create(Sess);
    defer alloc.destroy(b);
    b.* = .{};
    b.setup();

    var aside = LinkSide(sim.DefaultLink){ .link = link, .recv_dir = .to_a, .send_dir = .to_b };
    var bside = LinkSide(sim.DefaultLink){ .link = link, .recv_dir = .to_b, .send_dir = .to_a };

    const N: u32 = 80;
    var scratch: [session.mtu]u8 = undefined;
    var out: [64]u8 = undefined;
    var queued: u32 = 0;
    var got: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 4000 and got < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var w: [4]u8 = undefined;
            std.mem.writeInt(u32, &w, queued, .little);
            a.sendRaw(.rel, &w) catch break;
        }
        pumpSession(a, &aside, &scratch, now); // task A
        pumpSession(b, &bside, &scratch, now); // task B
        while (b.receiveRaw(.rel, &out)) |_| got += 1;
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), got);
}
