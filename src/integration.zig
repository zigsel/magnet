//! Integration tests - the only place allowed to bridge `proto/` and `runtime/`
//! (the sans-IO inversion holds: `proto/` itself never imports `runtime/`).
//! Everything runs through the Config-driven `Endpoint(cfg)` / `Session(cfg)`.

const std = @import("std");
const Config = @import("config").Config;
const Endpoint = @import("proto").Endpoint;
const session = @import("proto").session;
const channels = @import("proto").channels;
const trace = @import("trace");
const handshake = @import("proto").conn.handshake;
const sim = @import("runtime").sim;
const poll = @import("runtime").poll;
const reactor = @import("runtime").reactor;

const testing = std.testing;

// A 2-channel config used by the byte-oriented tests (raw API).
const NetSchema = channels(.{
    .un = .{ .mode = .unreliable, .Message = void },
    .rel = .{ .mode = .reliable_ordered, .Message = void },
});
const NetCfg = Config{ .channels = NetSchema, .limits = .{
    .max_connections = 4,
    .channel_cap = 128,
    .max_payload = 256,
    .bridge_cap = 1024,
    .recvpn_cap = 256,
} };
const NetEndpoint = Endpoint(NetCfg);

fn makeLink(alloc: std.mem.Allocator, params: sim.Params) !*sim.DefaultLink {
    const link = try alloc.create(sim.DefaultLink);
    link.* = .{ .params = params, .prng = std.Random.DefaultPrng.init(params.seed) };
    return link;
}
fn makeNet(alloc: std.mem.Allocator) !*NetEndpoint {
    const e = try alloc.create(NetEndpoint);
    e.* = .{};
    return e;
}

const server_addr: u64 = 2;
const client_addr: u64 = 1;

// ---- unreliable echo ----

const EchoResult = struct { received: usize, ok: bool };

fn runEcho(alloc: std.mem.Allocator, loss_permille: u32, seed: u64) !EchoResult {
    const N: u32 = 200;
    const link = try makeLink(alloc, .{ .latency_ms = 50, .jitter_ms = 20, .loss_permille = loss_permille, .seed = seed });
    defer alloc.destroy(link);
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var seen = [_]bool{false} ** N;
    var received: usize = 0;
    var ok = true;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var next_q: u32 = 0;

    var now: i64 = 0;
    var step: usize = 0;
    while (step < 200) : (step += 1) {
        var burst: u32 = 0;
        while (next_q < N and burst < 16) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, next_q, .little);
            client.sendRawTo(server_addr, .un, &b) catch break;
            next_q += 1;
            burst += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .un, &out)) |len| server.sendRawTo(client_addr, .un, out[0..len]) catch {};
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (client.receiveRawFrom(server_addr, .un, &out)) |len| {
            if (len != 4) {
                ok = false;
                continue;
            }
            const idx = std.mem.readInt(u32, out[0..4], .little);
            if (idx >= N or seen[idx]) {
                ok = false;
                continue;
            }
            seen[idx] = true;
            received += 1;
        }
        now += 5;
    }
    return .{ .received = received, .ok = ok };
}

test "echo: 0% loss delivers all 200, distinct, uncorrupted" {
    const r = try runEcho(testing.allocator, 0, 0xE0);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(usize, 200), r.received);
}

test "echo: heavy loss drops some, none corrupt, deterministic" {
    const r = try runEcho(testing.allocator, 700, 0xBEEF);
    try testing.expect(r.ok);
    try testing.expect(r.received < 200);
    const r2 = try runEcho(testing.allocator, 700, 0xBEEF);
    try testing.expectEqual(r.received, r2.received);
}

// ---- reliable-ordered + congestion control ----

const RelResult = struct { delivered: usize, ok: bool, rtt: i64, max_inflight: u32, cong: u32 };

fn runReliable(alloc: std.mem.Allocator, loss_permille: u32, seed: u64, payload_len: usize) !RelResult {
    const N: u32 = 500;
    const link = try makeLink(alloc, .{ .latency_ms = 50, .jitter_ms = 30, .loss_permille = loss_permille, .dup_permille = 50, .seed = seed });
    defer alloc.destroy(link);
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var payload = [_]u8{0} ** 256;
    var next_q: u32 = 0;
    var expected: u32 = 0;
    var delivered: usize = 0;
    var ok = true;
    var max_inflight: u32 = 0;

    var now: i64 = 0;
    var step: usize = 0;
    while (step < 8000 and delivered < N) : (step += 1) {
        var burst: u32 = 0;
        while (next_q < N and burst < 16) {
            std.mem.writeInt(u32, payload[0..4], next_q, .little);
            client.sendRawTo(server_addr, .rel, payload[0..payload_len]) catch break;
            next_q += 1;
            burst += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |len| {
            if (len != payload_len) {
                ok = false;
                continue;
            }
            const idx = std.mem.readInt(u32, out[0..4], .little);
            if (idx != expected) ok = false;
            expected += 1;
            delivered += 1;
        }
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        if (client.connection(server_addr)) |c| {
            if (c.bytesInFlight() > max_inflight) max_inflight = c.bytesInFlight();
        }
        now += 5;
    }

    const c = client.connection(server_addr);
    return .{
        .delivered = delivered,
        .ok = ok,
        .rtt = if (c) |x| x.rttMs() else 0,
        .max_inflight = max_inflight,
        .cong = if (c) |x| x.congestionEvents() else 0,
    };
}

test "reliable-ordered: exactly-once, in order, under 30% loss + reorder + dup" {
    const r = try runReliable(testing.allocator, 300, 0xC0FFEE, 4);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(usize, 500), r.delivered);
    try testing.expect(r.rtt >= 80 and r.rtt <= 200);
}

test "congestion control: in-flight bounded, cwnd shrinks on loss" {
    const r = try runReliable(testing.allocator, 300, 0xCC1234, 200);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(usize, 500), r.delivered);
    try testing.expect(r.cong >= 5); // loss repeatedly shrank cwnd
    try testing.expect(r.rtt >= 80 and r.rtt <= 220);
    try testing.expect(r.max_inflight <= 30_000); // bounded by send window - no leak
}

// ---- typed multi-channel session ----

const GameSchema = channels(.{
    .moves = .{ .mode = .unreliable_sequenced, .Message = u32 },
    .events = .{ .mode = .reliable_unordered, .Message = u32 },
    .chat = .{ .mode = .reliable_ordered, .Message = u32 },
});
const GameCfg = Config{ .channels = GameSchema, .limits = .{ .max_payload = 64, .channel_cap = 128, .bridge_cap = 1024, .recvpn_cap = 256 } };

const TypedResult = struct { chat_ok: bool, chat_n: usize, events_n: usize };

fn runTypedSession(alloc: std.mem.Allocator, loss_permille: u32, seed: u64) !TypedResult {
    const M: u32 = 100;
    const S = session.Session(GameCfg);
    const link = try makeLink(alloc, .{ .latency_ms = 50, .jitter_ms = 30, .loss_permille = loss_permille, .dup_permille = 50, .seed = seed });
    defer alloc.destroy(link);
    const a = try alloc.create(S);
    defer alloc.destroy(a);
    a.* = .{};
    a.setup();
    const b = try alloc.create(S);
    defer alloc.destroy(b);
    b.* = .{};
    b.setup();

    var scratch: [session.mtu]u8 = undefined;
    var next_chat: u32 = 0;
    var next_events: u32 = 0;
    var chat_expected: u32 = 0;
    var chat_ok = true;
    var chat_n: usize = 0;
    var events_seen = [_]bool{false} ** 100;
    var events_n: usize = 0;

    var now: i64 = 0;
    var step: usize = 0;
    while (step < 4000 and (chat_n < M or events_n < M)) : (step += 1) {
        var burst: u32 = 0;
        while (burst < 8 and (next_chat < M or next_events < M)) : (burst += 1) {
            if (next_chat < M) {
                a.send(.chat, next_chat) catch break;
                next_chat += 1;
            }
            if (next_events < M) {
                a.send(.events, next_events) catch break;
                next_events += 1;
            }
        }
        while (a.pollTransmit(&scratch, now)) |len| link.send(.to_b, scratch[0..len], now);
        while (link.poll(.to_b, now, &scratch)) |len| b.feed(scratch[0..len], now);
        while (b.receive(.chat)) |v| {
            if (v != chat_expected) chat_ok = false;
            chat_expected += 1;
            chat_n += 1;
        }
        while (b.receive(.events)) |v| {
            if (v < M and !events_seen[v]) {
                events_seen[v] = true;
                events_n += 1;
            }
        }
        while (b.pollTransmit(&scratch, now)) |len| link.send(.to_a, scratch[0..len], now);
        while (link.poll(.to_a, now, &scratch)) |len| a.feed(scratch[0..len], now);
        now += 5;
    }
    return .{ .chat_ok = chat_ok, .chat_n = chat_n, .events_n = events_n };
}

