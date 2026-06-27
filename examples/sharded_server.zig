//! sharded_server - scale across cores with zero shared state. The server is split into
//! N shards, each owning a disjoint subset of connections (partitioned by address), each
//! touched by exactly one executor. No locks, no cross-shard synchronization - the
//! kernel load-balances datagrams via SO_REUSEPORT in production.

const std = @import("std");
const magnet = @import("magnet");

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = magnet.Config{ .channels = Schema, .limits = .{ .max_connections = 64 } };
const Endpoint = magnet.Endpoint(Cfg);
const Server = magnet.runtime.sharded.Sharded(Endpoint, 4); // 4 shards

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const server = try gpa.create(Server);
    defer gpa.destroy(server);
    server.* = .{};

    // 200 clients connect; each lands in exactly one shard, decided by its address.
    var per_shard = [_]usize{0} ** 4;
    var addr: u64 = 1;
    while (addr <= 200) : (addr += 1) {
        per_shard[Server.shardOf(addr)] += 1;
        server.feedFrom(addr, &.{ 0x00, 0x00 }, 0); // a stray datagram opens the slot
    }

    std.debug.print("sharded_server: 200 connections spread across 4 shared-nothing shards:\n", .{});
    std.debug.print("  shard sizes = {any}  (total live = {d})\n", .{ per_shard, server.liveCount() });
}
