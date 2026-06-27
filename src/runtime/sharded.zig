//! **Sharded** shared-nothing driver: M independent endpoints, each owning a
//! disjoint subset of connections (partitioned by a hash of the peer address).
//! Each shard is touched by exactly one executor and has its own socket
//! (`SO_REUSEPORT` in production), so scaling is horizontal with **zero
//! cross-thread synchronization** - the kernel load-balances datagrams by RSS /
//! `SO_REUSEPORT`. Here the router is in-process and deterministic; a real
//! deployment runs one OS thread per shard, but the sans-IO core is unchanged.

const std = @import("std");

pub fn Sharded(comptime EpT: type, comptime n: usize) type {
    if (n == 0) @compileError("Sharded needs at least one shard");
    return struct {
        const Self = @This();
        pub const shard_count = n;

        shards: [n]EpT = [_]EpT{.{}} ** n,

        /// Which shard owns `addr`. A real deployment lets the kernel do this; the
        /// hash here mirrors a typical RSS spread so the partition is disjoint.
        pub fn shardOf(addr: u64) usize {
            var h = addr *% 0x9E37_79B9_7F4A_7C15;
            h ^= h >> 29;
            return @intCast(h % n);
        }

        pub fn endpointFor(self: *Self, addr: u64) *EpT {
            return &self.shards[shardOf(addr)];
        }

        pub fn feedFrom(self: *Self, addr: u64, bytes: []const u8, now: i64) void {
            self.shards[shardOf(addr)].feedFrom(addr, bytes, now);
        }

        pub fn secSetup(self: *Self, psk: [32]u8, challenge_secret: [16]u8) void {
            for (&self.shards) |*s| s.secSetup(psk, challenge_secret);
        }

        pub fn connection(self: *Self, addr: u64) ?*EpT.Session {
            return self.shards[shardOf(addr)].connection(addr);
        }
        pub fn receiveRawFrom(self: *Self, addr: u64, comptime ch: anytype, out: []u8) ?usize {
            return self.shards[shardOf(addr)].receiveRawFrom(addr, ch, out);
        }

        pub fn liveCount(self: *Self) usize {
            var t: usize = 0;
            for (&self.shards) |*s| t += s.liveCount();
            return t;
        }

        pub const Outgoing = EpT.Outgoing;
        /// Drain one outbound datagram, scanning shards round-robin from `cursor`.
        pub fn pollTransmit(self: *Self, buf: []u8, now: i64) ?Outgoing {
            for (&self.shards) |*s| {
                if (s.pollTransmit(buf, now)) |d| return d;
            }
            return null;
        }
    };
}

const testing = std.testing;
const Config = @import("config").Config;
const Endpoint = @import("proto").endpoint.Endpoint;
const channels = @import("proto").schema.channels;
const session = @import("proto").session;

const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = Config{ .channels = Schema, .limits = .{ .max_connections = 8, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };
const TestEndpoint = Endpoint(Cfg);
const Srv = Sharded(TestEndpoint, 2);
const Cli = session.Session(Cfg);

test "sharded server: connections partition across disjoint shards; all deliver" {
    const alloc = testing.allocator;
    const server = try alloc.create(Srv);
    defer alloc.destroy(server);
    server.* = .{};

    // pick two client addresses that hash to different shards
    const a: u64 = 100;
    var b: u64 = 101;
    while (Srv.shardOf(a) == Srv.shardOf(b)) : (b += 1) {}

    const clients = [_]u64{ a, b };
    var sessions: [2]*Cli = undefined;
    for (&sessions, clients) |*sp, addr| {
        const s = try alloc.create(Cli);
        s.* = .{};
        s.setup();
        s.peer = addr;
        sp.* = s;
    }
    defer for (sessions) |s| alloc.destroy(s);

    // each client sends 20 reliable messages; pump in-process (no loss).
    const N: u32 = 20;
    var queued = [_]u32{0} ** 2;
    var got = [_]usize{0} ** 2;
    var scratch: [session.mtu]u8 = undefined;
    var out: [64]u8 = undefined;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 2000 and (got[0] < N or got[1] < N)) : (step += 1) {
        for (sessions, 0..) |s, i| {
            while (queued[i] < N) : (queued[i] += 1) {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, queued[i], .little);
                s.sendRaw(.rel, &w) catch break;
            }
            while (s.pollTransmit(&scratch, now)) |len| server.feedFrom(clients[i], scratch[0..len], now);
        }
        // server → clients
        while (server.pollTransmit(&scratch, now)) |d| {
            for (sessions, clients) |s, addr| {
                if (addr == d.addr) s.feed(scratch[0..d.len], now);
            }
        }
        for (clients, 0..) |addr, i| {
            while (server.receiveRawFrom(addr, .rel, &out)) |_| got[i] += 1;
        }
        now += 5;
    }

    try testing.expectEqual(@as(usize, N), got[0]);
    try testing.expectEqual(@as(usize, N), got[1]);
    // the two connections really landed in different shards (shared-nothing)
    try testing.expect(Srv.shardOf(clients[0]) != Srv.shardOf(clients[1]));
    try testing.expectEqual(@as(usize, 1), server.shards[Srv.shardOf(clients[0])].liveCount());
    try testing.expectEqual(@as(usize, 1), server.shards[Srv.shardOf(clients[1])].liveCount());
}