test "typed multi-channel session over a lossy link: per-channel reliable delivery" {
    const r = try runTypedSession(testing.allocator, 300, 0x5E5510);
    try testing.expect(r.chat_ok); // reliable-ordered: strictly in order
    try testing.expectEqual(@as(usize, 100), r.chat_n);
    try testing.expectEqual(@as(usize, 100), r.events_n); // reliable-unordered: all, deduped
}

// ---- security (AEAD handshake, stateless challenge, replay, tamper) ----

const proto_id: u64 = 0x0A17_4747;
const SecCfg = Config{
    .channels = NetSchema,
    .protocol_id = proto_id,
    .tracer = trace.Counters,
    .security = .{ .mode = .aead },
    .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 256, .bridge_cap = 1024, .recvpn_cap = 256 },
};
const SecNet = Endpoint(SecCfg);

const psk = [_]u8{0x5A} ** 32;
const challenge_secret = [_]u8{0xC0} ** 16;

fn makeSecNet(alloc: std.mem.Allocator) !*SecNet {
    const e = try alloc.create(SecNet);
    e.* = .{};
    return e;
}

test "aead: encrypted handshake completes, reliable data flows; spoof allocates no slot; tamper + replay rejected" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 30, .jitter_ms = 0, .loss_permille = 0, .seed = 0x5EC });
    defer alloc.destroy(link);
    const client = try makeSecNet(alloc);
    defer alloc.destroy(client);
    const server = try makeSecNet(alloc);
    defer alloc.destroy(server);
    server.secSetup(psk, challenge_secret);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    _ = client.connectTo(server_addr, psk);

    const N: u32 = 50;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var payload = [_]u8{0} ** 16;
    var next_q: u32 = 0;
    var expected: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 600 and delivered < N) : (step += 1) {
        while (next_q < N) {
            std.mem.writeInt(u32, payload[0..4], next_q, .little);
            client.sendRawTo(server_addr, .rel, &payload) catch break;
            next_q += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |len| {
            try testing.expectEqual(@as(usize, 16), len);
            const idx = std.mem.readInt(u32, out[0..4], .little);
            try testing.expectEqual(expected, idx); // reliable-ordered, exactly-once
            expected += 1;
            delivered += 1;
        }
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), delivered); // encrypted reliable delivery
    try testing.expectEqual(@as(usize, 1), server.liveCount()); // exactly one validated peer
    try testing.expect(client.connection(server_addr).?.isConnected());

    // Spoofed-source hello must allocate NO slot (stateless challenge).
    var hello: [16]u8 = undefined;
    const hn = handshake.writeHello(&hello, proto_id, 0);
    server.feedFrom(0xBADBADBAD, hello[0..hn], now);
    server.feedFrom(0xBADBADBAD, hello[0..hn], now);
    try testing.expectEqual(@as(usize, 1), server.liveCount()); // still just the real client

    // Tampered datagram: flip a ciphertext byte → AEAD rejects pre-state-change.
    std.mem.writeInt(u32, payload[0..4], 9999, .little);
    try client.sendRawTo(server_addr, .rel, &payload);
    var dg: [session.mtu]u8 = undefined;
    const d = client.pollTransmit(&dg, now).?;
    const sconn = server.connection(client_addr).?;
    const drops_before = sconn.tracer.drops;
    var bad = dg;
    bad[d.len - 1] ^= 0xFF; // corrupt the AEAD tag
    server.feedFrom(client_addr, bad[0..d.len], now);
    try testing.expect(sconn.tracer.drops > drops_before); // counted as a drop
    try testing.expect(server.receiveRawFrom(client_addr, .rel, &out) == null); // nothing delivered

    // Replay of a *valid* datagram is rejected by the replay window.
    server.feedFrom(client_addr, dg[0..d.len], now); // first delivery (the real one)
    const got = server.receiveRawFrom(client_addr, .rel, &out);
    try testing.expect(got != null);
    const drops_mid = sconn.tracer.drops;
    server.feedFrom(client_addr, dg[0..d.len], now); // exact replay
    try testing.expect(sconn.tracer.drops > drops_mid); // replay dropped
    try testing.expect(server.receiveRawFrom(client_addr, .rel, &out) == null);
}

// ---- connection IDs & migration ----

const MigCfg = Config{
    .channels = NetSchema,
    .protocol_id = proto_id,
    .tracer = trace.Counters,
    .security = .{ .mode = .aead, .connection_ids = true },
    .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 256, .bridge_cap = 1024, .recvpn_cap = 256 },
};
const MigNet = Endpoint(MigCfg);

fn makeMigNet(alloc: std.mem.Allocator) !*MigNet {
    const e = try alloc.create(MigNet);
    e.* = .{};
    return e;
}

// (ip:u32 << 32 | port:u32) addresses so the rebind heuristic can classify them.
const caddr0: u64 = (0x0A00_0001 << 32) | 5000; // 10.0.0.1:5000
const caddr_port: u64 = (0x0A00_0001 << 32) | 6000; // same IP, new port
const caddr_ip: u64 = (0x0A00_0002 << 32) | 5000; // new IP

test "cid migration: port remap keeps the connection (and RTT); IP change re-validates the path" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 25, .jitter_ms = 0, .loss_permille = 0, .seed = 0xC1D });
    defer alloc.destroy(link);
    const client = try makeMigNet(alloc);
    defer alloc.destroy(client);
    const server = try makeMigNet(alloc);
    defer alloc.destroy(server);
    server.secSetup(psk, challenge_secret);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = caddr0 };

    _ = client.connectTo(server_addr, psk);

    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var payload = [_]u8{0} ** 16;
    var next_q: u32 = 0;
    var expected: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;

    // grabbed once the server session exists; the slot pointer is stable across migration.
    var sconn: ?*MigNet.Session = null;
    var saw_unvalidated = false; // the IP change must briefly de-validate the path

    var phase: usize = 0; // 0: initial, 1: port remap, 2: ip change
    var step: usize = 0;
    // run until all delivered AND the migrated path has re-validated (delivery alone
    // isn't gated by the server's validation, so we must wait for the probe to finish).
    while (step < 1200 and (delivered < 30 or !(sconn != null and sconn.?.pathValidated()))) : (step += 1) {
        // release 10 messages per phase as each phase's delivery target is reached.
        const target: u32 = switch (phase) {
            0 => 10,
            1 => 20,
            else => 30,
        };
        while (next_q < target) {
            std.mem.writeInt(u32, payload[0..4], next_q, .little);
            client.sendRawTo(server_addr, .rel, &payload) catch break;
            next_q += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);

        if (sconn == null) sconn = server.connection(caddr0);
        if (sconn) |sc| {
            while (sc.receiveRaw(.rel, &out)) |_| {
                const idx = std.mem.readInt(u32, out[0..4], .little);
                try testing.expectEqual(expected, idx); // reliable-ordered, exactly-once, across migrations
                expected += 1;
                delivered += 1;
            }
            if (phase == 2 and !sc.pathValidated()) saw_unvalidated = true;
            // advance phases as each batch lands, performing the migration.
            if (phase == 0 and delivered >= 10) {
                try testing.expect(sc.pathValidated()); // initial path validated by the handshake
                stx.peer_addr = caddr_port; // same IP, new port - a pure NAT remap
                phase = 1;
            } else if (phase == 1 and delivered >= 20) {
                try testing.expect(sc.pathValidated()); // port remap did NOT force re-validation
                stx.peer_addr = caddr_ip; // new IP → must trigger path validation
                phase = 2;
            }
        }
        now += 5;
    }

    try testing.expectEqual(@as(usize, 30), delivered); // delivered across both migrations
    try testing.expectEqual(@as(usize, 1), server.liveCount()); // one connection throughout
    try testing.expect(saw_unvalidated); // the IP change paused full send pending validation
    try testing.expect(sconn.?.pathValidated()); // …and the new path was then validated
    try testing.expectEqual(caddr_ip, server.connection(caddr_ip).?.peer); // session followed the address
}

