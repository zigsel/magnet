//! migration - connection IDs let a session survive its network address changing under
//! it (a phone moving Wi-Fi → cellular, a NAT rebinding a port). The peer is addressed
//! by an opaque connection id, not its IP, so the server simply follows it to the new
//! address and delivery continues in order, uninterrupted.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const poll = magnet.runtime.poll;

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
const Cfg = magnet.Config{ .channels = Schema, .protocol_id = 0xC1D, .security = .{ .mode = .aead, .connection_ids = true } };
const Endpoint = magnet.Endpoint(Cfg);

const psk = [_]u8{0x5A} ** 32;
const challenge_secret = [_]u8{0xC0} ** 16;
const server_addr = 2;
const addr_before = (0x0A00_0001 << 32) | 5000; // 10.0.0.1:5000
const addr_after = (0x0A00_0001 << 32) | 6000; // …:6000 - same IP, new port

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const link = try gpa.create(sim.DefaultLink);
    defer gpa.destroy(link);
    link.* = sim.DefaultLink.init(.{ .latency_ms = 20, .seed = 1 });
    const client = try gpa.create(Endpoint);
    defer gpa.destroy(client);
    client.* = .{};
    const server = try gpa.create(Endpoint);
    defer gpa.destroy(server);
    server.* = .{};

    server.secSetup(psk, challenge_secret);
    _ = client.connectTo(server_addr, psk);

    var to_srv: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var to_cli: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = addr_before };

    var scratch: [1200]u8 = undefined;
    var out: [64]u8 = undefined;
    var sent: u32 = 0;
    var expected: u32 = 0;
    var in_order = true;
    var now: i64 = 0;
    while (expected < 30 and now < 8000) : (now += 5) {
        while (sent < 30) : (sent += 1) client.sendRawTo(server_addr, .rel, std.mem.asBytes(&sent)) catch break;
        if (expected == 12) to_cli.peer_addr = addr_after; // ← the client's address changes mid-stream
        poll.flushAll(client, &to_srv, &scratch, now);
        poll.recvAll(server, &to_cli, &scratch, now);
        poll.flushAll(server, &to_cli, &scratch, now);
        poll.recvAll(client, &to_srv, &scratch, now);
        if (server.connection(to_cli.peer_addr)) |c| {
            while (c.receiveRaw(.rel, &out)) |_| {
                if (std.mem.readInt(u32, out[0..4], .little) != expected) in_order = false;
                expected += 1;
            }
        }
    }

    std.debug.print("migration: address changed at msg 12; {d}/30 delivered in order = {}\n", .{ expected, in_order });
    std.debug.print("  one connection throughout = {}\n", .{server.liveCount() == 1});
}
