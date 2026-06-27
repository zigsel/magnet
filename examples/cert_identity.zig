//! cert_identity - authenticated key agreement from Ed25519 certificates. A CA signs
//! each peer's public key; the two sides verify each other's cert and derive a shared
//! session key by ECDH. No password to pre-share - and the derived key flows straight
//! into the normal encrypted transport.

const std = @import("std");
const magnet = @import("magnet");
const sim = magnet.runtime.sim;
const poll = magnet.runtime.poll;
const identity = magnet.proto.conn.identity;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;

const Schema = magnet.proto.channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
const Cfg = magnet.Config{ .channels = Schema, .protocol_id = 0xCE7, .security = .{ .mode = .aead } };
const Endpoint = magnet.Endpoint(Cfg);

const challenge_secret = [_]u8{0xC0} ** 16;
const client_addr = 1;
const server_addr = 2;

pub fn main() !void {
    // --- trust setup: a CA, two keypairs, two certs ---
    const ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x70} ** 32);
    const ckey = try X25519.KeyPair.generateDeterministic([_]u8{0xC0} ** 32);
    const skey = try X25519.KeyPair.generateDeterministic([_]u8{0x50} ** 32);
    const ccert = try identity.issue(ca, ckey.public_key, 1_000_000);
    const scert = try identity.issue(ca, skey.public_key, 1_000_000);

    // each side verifies the peer cert and derives the same master key (no PSK shared).
    const client_master = try identity.agree(ckey, &ccert, &scert, ca.public_key.toBytes(), 0, true);
    const server_master = try identity.agree(skey, &scert, &ccert, ca.public_key.toBytes(), 0, false);

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

    server.secSetup(server_master, challenge_secret); // server keys from the cert master
    _ = client.connectTo(server_addr, client_master); // client keys from the same master

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

    std.debug.print("cert_identity: cert-verified ECDH, masters match = {}, {d}/15 delivered\n", .{
        std.mem.eql(u8, &client_master, &server_master), delivered,
    });
}