// ---- cross-driver equivalence (model-agnosticism is a tested invariant) ----

const DriverKind = enum { poll, reactor };

// Run an identical seeded reliable-delivery scenario under a given driver; returns
// the delivered count. The sans-IO core is the same, so every driver must agree.
fn runUnderDriver(alloc: std.mem.Allocator, kind: DriverKind, loss: u32, seed: u64) !struct { delivered: usize, ordered: bool } {
    const link = try makeLink(alloc, .{ .latency_ms = 40, .jitter_ms = 20, .loss_permille = loss, .seed = seed });
    defer alloc.destroy(link);
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var react = reactor.Reactor(NetEndpoint, sim.Transport(sim.DefaultLink), 2){};
    react.add(client, &ctx);
    react.add(server, &stx);

    const N: u32 = 150;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var queued: u32 = 0;
    var expected: u32 = 0;
    var delivered: usize = 0;
    var ordered = true;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 8000 and delivered < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(server_addr, .rel, &b) catch break;
        }
        switch (kind) {
            // identical call order in both, so the outcomes must match exactly.
            .poll => {
                poll.recvAll(client, &ctx, &scratch, now);
                poll.flushAll(client, &ctx, &scratch, now);
                poll.recvAll(server, &stx, &scratch, now);
                poll.flushAll(server, &stx, &scratch, now);
            },
            .reactor => react.tick(&scratch, now),
        }
        while (server.receiveRawFrom(client_addr, .rel, &out)) |len| {
            if (len != 4) ordered = false;
            const idx = std.mem.readInt(u32, out[0..4], .little);
            if (idx != expected) ordered = false;
            expected += 1;
            delivered += 1;
        }
        now += 5;
    }
    return .{ .delivered = delivered, .ordered = ordered };
}

test "cross-driver equivalence: poll and reactor deliver identically (in order, under loss)" {
    const alloc = testing.allocator;
    const p = try runUnderDriver(alloc, .poll, 250, 0xD1D1);
    const r = try runUnderDriver(alloc, .reactor, 250, 0xD1D1);
    try testing.expect(p.ordered and r.ordered);
    try testing.expectEqual(@as(usize, 150), p.delivered);
    try testing.expectEqual(p.delivered, r.delivered); // same outcome across drivers
}

// ---- observability (live tracer + stats snapshot + dashboard line) ----

const ObsCfg = Config{
    .channels = NetSchema,
    .tracer = trace.Multi(trace.Counters, trace.Log(64)),
    .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 256, .bridge_cap = 1024, .recvpn_cap = 256 },
};
const ObsNet = Endpoint(ObsCfg);

test "observability: tracer counts events, stats snapshot reflects the live path" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 50, .jitter_ms = 20, .loss_permille = 250, .dup_permille = 30, .seed = 0x0B5 });
    defer alloc.destroy(link);
    const client = try alloc.create(ObsNet);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(ObsNet);
    defer alloc.destroy(server);
    server.* = .{};

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    const N: u32 = 200;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var queued: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 6000 and delivered < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(server_addr, .rel, &b) catch break;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| delivered += 1;
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), delivered);

    // the client's tracer (Counters + Log) observed the path
    const cc = client.connection(server_addr).?;
    try testing.expect(cc.tracer.a.packets_sent > 0); // Counters
    try testing.expect(cc.tracer.a.acked_bytes > 0);
    try testing.expect(cc.tracer.a.packets_recv > 0); // saw the ack traffic back
    var evbuf: [64]trace.Event = undefined;
    try testing.expect(cc.tracer.b.drain(&evbuf) > 0); // Log ring captured events

    // live stats snapshot
    const st = client.stats(server_addr).?;
    try testing.expect(st.rtt_ms >= 90 and st.rtt_ms <= 260); // ~2×50ms + jitter
    try testing.expect(st.cwnd_bytes > 0);
    var linebuf: [128]u8 = undefined;
    const line = st.line(&linebuf);
    try testing.expect(std.mem.indexOf(u8, line, "rtt=") != null);
    try testing.expect(std.mem.indexOf(u8, line, "cwnd=") != null);
}

// ---- replication foundations (server→client world sync) ----

const repl_registry = @import("replication").registry;
const ReplWorld = @import("replication").World;
const ReplSnapshot = @import("replication").Snapshot;
const ReplEntityMap = @import("replication").EntityMap;
const interest = @import("replication").interest;
const ReplPriority = @import("replication").Priority;

const RPos = struct { x: i16, y: i16 };
const RVel = struct { dx: i8, dy: i8 };
const RHealth = struct { hp: u16 };
const GameReg = repl_registry(.{ .components = .{ RPos, RVel, RHealth } });
const GameWorld = ReplWorld(GameReg, 64);
const GameSnapshot = ReplSnapshot(GameReg, GameWorld);
const GameMap = ReplEntityMap(GameWorld.Entity, 64);
const Rooms = interest.Rooms(16);

