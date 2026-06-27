//! udp_server - the same sans-IO core, now over a real socket. Two `std.Io` UDP sockets
//! on loopback exchange a datagram through the actual kernel network stack. (A real
//! server loops this with `magnet.serve`; here we do one round-trip and stop.)

const std = @import("std");
const magnet = @import("magnet");
const io = magnet.runtime.io;
const net = std.Io.net;

const Schema = magnet.proto.channels(.{ .msg = .{ .mode = .unreliable, .Message = void } });
const Session = magnet.proto.Session(magnet.Config{ .channels = Schema });

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const ioz = threaded.io();

    var saddr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server_sock = saddr.bind(ioz, .{ .mode = .dgram }) catch {
        std.debug.print("udp_server: skipped (sockets unavailable in this sandbox)\n", .{});
        return;
    };
    defer server_sock.close(ioz);
    var caddr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var client_sock = caddr.bind(ioz, .{ .mode = .dgram }) catch return;
    defer client_sock.close(ioz);

    const gpa = std.heap.page_allocator;
    const client = try gpa.create(Session);
    defer gpa.destroy(client);
    client.* = .{};
    client.setup();
    const server = try gpa.create(Session);
    defer gpa.destroy(server);
    server.* = .{};
    server.setup();

    // client → wire: build a datagram and send it over the real socket
    client.sendRaw(.msg, "hello over UDP") catch {};
    var buf: [1200]u8 = undefined;
    var dest = server_sock.address;
    while (client.pollTransmit(&buf, 0)) |len| client_sock.send(ioz, &dest, buf[0..len]) catch {};

    // server: receive from the kernel, feed the sans-IO core, read the message back out
    const msg = try server_sock.receive(ioz, &buf);
    server.feed(msg.data, 0);
    var out: [64]u8 = undefined;
    const n = server.receiveRaw(.msg, &out).?;

    std.debug.print("udp_server: received \"{s}\" over real loopback UDP\n", .{out[0..n]});
}
