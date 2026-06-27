//! discovery - connectionless messages for server browsing / NAT-punch coordination.
//! A client can ping a server before connecting; the server answers with its info and
//! allocates no connection slot - so a spoofed-source flood costs nothing.

const std = @import("std");
const magnet = @import("magnet");

const Ping = struct { magic: u32 };
const Info = struct { players: u16, map: u8 };

const Schema = magnet.proto.channels(.{ .game = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = magnet.Config{ .channels = Schema, .limits = .{ .unconnected_cap = 8 } }; // enable the feature
const Endpoint = magnet.Endpoint(Cfg);
const client_addr = 1;
const server_addr = 2;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const client = try gpa.create(Endpoint);
    defer gpa.destroy(client);
    client.* = .{};
    const server = try gpa.create(Endpoint);
    defer gpa.destroy(server);
    server.* = .{};

    var buf: [256]u8 = undefined;

    // client → server: a discovery ping, carried connectionless
    client.sendUnconnected(server_addr, Ping{ .magic = 0xCAFE });
    while (client.pollTransmit(&buf, 0)) |d| server.feedFrom(client_addr, buf[0..d.len], 0);

    const ping = server.receiveUnconnected(Ping).?;
    std.debug.print("discovery: server got a ping (magic 0x{X}), live connections = {d}\n", .{
        ping.msg.magic, server.liveCount(),
    });

    // server → client: its info, also connectionless
    server.sendUnconnected(ping.addr, Info{ .players = 7, .map = 3 });
    while (server.pollTransmit(&buf, 0)) |d| client.feedFrom(server_addr, buf[0..d.len], 0);

    const info = client.receiveUnconnected(Info).?;
    std.debug.print("  client learned: {d} players on map {d} - no connection opened either side\n", .{
        info.msg.players, info.msg.map,
    });
}