test "replication: server world syncs to a client - changed-only, interest-filtered, budget-bounded" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 40, .jitter_ms = 15, .loss_permille = 150, .seed = 0x12 });
    defer alloc.destroy(link);
    const server = try makeNet(alloc); // reliable transport for snapshots
    defer alloc.destroy(server);
    const client_ep = try makeNet(alloc);
    defer alloc.destroy(client_ep);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    const world = try alloc.create(GameWorld);
    defer alloc.destroy(world);
    world.* = .{};
    const baseline = try alloc.create(GameWorld);
    defer alloc.destroy(baseline);
    baseline.* = .{};
    const cworld = try alloc.create(GameWorld);
    defer alloc.destroy(cworld);
    cworld.* = .{};
    var map = GameMap{};
    var prio = ReplPriority(64){};

    // 8 entities: even ids in the client's room (visible), odd ids elsewhere.
    var client_rooms = Rooms{};
    client_rooms.join(1);
    var ent_rooms = [_]Rooms{.{}} ** 8;
    var ents: [8]GameWorld.Entity = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = world.spawn().?;
        world.set(e.*, RPos, .{ .x = @intCast(i * 10), .y = 0 });
        world.set(e.*, RHealth, .{ .hp = 100 });
        if (i % 2 == 0) ent_rooms[i].join(1) else ent_rooms[i].join(2);
    }

    const budget: usize = 24; // small → forces split across ticks (priority rotation)
    var snap_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var max_snap: usize = 0;
    var now: i64 = 0;
    var tick: usize = 0;
    while (tick < 400) : (tick += 1) {
        // churn the visible entities for the first half, then let it settle.
        if (tick < 150 and tick % 5 == 0) {
            for (ents, 0..) |e, i| {
                if (i % 2 == 0) world.get(e, RPos).?.x +%= 1;
            }
        }
        // build the client's interest set (even/visible only), priority-ordered.
        var vis: [8]GameWorld.Entity = undefined;
        var nvis: usize = 0;
        for (ents, 0..) |e, i| {
            if (Rooms.visible(&client_rooms, &ent_rooms[i])) {
                prio.accumulate(e.idx, 1);
                vis[nvis] = e;
                nvis += 1;
            }
        }
        var order_idx: [8]u32 = undefined;
        for (vis[0..nvis], 0..) |e, k| order_idx[k] = e.idx;
        prio.order(order_idx[0..nvis]);
        var ordered: [8]GameWorld.Entity = undefined;
        for (order_idx[0..nvis], 0..) |idx, k| ordered[k] = .{ .idx = idx, .gen = world.gens[idx] };

        const len = GameSnapshot.write(world, baseline, ordered[0..nvis], budget, &snap_buf);
        max_snap = @max(max_snap, len);
        for (order_idx[0..nvis]) |idx| prio.reset(idx); // sent (or considered) this tick

        if (len > 1) server.sendRawTo(client_addr, .rel, snap_buf[0..len]) catch {};

        poll.flushAll(server, &stx, &recv_buf, now);
        poll.recvAll(client_ep, &ctx, &recv_buf, now);
        while (client_ep.receiveRawFrom(server_addr, .rel, &recv_buf)) |rl| {
            GameSnapshot.apply(cworld, &map, recv_buf[0..rl]);
        }
        poll.flushAll(client_ep, &ctx, &recv_buf, now);
        poll.recvAll(server, &stx, &recv_buf, now);
        now += 5;
    }

    // every snapshot respected the byte budget
    try testing.expect(max_snap <= budget);

    // visible (even) entities converged on the client; odd entities never replicated.
    for (ents, 0..) |e, i| {
        if (i % 2 == 0) {
            const ce = map.get(e.idx).?;
            try testing.expectEqual(world.get(e, RPos).?.x, cworld.get(ce, RPos).?.x);
            try testing.expectEqual(@as(u16, 100), cworld.get(ce, RHealth).?.hp);
        } else {
            try testing.expect(!map.mapped(e.idx)); // out of interest → never sent
        }
    }
}

// ---- FPS recipe - predict + reconcile + lag-compensation end to end ----

const Predictor = @import("replication").Predictor;
const LagComp = @import("replication").LagComp;

const ShState = struct { x: i32, vx: i32 };
const ShInput = struct { ax: i8 };
fn shStep(s: ShState, in: ShInput) ShState {
    return .{ .x = s.x + s.vx, .vx = s.vx + in.ax };
}
const ShPred = Predictor(ShState, ShInput, shStep, 128);
const ShLag = LagComp(8, 64);

test "fps recipe: client predicts its own avatar, reconciles, and lag-comp hits favor the shooter" {
    const latency: u32 = 6;

    // --- the shooter's own avatar: client-side prediction + server reconciliation ---
    var client: ShPred = undefined;
    client.init(.{ .x = 0, .vx = 0 });
    var server_avatar = ShState{ .x = 0, .vx = 0 };
    var pend: [256]struct { at: u32, tick: u32, st: ShState } = undefined;
    var np: usize = 0;

    // --- a target the server tracks for lag compensation (moves +x at 10/tick) ---
    var lag = ShLag{};

    var t: u32 = 1;
    while (t <= 60) : (t += 1) {
        const in = ShInput{ .ax = 1 };
        // client predicts its avatar immediately (responsive)
        _ = client.predict(in);
        try testing.expectEqual(t, client.tick);

        // server advances the avatar authoritatively; a one-time unpredicted nudge
        server_avatar = shStep(server_avatar, in);
        if (t == 25) server_avatar.vx += 30; // server-only event → forces a reconcile
        pend[np] = .{ .at = t + latency, .tick = t, .st = server_avatar };
        np += 1;

        // server records the lag-comp snapshot for this tick (shooter id 0, target id 1)
        const boxes = lag.beginFrame(t);
        boxes[0] = .{ .present = true, .x = @floatFromInt(server_avatar.x), .y = -50, .r = 5 };
        boxes[1] = .{ .present = true, .x = @floatFromInt(t * 10), .y = 0, .r = 5 };

        // deliver authoritative snapshots → reconcile the avatar
        for (pend[0..np]) |s| {
            if (s.at == t) _ = client.reconcile(s.tick, s.st);
        }
    }
    for (pend[0..np]) |s| {
        if (s.at > 60) _ = client.reconcile(s.tick, s.st);
    }

    // avatar: responsive prediction reconciled to the authoritative state exactly
    try testing.expect(client.rollbacks > 0);
    try testing.expectEqual(server_avatar.x, client.present.x);
    try testing.expectEqual(server_avatar.vx, client.present.vx);

    // lag comp: at "now"=60 the client (behind by `latency`) saw the target where it
    // was at tick 54 (x=540). A shot aimed there hits when rewound, misses at "now".
    const now: u32 = 60;
    const view = now - latency; // 54
    const hit = lag.rewindRaycast(view, 0, @floatFromInt(view * 10), -50, 0, 1, 100);
    try testing.expect(hit != null and hit.?.entity == 1); // favor-the-shooter hit
    const miss = lag.rewindRaycast(now, 0, @floatFromInt(view * 10), -50, 0, 1, 100);
    try testing.expect(miss == null); // same aim at the current world misses
}

// ---- Track B1: fragmentation of a large message over a lossy link ----

const FragSchema = channels(.{ .blob = .{ .mode = .reliable_ordered, .Message = void } });
const FragCfg = Config{
    .channels = FragSchema,
    .delivery = .{ .fragmentation = true, .max_fragments = 64, .reassembly_slots = 2 },
    .limits = .{ .channel_cap = 128, .max_payload = 256, .bridge_cap = 1024, .recvpn_cap = 256 },
};

test "fragmentation: a 9000-byte message splits, survives loss, reassembles byte-exact" {
    const alloc = testing.allocator;
    const FragSession = session.Session(FragCfg);
    const link = try makeLink(alloc, .{ .latency_ms = 30, .jitter_ms = 15, .loss_permille = 200, .dup_permille = 30, .seed = 0xF2A6 });
    defer alloc.destroy(link);
    const a = try alloc.create(FragSession);
    defer alloc.destroy(a);
    a.* = .{};
    a.setup();
    const b = try alloc.create(FragSession);
    defer alloc.destroy(b);
    b.* = .{};
    b.setup();

    var blob: [9000]u8 = undefined;
    for (&blob, 0..) |*x, i| x.* = @truncate(i *% 131 +% 7);
    try a.sendBlock(.blob, &blob); // > max_payload → fragments into ~36 reliable pieces

    var scratch: [session.mtu]u8 = undefined;
    var out: [9000]u8 = undefined;
    var got: ?usize = null;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 4000 and got == null) : (step += 1) {
        while (a.pollTransmit(&scratch, now)) |len| link.send(.to_b, scratch[0..len], now);
        while (link.poll(.to_b, now, &scratch)) |len| b.feed(scratch[0..len], now);
        if (b.receiveBlock(.blob, &out)) |n| got = n;
        while (b.pollTransmit(&scratch, now)) |len| link.send(.to_a, scratch[0..len], now);
        while (link.poll(.to_a, now, &scratch)) |len| a.feed(scratch[0..len], now);
        now += 5;
    }
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 9000), got.?);
    try testing.expectEqualSlices(u8, &blob, out[0..got.?]); // reassembled byte-exact under loss
}

// ---- Track B2: control frames (PING/PONG RTT on idle, DISCONNECT, fast-NAK) ----

