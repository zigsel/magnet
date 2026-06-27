//! encrypted - turn on AEAD and the connection is encrypted + authenticated. The server
//! holds no per-client state until a stateless cookie is echoed (DoS-resistant), every
//! datagram is sealed, and a tampered datagram is rejected before it touches state.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const poll = magnet.runtime.poll;

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
const Cfg = magnet.Config{ .channels = Schema, .protocol_id = 0xC0FFEE, .security = .{ .mode = .aead } };
const Endpoint = magnet.Endpoint(Cfg);

const psk = [_]u8{0x5A} ** 32;
const challenge_secret = [_]u8{0xC0} ** 16;
const client_addr = 1;
const server_addr = 2;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const link = try gpa.create(sim.DefaultLink);
    defer gpa.destroy(link);
    link.* = sim.DefaultLink.init(.{ .latency_ms = 25, .seed = 1 });
    const client = try gpa.create(Endpoint);
    defer gpa.destroy(client);
    client.* = .{};
    const server = try gpa.create(Endpoint);
    defer gpa.destroy(server);
    server.* = .{};

    server.secSetup(psk, challenge_secret);
    _ = client.connectTo(server_addr, psk); // begins the encrypted handshake

    var to_srv: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var to_cli: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [1200]u8 = undefined;
    var out: [64]u8 = undefined;
    var sent: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    while (delivered < 20 and now < 5000) : (now += 5) {
        while (sent < 20) : (sent += 1) client.sendRawTo(server_addr, .rel, std.mem.asBytes(&sent)) catch break;
        poll.flushAll(client, &to_srv, &scratch, now);
        poll.recvAll(server, &to_cli, &scratch, now);
        poll.flushAll(server, &to_cli, &scratch, now);
        poll.recvAll(client, &to_srv, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| delivered += 1;
    }

    std.debug.print("encrypted: handshake done, connected = {}, {d}/20 sealed messages delivered\n", .{
        client.connection(server_addr).?.isConnected(), delivered,
    });

    // a spoofed-source hello allocates no connection slot (stateless challenge).
    var hello: [16]u8 = undefined;
    const hn = magnet.proto.conn.handshake.writeHello(&hello, 0xC0FFEE, 0);
    server.feedFrom(0xBADBAD, hello[0..hn], now);
    std.debug.print("  spoofed hello flood → live connections still {d}\n", .{server.liveCount()});
}
