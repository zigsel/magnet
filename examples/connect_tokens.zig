//! connect_tokens - identity without a password. A backend (matchmaker) signs a short
//! connect token authorizing a client for specific servers; the client presents it in
//! the handshake and the server derives the session keys from it. Expired, forged, or
//! replayed tokens are rejected on the wire.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const poll = magnet.runtime.poll;
const token = magnet.proto.conn.token;

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
const Cfg = magnet.Config{ .channels = Schema, .protocol_id = 0xA17, .security = .{ .mode = .aead, .tokens = true } };
const Endpoint = magnet.Endpoint(Cfg);

const issuer_key = [_]u8{0x5A} ** 32; // shared backend ↔ dedicated servers
const challenge_secret = [_]u8{0xC0} ** 16;
const client_addr = 1;
const server_addr = 2;

pub fn main() !void {
    // --- the backend, offline, mints a token good only for `server_addr` ---
    const tok = token.issue(issuer_key, 0xA17, 1_000_000, [_]u8{0x11} ** token.nonce_len, .{
        .client_id = 42,
        .timeout_s = 30,
        .c2s_key = [_]u8{0xC2} ** 32,
        .s2c_key = [_]u8{0x52} ** 32,
        .user_data = [_]u8{0} ** token.user_data_len,
        .num_server_addrs = 1,
        .server_addrs = .{ server_addr, 0, 0, 0 },
    });

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

    server.secSetupTokens(issuer_key, challenge_secret, server_addr);
    var t = tok;
    _ = client.connectToWithToken(server_addr, &t); // keys derive from the token

    var to_srv: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var to_cli: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [1200]u8 = undefined;
    var out: [64]u8 = undefined;
    var sent: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    while (delivered < 15 and now < 5000) : (now += 5) {
        while (sent < 15) : (sent += 1) client.sendRawTo(server_addr, .rel, std.mem.asBytes(&sent)) catch break;
        poll.flushAll(client, &to_srv, &scratch, now);
        poll.recvAll(server, &to_cli, &scratch, now);
        poll.flushAll(server, &to_cli, &scratch, now);
        poll.recvAll(client, &to_srv, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| delivered += 1;
    }

    std.debug.print("connect_tokens: token-authenticated channel up, {d}/15 delivered, client 42 admitted\n", .{delivered});
}