const PingCfg = Config{ .channels = NetSchema, .delivery = .{ .ping_interval_ms = 50, .nack_delay_ms = 3 }, .limits = NetCfg.limits };

test "ping/pong measures RTT on an otherwise-idle connection" {
    const alloc = testing.allocator;
    const PingNet = Endpoint(PingCfg);
    const link = try makeLink(alloc, .{ .latency_ms = 40, .jitter_ms = 0, .loss_permille = 0, .seed = 0x9119 });
    defer alloc.destroy(link);
    const client = try alloc.create(PingNet);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(PingNet);
    defer alloc.destroy(server);
    server.* = .{};
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    // touch both endpoints once so the sessions exist, then send NO data - only pings flow.
    try client.sendRawTo(server_addr, .un, "hi");
    var scratch: [session.mtu]u8 = undefined;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 400) : (step += 1) {
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        now += 5;
    }
    // RTT (~80ms = 2×40) learned purely from idle ping/pong
    const rtt = client.connection(server_addr).?.rttMs();
    try testing.expect(rtt >= 60 and rtt <= 120);
}

test "disconnect sends a DISCONNECT, closes both sides, and frees the slot" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 20, .loss_permille = 0, .seed = 0xD15C });
    defer alloc.destroy(link);
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    try client.sendRawTo(server_addr, .rel, "hello");
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var now: i64 = 0;
    var step: usize = 0;
    var did_disc = false;
    while (step < 200) : (step += 1) {
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| {}
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        if (!did_disc and step == 20) {
            client.disconnect(server_addr, 7); // graceful close
            did_disc = true;
        }
        client.reapClosed();
        server.reapClosed();
        now += 5;
    }
    try testing.expectEqual(@as(usize, 0), client.liveCount()); // client closed + freed
    try testing.expectEqual(@as(usize, 0), server.liveCount()); // server saw DISCONNECT + freed
}

// ---- Track C2: public API ergonomics (broadcast + connect/disconnect events) ----

test "endpoint: broadcast reaches all peers; nextEvent surfaces connect/disconnect" {
    const alloc = testing.allocator;
    const server = try makeNet(alloc);
    defer alloc.destroy(server);
    // two client sessions (raw), addrs 10 and 11
    const ClientSess = session.Session(NetCfg);
    var c0 = try alloc.create(ClientSess);
    defer alloc.destroy(c0);
    c0.* = .{};
    c0.setup();
    var c1 = try alloc.create(ClientSess);
    defer alloc.destroy(c1);
    c1.* = .{};
    c1.setup();
    const peers = [_]u64{ 10, 11 };
    const cs = [_]*ClientSess{ c0, c1 };

    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;

    // each client says hello → the server allocates a slot and emits a `connected` event
    for (cs, peers) |c, addr| {
        try c.sendRaw(.rel, "hi");
        while (c.pollTransmit(&scratch, 0)) |n| server.feedFrom(addr, scratch[0..n], 0);
    }
    var connects: usize = 0;
    while (server.nextEvent()) |ev| switch (ev) {
        .connected => connects += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), connects);
    try testing.expectEqual(@as(usize, 2), server.liveCount());

    // broadcast reaches both connections
    server.broadcastRaw(.rel, "to-all");
    while (server.pollTransmit(&scratch, 0)) |d| { // drain once, route each by addr
        for (cs, peers) |c, addr| {
            if (addr == d.addr) c.feed(scratch[0..d.len], 0);
        }
    }
    var got: usize = 0;
    for (cs) |c| {
        if (c.receiveRaw(.rel, &out)) |n| {
            if (std.mem.eql(u8, out[0..n], "to-all")) got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), got);

    // disconnect one → reapClosed frees the slot and emits a `disconnected` event
    server.disconnect(10, 0);
    var t: i64 = 0;
    var step: usize = 0;
    while (step < 10) : (step += 1) {
        while (server.pollTransmit(&scratch, t)) |_| {}
        server.reapClosed();
        t += 5;
    }
    var disconnects: usize = 0;
    while (server.nextEvent()) |ev| switch (ev) {
        .disconnected => disconnects += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), disconnects);
    try testing.expectEqual(@as(usize, 1), server.liveCount());
}

// ---- Track B4: connect-token handshake (identity verified, keys from the token) ----

const tokenmod = @import("proto").conn.token;

const TokenCfg = Config{
    .channels = NetSchema,
    .protocol_id = proto_id,
    .security = .{ .mode = .aead, .tokens = true },
    .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 256, .bridge_cap = 1024, .recvpn_cap = 256 },
};

const issuer_key = [_]u8{0x5A} ** 32;

fn makeTokenFor(expire_s: i64, server: u64) tokenmod.Token {
    return tokenmod.issue(issuer_key, proto_id, expire_s, [_]u8{0x11} ** tokenmod.nonce_len, .{
        .client_id = 42,
        .timeout_s = 30,
        .c2s_key = [_]u8{0xC2} ** 32,
        .s2c_key = [_]u8{0x52} ** 32,
        .user_data = [_]u8{0} ** tokenmod.user_data_len,
        .num_server_addrs = 1,
        .server_addrs = .{ server, 0, 0, 0 }, // whitelisted only for `server`
    });
}
fn makeToken(expire_s: i64) tokenmod.Token {
    return makeTokenFor(expire_s, server_addr);
}

test "connect-token handshake completes with keys derived from the token; expired token rejected" {
    const alloc = testing.allocator;
    const TokNet = Endpoint(TokenCfg);
    const link = try makeLink(alloc, .{ .latency_ms = 30, .loss_permille = 50, .seed = 0x70CE });
    defer alloc.destroy(link);
    const client = try alloc.create(TokNet);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(TokNet);
    defer alloc.destroy(server);
    server.* = .{};
    server.secSetupTokens(issuer_key, challenge_secret, server_addr);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var tok = makeToken(1000); // expires at t=1000s, well in the future
    _ = client.connectToWithToken(server_addr, &tok);

    const N: u32 = 30;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var queued: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 600 and delivered < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(server_addr, .rel, &b) catch break;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| delivered += 1;
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), delivered); // token handshake established an encrypted channel
    try testing.expectEqual(@as(usize, 1), server.liveCount());
    // expired/forged/replayed tokens are rejected on the live path (server calls
    // tokenmod.verify + MAC dedup); the rejection cases are unit-tested in token.zig.
}

const TypedSchema = channels(.{ .ev = .{ .mode = .reliable_ordered, .Message = u32 } });
const TypedCfg = Config{ .channels = TypedSchema, .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };

test "typed receive iterator drains messages across connections with their addr" {
    const alloc = testing.allocator;
    const TypedEP = Endpoint(TypedCfg);
    const TypedSess = session.Session(TypedCfg);
    const server = try alloc.create(TypedEP);
    defer alloc.destroy(server);
    server.* = .{};
    var cs = try alloc.create(TypedSess);
    defer alloc.destroy(cs);
    cs.* = .{};
    cs.setup();

    try cs.send(.ev, 100);
    try cs.send(.ev, 101);
    try cs.send(.ev, 102);
    var scratch: [session.mtu]u8 = undefined;
    while (cs.pollTransmit(&scratch, 0)) |n| server.feedFrom(7, scratch[0..n], 0);

    // drain via the typed iterator: yields {addr, msg} for every peer
    var sum: u32 = 0;
    var count: usize = 0;
    var it = server.receive(.ev);
    while (it.next()) |r| {
        try testing.expectEqual(@as(u64, 7), r.addr);
        sum += r.msg;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(u32, 303), sum); // 100+101+102
}

// ---- app_version negotiation in the handshake ----

const AppCfg = Config{ .channels = NetSchema, .protocol_id = proto_id, .app_version = 2, .security = .{ .mode = .aead }, .limits = NetCfg.limits };

test "app_version mismatch is rejected in the handshake (no challenge reply)" {
    const alloc = testing.allocator;
    const AppNet = Endpoint(AppCfg);
    const server = try alloc.create(AppNet);
    defer alloc.destroy(server);
    server.* = .{};
    server.secSetup(psk, challenge_secret);

    var hello: [16]u8 = undefined;
    var buf: [64]u8 = undefined;
    // a client on the wrong app version → server sends no challenge (rejected pre-slot)
    var hn = handshake.writeHello(&hello, proto_id, 1);
    server.feedFrom(99, hello[0..hn], 0);
    try testing.expect(server.pollTransmit(&buf, 0) == null);
    // the right app version → server replies with a challenge
    hn = handshake.writeHello(&hello, proto_id, 2);
    server.feedFrom(99, hello[0..hn], 0);
    try testing.expect(server.pollTransmit(&buf, 0) != null);
}

// ---- fast-NAK fires sub-RTT (well before the PTO) and doesn't double-count congestion ----

const FastNakSchema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
const FastNakCfg = Config{ .channels = FastNakSchema, .delivery = .{ .nack_delay_ms = 3 }, .limits = .{ .channel_cap = 64, .max_payload = 16, .bridge_cap = 256, .recvpn_cap = 256 } };

test "fast-NAK retransmits the gap before the PTO, with no spurious congestion event" {
    const alloc = testing.allocator;
    const S = session.Session(FastNakCfg);
    const sender = try alloc.create(S);
    defer alloc.destroy(sender);
    sender.* = .{};
    sender.setup();
    const recv = try alloc.create(S);
    defer alloc.destroy(recv);
    recv.* = .{};
    recv.setup();

    var d: [session.mtu]u8 = undefined;
    var dn: usize = undefined;

    // pn0 (msg 0): delivered.
    try sender.send(.rel, 0);
    dn = sender.pollTransmit(&d, 0).?;
    recv.feed(d[0..dn], 5);
    // pn1 (msg 1): DROPPED on the wire (we just don't deliver it).
    try sender.send(.rel, 1);
    _ = sender.pollTransmit(&d, 0).?;
    // pn2 (msg 2): delivered → receiver sees the gap at pn1 → schedules a fast-NAK.
    try sender.send(.rel, 2);
    dn = sender.pollTransmit(&d, 0).?;
    recv.feed(d[0..dn], 5);

    // the receiver emits the NAK after nack_delay (3ms) - far before the ~200ms PTO.
    var got: [3]bool = .{ false, false, false };
    var now: i64 = 10;
    var step: usize = 0;
    var delivered: usize = 0;
    while (step < 20 and delivered < 3) : (step += 1) { // now stays well under the 200ms PTO
        while (recv.pollTransmit(&d, now)) |n| sender.feed(d[0..n], now); // NAK + acks → re-eligible
        while (sender.pollTransmit(&d, now)) |n| recv.feed(d[0..n], now); // immediate retransmit of msg 1
        while (recv.receive(.rel)) |v| {
            got[v] = true;
            delivered += 1;
        }
        now += 5;
    }
    try testing.expect(now < 200); // the gap was filled well before the PTO would fire
    try testing.expect(got[0] and got[1] and got[2]); // all three delivered, in order
    // the NAK path re-eligibled the message WITHOUT a congestion event (only RACK does that)
    try testing.expectEqual(@as(u32, 0), sender.congestionEvents());
}

// ============================================================================
// hardening: fuzz · soak · zero-alloc proof · memory audit
// ============================================================================

test "hardening: zero steady-state allocation - the hot path advances no allocator" {
    const backing = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(backing);
    var fba = std.heap.FixedBufferAllocator.init(backing);
    const a = fba.allocator();

    const link = try makeLink(a, .{ .latency_ms = 40, .jitter_ms = 20, .loss_permille = 250, .dup_permille = 50, .seed = 0x5417 });
    const client = try makeNet(a);
    const server = try makeNet(a);
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    // prime the link so every lazy per-connection structure exists, THEN arm the trap.
    try client.sendRawTo(server_addr, .rel, "prime");
    poll.flushAll(client, &ctx, &scratch, 0);
    poll.recvAll(server, &stx, &scratch, 0);
    poll.flushAll(server, &stx, &scratch, 0);
    poll.recvAll(client, &ctx, &scratch, 0);
    const armed = fba.end_index;

    var now: i64 = 0;
    var q: u32 = 0;
    var got: usize = 0;
    var step: usize = 0;
    while (step < 400) : (step += 1) {
        var b: u32 = 0;
        while (b < 8) : (b += 1) {
            var w: [4]u8 = undefined;
            std.mem.writeInt(u32, &w, q, .little);
            client.sendRawTo(server_addr, .rel, &w) catch {};
            q += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| got += 1;
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        now += 5;
    }
    try testing.expect(got > 0);
    try testing.expectEqual(armed, fba.end_index); // not a single byte allocated in steady state
}

test "hardening: per-connection memory is bounded and comptime-known" {
    const SessSize = @sizeOf(NetEndpoint.Session);
    try testing.expect(SessSize > 0 and SessSize < 512 * 1024); // < 512 KiB/conn at default limits
    try testing.expect(@sizeOf(NetEndpoint) < 4 * 1024 * 1024); // 4 conns + tables
}

const fuzz_addrs = [_]u64{ 100, 200, 300, 400 };

test "hardening fuzz: receive path never crashes on random datagrams (insecure)" {
    const alloc = testing.allocator;
    const ep = try makeNet(alloc);
    defer alloc.destroy(ep);
    var prng = std.Random.DefaultPrng.init(0xF0F0F0);
    const rnd = prng.random();
    var buf: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;

    var i: usize = 0;
    while (i < 30000) : (i += 1) {
        const len = rnd.uintLessThan(usize, session.mtu + 1);
        rnd.bytes(buf[0..len]);
        const addr = fuzz_addrs[rnd.uintLessThan(usize, fuzz_addrs.len)];
        ep.feedFrom(addr, buf[0..len], @intCast(i)); // must not crash / UB / hang
        _ = ep.receiveRawFrom(addr, .rel, &out);
        _ = ep.receiveRawFrom(addr, .un, &out);
        while (ep.pollTransmit(&buf, @intCast(i))) |_| {}
        try testing.expect(ep.liveCount() <= NetCfg.limits.max_connections); // bounded, no runaway
    }
}

test "hardening fuzz: receive path survives bit-flipped *valid* datagrams" {
    const alloc = testing.allocator;
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);
    var prng = std.Random.DefaultPrng.init(0xBADF00D);
    const rnd = prng.random();
    var buf: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;

    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        // produce a genuine datagram, then corrupt a random bit before feeding it.
        var payload: [16]u8 = undefined;
        rnd.bytes(&payload);
        client.sendRawTo(server_addr, .rel, &payload) catch {};
        if (client.pollTransmit(&buf, @intCast(i))) |d| {
            var dg = buf;
            if (rnd.boolean() and d.len > 0) dg[rnd.uintLessThan(usize, d.len)] ^= rnd.int(u8); // mutate
            server.feedFrom(client_addr, dg[0..d.len], @intCast(i));
            while (server.receiveRawFrom(client_addr, .rel, &out)) |_| {}
            while (server.pollTransmit(&buf, @intCast(i))) |sd| client.feedFrom(server_addr, buf[0..sd.len], @intCast(i));
        }
    }
}

test "hardening fuzz: AEAD + fragmentation receive paths survive random bytes" {
    const alloc = testing.allocator;
    // AEAD endpoint (handshake + crypto + replay parsing on garbage)
    const aead = try makeSecNet(alloc);
    defer alloc.destroy(aead);
    aead.secSetup(psk, challenge_secret);
    // fragmentation session (fragment-frame parsing on garbage)
    const FragSession = session.Session(FragCfg);
    const frag = try alloc.create(FragSession);
    defer alloc.destroy(frag);
    frag.* = .{};
    frag.setup();

    var prng = std.Random.DefaultPrng.init(0x5EC0FF);
    const rnd = prng.random();
    var buf: [session.mtu]u8 = undefined;
    var out: [9000]u8 = undefined;

    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const len = rnd.uintLessThan(usize, session.mtu + 1);
        rnd.bytes(buf[0..len]);
        aead.feedFrom(fuzz_addrs[rnd.uintLessThan(usize, fuzz_addrs.len)], buf[0..len], @intCast(i));
        while (aead.pollTransmit(&buf, @intCast(i))) |_| {}
        frag.feed(buf[0..len], @intCast(i));
        _ = frag.receiveBlock(.blob, &out);
        while (frag.pollTransmit(&buf, @intCast(i))) |_| {}
    }
    try testing.expect(aead.liveCount() == 0); // random garbage never completes a handshake
}

fn runSoak(alloc: std.mem.Allocator, loss: u32, n: u32, payload_len: usize, max_steps: usize, seed: u64) !usize {
    const link = try makeLink(alloc, .{ .latency_ms = 50, .jitter_ms = 30, .loss_permille = loss, .dup_permille = 30, .seed = seed });
    defer alloc.destroy(link);
    const client = try makeNet(alloc);
    defer alloc.destroy(client);
    const server = try makeNet(alloc);
    defer alloc.destroy(server);
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var payload = [_]u8{0} ** 256;
    var queued: u32 = 0;
    var expected: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < max_steps and delivered < n) : (step += 1) {
        var burst: u32 = 0;
        while (queued < n and burst < 16) {
            std.mem.writeInt(u32, payload[0..4], queued, .little);
            client.sendRawTo(server_addr, .rel, payload[0..payload_len]) catch break;
            queued += 1;
            burst += 1;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |len| {
            if (len != payload_len) return error.TestUnexpectedResult;
            if (std.mem.readInt(u32, out[0..4], .little) != expected) return error.TestUnexpectedResult; // strict order
            expected += 1;
            delivered += 1;
        }
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        now += 5;
    }
    return delivered;
}

test "soak: reliable-ordered delivers exactly-once under 75% loss" {
    const d = try runSoak(testing.allocator, 750, 300, 8, 120000, 0x50A4);
    try testing.expectEqual(@as(usize, 300), d); // all 300, in order, despite 75% loss + dup
}

test "soak: 90% loss never corrupts or over-delivers (no leak), even if it can't finish" {
    // runSoak asserts strict order + exact length internally and never over-delivers; at
    // 90% loss it may not complete in the budget - the guarantee under test is that what
    // *does* arrive is still exactly-once and in order (no wrap/leak corruption).
    const d = try runSoak(testing.allocator, 900, 300, 8, 40000, 0x9099);
    try testing.expect(d <= 300); // bounded, in-order (internal asserts), no corruption
}

test "soak: data-sequence u16 wrap - 70000 reliable messages stay in order, exactly-once" {
    // 70000 > 65536 forces the per-channel u16 data-sequence to wrap (the reliable.io
    // >90%-loss soak / wrap regression). Lossless so it runs fast; correctness is the point.
    const d = try runSoak(testing.allocator, 0, 70000, 4, 2_000_000, 0x77AA);
    try testing.expectEqual(@as(usize, 70000), d);
}

test "soak: 20 large blocks reassemble byte-exact under loss (reassembly slot reuse, no leak)" {
    const alloc = testing.allocator;
    const FragSession = session.Session(FragCfg);
    const link = try makeLink(alloc, .{ .latency_ms = 30, .jitter_ms = 15, .loss_permille = 200, .dup_permille = 30, .seed = 0xF7A6 });
    defer alloc.destroy(link);
    const a = try alloc.create(FragSession);
    defer alloc.destroy(a);
    a.* = .{};
    a.setup();
    const b = try alloc.create(FragSession);
    defer alloc.destroy(b);
    b.* = .{};
    b.setup();

    var scratch: [session.mtu]u8 = undefined;
    var out: [9000]u8 = undefined;
    var blob: [9000]u8 = undefined;
    var now: i64 = 0;

    var block: u32 = 0;
    while (block < 20) : (block += 1) {
        for (&blob, 0..) |*x, i| x.* = @truncate(i *% 131 +% block); // distinct per block
        try a.sendBlock(.blob, &blob);
        var got: ?usize = null;
        var step: usize = 0;
        // pump until the block is received AND the sender's reliable window has drained
        // (acks all processed), so the next `sendBlock` starts with a clear window.
        while (step < 8000 and (got == null or a.hasUnacked())) : (step += 1) {
            while (a.pollTransmit(&scratch, now)) |len| link.send(.to_b, scratch[0..len], now);
            while (link.poll(.to_b, now, &scratch)) |len| b.feed(scratch[0..len], now);
            if (b.receiveBlock(.blob, &out)) |n| got = n;
            while (b.pollTransmit(&scratch, now)) |len| link.send(.to_a, scratch[0..len], now);
            while (link.poll(.to_a, now, &scratch)) |len| a.feed(scratch[0..len], now);
            now += 5;
        }
        try testing.expectEqual(@as(usize, 9000), got.?);
        try testing.expectEqualSlices(u8, &blob, out[0..9000]); // byte-exact, block after block
    }
}

// ---- replication engine driven over the live transport (closes the transport ↔ replication seam) ----

const replEngine = @import("replication").engine;
const EPos = struct { x: i32, y: i32 };
const EVel = struct { x: i32, y: i32 };
fn eStep(w: anytype, dt: f32) void {
    _ = dt;
    var it = w.query(.{ EPos, EVel });
    while (it.next()) |e| {
        const v = w.get(e, EVel).?;
        w.get(e, EPos).?.x += v.x;
    }
}
const NetGame = replEngine(.{ .components = .{ EPos, EVel }, .max_entities = 32, .step = eStep });

test "engine: server simulates + snapshots over a real lossy Session to a client world" {
    const alloc = testing.allocator;
    const link = try makeLink(alloc, .{ .latency_ms = 30, .jitter_ms = 10, .loss_permille = 200, .seed = 0xE5 });
    defer alloc.destroy(link);
    const server_ep = try makeNet(alloc);
    defer alloc.destroy(server_ep);
    const client_ep = try makeNet(alloc);
    defer alloc.destroy(client_ep);

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };

    var game = NetGame.Server{};
    const e = game.world.spawn().?;
    game.world.set(e, EPos, .{ .x = 0, .y = 0 });
    game.world.set(e, EVel, .{ .x = 2, .y = 0 });

    var cworld = NetGame.WorldT{};
    var map = NetGame.EntityMap{};

    var snap_buf: [256]u8 = undefined;
    var recv_buf: [256]u8 = undefined;
    var now: i64 = 0;
    var tick: usize = 0;
    while (tick < 200) : (tick += 1) {
        game.advance(); // authoritative sim step
        const vis = [_]NetGame.Entity{e};
        const n = game.snapshotFor(0, &vis, 200, &snap_buf); // delta vs this client's baseline
        if (n > 1) server_ep.sendRawTo(client_addr, .rel, snap_buf[0..n]) catch {};

        poll.flushAll(server_ep, &stx, &recv_buf, now);
        poll.recvAll(client_ep, &ctx, &recv_buf, now);
        while (client_ep.receiveRawFrom(server_addr, .rel, &recv_buf)) |rl| {
            NetGame.Snapshot.apply(&cworld.inner, &map, recv_buf[0..rl]);
        }
        poll.flushAll(client_ep, &ctx, &recv_buf, now);
        poll.recvAll(server_ep, &stx, &recv_buf, now);
        now += 5;
    }

    // drain: stop simulating, let the reliable snapshot channel deliver what's in flight
    const target = game.world.get(e, EPos).?.x;
    var drain: usize = 0;
    while (drain < 2000) : (drain += 1) {
        poll.flushAll(server_ep, &stx, &recv_buf, now);
        poll.recvAll(client_ep, &ctx, &recv_buf, now);
        while (client_ep.receiveRawFrom(server_addr, .rel, &recv_buf)) |rl| {
            NetGame.Snapshot.apply(&cworld.inner, &map, recv_buf[0..rl]);
        }
        poll.flushAll(client_ep, &ctx, &recv_buf, now);
        poll.recvAll(server_ep, &stx, &recv_buf, now);
        if (map.get(e.idx)) |m| {
            if (cworld.inner.get(m, EPos).?.x == target) break;
        }
        now += 5;
    }

    // the client's world converged on the authoritative position over the lossy link
    const ce = map.get(e.idx).?;
    try testing.expectEqual(game.world.get(e, EPos).?.x, cworld.inner.get(ce, EPos).?.x);
    try testing.expectEqual(@as(i32, 2), cworld.inner.get(ce, EVel).?.x);
}

test "pmtud raises the path MTU via DF-padded probes (acked), holds on a black hole" {
    const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
    const Cfg = Config{ .channels = Schema, .enable_pmtud = true, .max_datagram = 1500, .limits = .{ .channel_cap = 64, .max_payload = 64, .bridge_cap = 256, .recvpn_cap = 256 } };
    const S = session.Session(Cfg);
    var a: S = .{};
    a.setup();
    var b: S = .{};
    b.setup();
    var buf: [1500]u8 = undefined;
    var now: i64 = 0;

    try testing.expectEqual(@as(u16, 1200), a.pathMtu()); // conservative base
    var step: usize = 0;
    while (step < 50 and a.pathMtu() < 1500) : (step += 1) {
        while (a.pollTransmit(&buf, now)) |n| b.feed(buf[0..n], now);
        while (b.pollTransmit(&buf, now)) |n| a.feed(buf[0..n], now);
        now += 30;
    }
    try testing.expectEqual(@as(u16, 1500), a.pathMtu()); // climbed 1200→1400→1500 on acks

    a.onBlackHole(); // large packets suddenly fail → fall back to the safe base
    try testing.expectEqual(@as(u16, 1200), a.pathMtu());
}

// ---- Ed25519 cert identity feeding the live AEAD handshake (cert auth mode) ----

const identity = @import("proto").conn.identity;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;

test "cert auth: CA-verified ECDH master drives the live encrypted session" {
    const alloc = testing.allocator;
    // CA + both peers' X25519 keypairs + CA-signed certs (the trust setup).
    const ca = try Ed25519.KeyPair.generateDeterministic([_]u8{0x70} ** 32);
    const ck = try X25519.KeyPair.generateDeterministic([_]u8{0xC0} ** 32);
    const sk = try X25519.KeyPair.generateDeterministic([_]u8{0x50} ** 32);
    const ccert = try identity.issue(ca, ck.public_key, 1_000_000);
    const scert = try identity.issue(ca, sk.public_key, 1_000_000);
    // each side verifies the peer cert and derives the shared master (no PSK pre-shared).
    const cmaster = try identity.agree(ck, &ccert, &scert, ca.public_key.toBytes(), 0, true);
    const smaster = try identity.agree(sk, &scert, &ccert, ca.public_key.toBytes(), 0, false);

    const link = try makeLink(alloc, .{ .latency_ms = 30, .loss_permille = 100, .seed = 0xCE71 });
    defer alloc.destroy(link);
    const client = try makeSecNet(alloc);
    defer alloc.destroy(client);
    const server = try makeSecNet(alloc);
    defer alloc.destroy(server);
    server.secSetup(smaster, challenge_secret); // server keys derive from the cert master
    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = server_addr };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = client_addr };
    _ = client.connectTo(server_addr, cmaster); // client keys derive from the same master

    const N: u32 = 30;
    var scratch: [session.mtu]u8 = undefined;
    var out: [256]u8 = undefined;
    var b: [4]u8 = undefined;
    var queued: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 600 and delivered < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(server_addr, .rel, &b) catch break;
        }
        poll.flushAll(client, &ctx, &scratch, now);
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (server.receiveRawFrom(client_addr, .rel, &out)) |_| delivered += 1;
        now += 5;
    }
    try testing.expectEqual(@as(usize, N), delivered); // cert-authenticated encrypted channel works
    try testing.expectEqual(@as(usize, 1), server.liveCount());
    try testing.expect(server.connection(client_addr).?.isConnected());
}

test "blended channel: ordered+sequenced interleave on one stream via send/sendSequenced" {
    const Schema = channels(.{ .mixed = .{ .mode = .reliable_ordered_sequenced, .Message = u32 } });
    const Cfg = Config{ .channels = Schema, .limits = .{ .channel_cap = 64, .max_payload = 64, .bridge_cap = 256, .recvpn_cap = 256 } };
    const S = session.Session(Cfg);
    var a: S = .{};
    a.setup();
    var b: S = .{};
    b.setup();

    // slot 0: two sequenced updates (newest = 11) then the ordered terminator 100;
    // slot 1: a sequenced update (20) then the ordered terminator 101.
    try a.sendSequenced(.mixed, 10);
    try a.sendSequenced(.mixed, 11);
    try a.send(.mixed, 100);
    try a.sendSequenced(.mixed, 20);
    try a.send(.mixed, 101);

    var buf: [session.mtu]u8 = undefined;
    var now: i64 = 0;
    var n: usize = 0;
    // pump everything across first (no loss) so all messages reach the BlendReceiver
    // before we drain → newest-sequenced-per-slot applies.
    while (a.pollTransmit(&buf, now)) |len| : (now += 5) {
        b.feed(buf[0..len], now);
        n += 1;
        if (n > 50) break;
    }

    var got: [8]u32 = undefined;
    var k: usize = 0;
    while (b.receive(.mixed)) |v| {
        got[k] = v;
        k += 1;
    }
    // ordered terminators strictly in order (100 then 101); the stale sequenced 10 was
    // superseded by 11 in its slot; each slot's survivor precedes its terminator.
    try testing.expectEqualSlices(u32, &.{ 11, 100, 20, 101 }, got[0..k]);
}

test "idle-timeout closes a connection whose peer has gone silent" {
    const IdleCfg = Config{ .channels = NetSchema, .delivery = .{ .idle_timeout_ms = 100 }, .limits = NetCfg.limits };
    const S = session.Session(IdleCfg);
    var a: S = .{};
    a.setup();
    var b: S = .{};
    b.setup();
    var buf: [session.mtu]u8 = undefined;

    // exchange one datagram so both have "received" something
    try a.sendRaw(.rel, "hi");
    const n = a.pollTransmit(&buf, 0).?;
    b.feed(buf[0..n], 0);
    try testing.expect(!b.isClosed());

    // b hears nothing more; once now exceeds the idle bound past its last recv, it closes
    _ = b.pollTransmit(&buf, 50); // still within the bound
    try testing.expect(!b.isClosed());
    _ = b.pollTransmit(&buf, 200); // 200 - 0 > 100 → dead peer
    try testing.expect(b.isClosed());
}

test "config defaults compose with a channel schema" {
    const Schema = channels(.{
        .moves = .{ .mode = .unreliable, .Message = u32 },
        .chat = .{ .mode = .reliable_ordered, .Message = u32 },
    });
    const cfg = Config{ .channels = Schema, .protocol_id = 0x1234 };
    try testing.expectEqual(@as(u64, 0x1234), cfg.protocol_id);
    try testing.expectEqual(@as(usize, 64), cfg.limits.max_connections);
    try testing.expectEqual(@as(?type, null), cfg.congestion); // default resolved in Session
    try testing.expectEqual(trace.Null, cfg.tracer);
    try testing.expectEqual(@as(usize, 2), cfg.channels.count);
}
