//! `Endpoint(comptime cfg: Config)` - a fixed table of `Session(cfg)`s demultiplexed
//! by peer address. Sans-IO; the runtime drivers feed datagrams in (with the current
//! time) and pump transmits out. Typed (`sendTo`/`receiveFrom`) and raw
//! (`sendRawTo`/`receiveRawFrom`) per-channel APIs.

const std = @import("std");
const Config = @import("config").Config;
const session = @import("channel/session.zig");
const handshake = @import("conn/handshake.zig");
const Challenger = @import("conn/challenge.zig").Challenger;
const cidmod = @import("conn/cid.zig");
const tokenmod = @import("conn/token.zig");
const Ring = @import("core").Ring;
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;

pub fn Endpoint(comptime cfg: Config) type {
    const SessionT = session.Session(cfg);
    const Schema = cfg.channels;
    const max = cfg.limits.max_connections;

    const sec = cfg.security.mode == .aead;
    const cid_on = cfg.security.connection_ids;
    const tokens_on = cfg.security.tokens;
    const has_cid_bit: u8 = 0x40;
    // Connectionless (pre-connection) datagrams: flags bit5 (never set by the data or
    // handshake header) marks an application out-of-band message. Checked before any
    // session routing/allocation, so a spoofed-source flood allocates nothing.
    const unconnected_bit: u8 = 0x20;
    const unc_cap = cfg.limits.unconnected_cap;
    const unconnected = unc_cap > 0;
    const Uncon = struct { addr: u64 = 0, len: u16 = 0, data: [cfg.max_datagram]u8 = undefined };
    // A queued stateless handshake reply (challenge) - sent without a session slot,
    // so a spoofed-source hello flood never forces an allocation.
    const Reply = struct { addr: u64 = 0, len: u16 = 0, data: [32]u8 = undefined };
    const SecState = if (sec) struct {
        challenger: Challenger = Challenger.init([_]u8{0} ** 16, 4),
        cid_secret: [16]u8 = [_]u8{0} ** 16,
        psk: [32]u8 = [_]u8{0} ** 32,
        pending: Ring(Reply, 64) = .{},
        // connect-token verification (server side), when tokens are on
        issuer_key: if (tokens_on) [32]u8 else void = if (tokens_on) [_]u8{0} ** 32 else {},
        dedup: if (tokens_on) tokenmod.MacDedup(256) else void = if (tokens_on) .{} else {},
        own_addr: if (tokens_on) u64 else void = if (tokens_on) 0 else {}, // this server's address (whitelist)
    } else void;

    return struct {
        const Self = @This();
        pub const Session = SessionT;
        pub const capacity = max;
        /// Connection lifecycle events drained via `nextEvent`.
        pub const Event = union(enum) { connected: u64, disconnected: u64, migrated: u64 };

        conns: [max]SessionT = [_]SessionT{.{}} ** max,
        addrs: [max]u64 = [_]u64{0} ** max,
        used: [max]bool = [_]bool{false} ** max,
        events: Ring(Event, 64) = .{},
        sec_state: SecState = if (sec) .{} else {},
        // connectionless inbound/outbound queues (compiled out when unc_cap == 0)
        unc_in: if (unconnected) Ring(Uncon, unc_cap) else void = if (unconnected) .{} else {},
        unc_out: if (unconnected) Ring(Uncon, unc_cap) else void = if (unconnected) .{} else {},

        fn find(self: *Self, addr: u64) ?usize {
            for (self.used, self.addrs, 0..) |u, a, i| {
                if (u and a == addr) return i;
            }
            return null;
        }
        fn findOrAdd(self: *Self, addr: u64) ?usize {
            if (self.find(addr)) |i| return i;
            for (self.used, 0..) |u, i| {
                if (!u) {
                    self.used[i] = true;
                    self.addrs[i] = addr;
                    self.conns[i] = .{};
                    self.conns[i].setup();
                    self.conns[i].peer = addr;
                    self.events.pushOverwrite(.{ .connected = addr });
                    return i;
                }
            }
            return null;
        }

        /// Drain the next connect/disconnect/migrate event, or null.
        pub fn nextEvent(self: *Self) ?Event {
            return self.events.pop();
        }

        /// Typed receive iterator across **all** live connections: drains channel `ch`
        /// from every peer. `it.next()` yields `{ addr, msg }` until exhausted.
        pub fn Received(comptime ch: anytype) type {
            return struct { addr: u64, msg: Schema.MessageOf(ch) };
        }
        pub fn ReceiveIter(comptime ch: anytype) type {
            return struct {
                ep: *Self,
                i: usize = 0,
                pub fn next(it: *@This()) ?Received(ch) {
                    while (it.i < max) {
                        if (it.ep.used[it.i]) {
                            if (it.ep.conns[it.i].receive(ch)) |m| return .{ .addr = it.ep.addrs[it.i], .msg = m };
                        }
                        it.i += 1;
                    }
                    return null;
                }
            };
        }
        pub fn receive(self: *Self, comptime ch: anytype) ReceiveIter(ch) {
            return .{ .ep = self };
        }

        pub fn connection(self: *Self, addr: u64) ?*SessionT {
            const i = self.find(addr) orelse return null;
            return &self.conns[i];
        }

        /// Live per-connection stats snapshot (rtt/cwnd/in-flight/congestion), or null.
        pub fn stats(self: *Self, addr: u64) ?SessionT.Stats {
            const c = self.connection(addr) orelse return null;
            return c.stats();
        }

        /// Request a graceful close of the connection to `addr` (sends a DISCONNECT).
        pub fn disconnect(self: *Self, addr: u64, reason: u8) void {
            if (self.connection(addr)) |c| c.disconnect(reason);
        }

        /// Free any connection slots whose session has closed (peer DISCONNECTed or we
        /// finished sending our own DISCONNECT). Call after pumping.
        pub fn reapClosed(self: *Self) void {
            for (self.used, 0..) |u, i| {
                if (u and self.conns[i].isClosed()) {
                    self.used[i] = false;
                    self.events.pushOverwrite(.{ .disconnected = self.addrs[i] });
                }
            }
        }

        /// Send `value` on channel `ch` to every live connection (typed).
        pub fn broadcast(self: *Self, comptime ch: anytype, value: Schema.MessageOf(ch)) void {
            for (self.used, 0..) |u, i| {
                if (u) self.conns[i].send(ch, value) catch {};
            }
        }
        pub fn broadcastRaw(self: *Self, comptime ch: anytype, bytes: []const u8) void {
            for (self.used, 0..) |u, i| {
                if (u) self.conns[i].sendRaw(ch, bytes) catch {};
            }
        }
        pub fn liveCount(self: *Self) usize {
            var n: usize = 0;
            for (self.used) |u| {
                if (u) n += 1;
            }
            return n;
        }

        /// Server-side security setup: the pre-shared session key and the challenge
        /// secret (rotated by the caller via the challenger). Required before an
        /// `.aead` server accepts handshakes.
        pub fn secSetup(self: *Self, psk: [32]u8, challenge_secret: [16]u8) void {
            if (sec) {
                self.sec_state.psk = psk;
                self.sec_state.cid_secret = challenge_secret;
                self.sec_state.challenger = Challenger.init(challenge_secret, 4);
            }
        }

        /// Server-side token setup: the backend-shared issuer key that signs connect
        /// tokens, the challenge secret, and **this server's own address** (a token is
        /// accepted only if its whitelist authorizes this address). Required when
        /// `Security.tokens`.
        pub fn secSetupTokens(self: *Self, issuer_key: [32]u8, challenge_secret: [16]u8, own_addr: u64) void {
            if (tokens_on) {
                self.sec_state.issuer_key = issuer_key;
                self.sec_state.cid_secret = challenge_secret;
                self.sec_state.own_addr = own_addr;
                self.sec_state.challenger = Challenger.init(challenge_secret, 4);
            }
        }

        /// Client-side: connect using a backend-issued connect token (keys derive from
        /// the token, echoed in the handshake response). Requires `Security.tokens`.
        pub fn connectToWithToken(self: *Self, addr: u64, t: *const tokenmod.Token) ?*SessionT {
            const i = self.findOrAdd(addr) orelse return null;
            var enc: [tokenmod.Token.wire_len]u8 = undefined;
            const n = t.encode(&enc);
            self.conns[i].secSetupToken(true, t.c2s_key, t.s2c_key, enc[0..n]);
            self.conns[i].connect();
            return &self.conns[i];
        }

        /// Client-side: open a connection to `addr` (allocates one slot, begins the
        /// handshake). The session emits a hello on the next `pollTransmit`.
        pub fn connectTo(self: *Self, addr: u64, psk: [32]u8) ?*SessionT {
            const i = self.findOrAdd(addr) orelse return null;
            self.conns[i].secSetup(true, psk);
            if (cid_on) {
                // client's local CID (peer will address us by it); deterministic from psk.
                var secret16: [16]u8 = undefined;
                @memcpy(&secret16, psk[0..16]);
                self.conns[i].setLocalCid(cidmod.derive(secret16, addr));
            }
            self.conns[i].connect();
            return &self.conns[i];
        }

        fn findByCid(self: *Self, c: cidmod.Cid) ?usize {
            for (self.used, 0..) |u, i| {
                if (u and self.conns[i].localCid() == c) return i;
            }
            return null;
        }

        fn queueReply(self: *Self, addr: u64, c: handshake.Cookie) void {
            var r = Reply{ .addr = addr };
            if (cid_on) {
                const scid = cidmod.derive(self.sec_state.cid_secret, addr);
                r.len = @intCast(handshake.writeChallengeCid(&r.data, c, scid));
            } else {
                r.len = @intCast(handshake.writeChallenge(&r.data, c));
            }
            _ = self.sec_state.pending.push(r);
        }

        pub fn feedFrom(self: *Self, addr: u64, bytes: []const u8, now: i64) void {
            // Connectionless datagram (flags bit5): queue for the app and stop - never
            // routed to a session, never allocates a slot (so a flood is harmless).
            if (unconnected and bytes.len >= 1 and (bytes[0] & unconnected_bit) != 0) {
                const payload = bytes[1..];
                if (payload.len <= cfg.max_datagram) {
                    var m = Uncon{ .addr = addr, .len = @intCast(payload.len) };
                    @memcpy(m.data[0..payload.len], payload);
                    self.unc_in.pushOverwrite(m); // drop-oldest under flood
                }
                return;
            }
            if (sec) {
                if (handshake.isHandshake(bytes)) {
                    const t = handshake.typeOf(bytes) orelse return;
                    switch (t) {
                        .hello => {
                            // Stateless: verify protocol + app version, reply with a cookie,
                            // allocate NOTHING.
                            const pid = handshake.readHello(bytes) orelse return;
                            if (pid != cfg.protocol_id) return;
                            if (cfg.app_version != 0) {
                                const v = handshake.readAppVersion(bytes) orelse return;
                                if (v != cfg.app_version) return; // incompatible app version
                            }
                            const c = self.sec_state.challenger.issue(addr, now);
                            self.queueReply(addr, .{ .coarse = c.coarse, .cookie = c.cookie });
                            return;
                        },
                        .response => {
                            // Allocate a slot ONLY on a valid, fresh cookie (address-validated).
                            const c = handshake.readCookie(bytes) orelse return;
                            if (!self.sec_state.challenger.verify(addr, c.coarse, c.cookie, now)) return;
                            // when tokens are required, verify the echoed connect token
                            // (identity) before allocating - keys derive from it.
                            var tok_c2s: [32]u8 = undefined;
                            var tok_s2c: [32]u8 = undefined;
                            if (tokens_on) {
                                const tb = handshake.readResponseToken(bytes) orelse return;
                                const tk = tokenmod.Token.decode(tb) orelse return;
                                const now_s = @divTrunc(now, 1000);
                                const priv = tokenmod.verify(self.sec_state.issuer_key, cfg.protocol_id, now_s, &tk) catch return;
                                if (!priv.allowsServer(self.sec_state.own_addr)) return; // not whitelisted for this server
                                const m = tokenmod.mac(&tk);
                                if (self.sec_state.dedup.seen(m)) return; // replayed token
                                self.sec_state.dedup.record(m);
                                tok_c2s = priv.c2s_key;
                                tok_s2c = priv.s2c_key;
                            }
                            const i = self.findOrAdd(addr) orelse return;
                            if (!self.conns[i].isConnected()) {
                                if (tokens_on) {
                                    self.conns[i].secSetupToken(false, tok_c2s, tok_s2c, &.{});
                                } else {
                                    self.conns[i].secSetup(false, self.sec_state.psk);
                                    if (cid_on) {
                                        self.conns[i].setLocalCid(cidmod.derive(self.sec_state.cid_secret, addr));
                                        if (handshake.readConnId(bytes)) |client_cid| self.conns[i].setRemoteCid(client_cid);
                                    }
                                }
                                self.conns[i].secAccept();
                                self.conns[i].peer = addr;
                            } else {
                                // retransmitted response → re-arm the proof keepalive
                                self.conns[i].sec_state.force_keepalive = true;
                            }
                            return;
                        },
                        .challenge => {
                            // client-side: deliver to the existing session
                            const i = self.find(addr) orelse return;
                            self.conns[i].feed(bytes, now);
                            return;
                        },
                    }
                }
                // encrypted data: route by connection id when enabled (survives a
                // changed source address), else by source address. No implicit alloc.
                if (cid_on) {
                    if (bytes.len < 9 or (bytes[0] & has_cid_bit) == 0) return;
                    const c = std.mem.readInt(u64, bytes[1..9], .little);
                    const i = self.findByCid(c) orelse return;
                    if (self.conns[i].peer != addr) {
                        switch (cidmod.classify(self.conns[i].peer, addr)) {
                            .same => {},
                            .port_only => {
                                self.addrs[i] = addr; // keep RTT/cc/MTU on a port remap
                                self.conns[i].peer = addr;
                            },
                            .ip_change => {
                                self.addrs[i] = addr;
                                self.conns[i].peer = addr;
                                const token = cidmod.derive(self.sec_state.cid_secret, addr) ^ 0xA5A5_5A5A_A5A5_5A5A;
                                self.conns[i].onPathChange(token); // reset path + validate
                                self.events.pushOverwrite(.{ .migrated = addr });
                            },
                        }
                    }
                    self.conns[i].feed(bytes, now);
                    return;
                }
                const i = self.find(addr) orelse return;
                self.conns[i].feed(bytes, now);
                return;
            }
            const i = self.findOrAdd(addr) orelse return;
            self.conns[i].feed(bytes, now);
        }

        pub fn sendTo(self: *Self, addr: u64, comptime ch: anytype, value: Schema.MessageOf(ch)) session.SendError!void {
            const i = self.findOrAdd(addr) orelse return error.Backpressure;
            try self.conns[i].send(ch, value);
        }
        pub fn sendRawTo(self: *Self, addr: u64, comptime ch: anytype, bytes: []const u8) session.SendError!void {
            const i = self.findOrAdd(addr) orelse return error.Backpressure;
            try self.conns[i].sendRaw(ch, bytes);
        }
        pub fn receiveFrom(self: *Self, addr: u64, comptime ch: anytype) ?Schema.MessageOf(ch) {
            const c = self.connection(addr) orelse return null;
            return c.receive(ch);
        }
        pub fn receiveRawFrom(self: *Self, addr: u64, comptime ch: anytype, out: []u8) ?usize {
            const c = self.connection(addr) orelse return null;
            return c.receiveRaw(ch, out);
        }

        // ---- connectionless (pre-connection) messages: discovery / server-info /
        // NAT-punch. Unauthenticated, unencrypted, unreliable by nature - the app must
        // treat them as untrusted (rate-limit; keep replies ≤ request size). Enabled by
        // `Config.limits.unconnected_cap > 0`. ----

        /// Queue a raw connectionless datagram to `addr` (sent on the next `pollTransmit`,
        /// ahead of session traffic). Drop-oldest if the outbound queue is full.
        pub fn sendUnconnectedRaw(self: *Self, addr: u64, payload: []const u8) void {
            if (!unconnected) @compileError("set Config.limits.unconnected_cap > 0 to use connectionless messages");
            if (payload.len > cfg.max_datagram) return;
            var m = Uncon{ .addr = addr, .len = @intCast(payload.len) };
            @memcpy(m.data[0..payload.len], payload);
            self.unc_out.pushOverwrite(m);
        }
        /// Typed connectionless send: serialize `value` (derived `wire.serde`) and queue it.
        /// For **more than one** message kind, make `value`'s type a tagged union (e.g.
        /// `union(enum){ ping: Ping, info: Info, … }`) - serde encodes the tag, and
        /// `receiveUnconnected(ThatUnion)` lets the peer switch on it. No channel schema
        /// is needed (unconnected messages carry no per-stream reliability/ordering state).
        pub fn sendUnconnected(self: *Self, addr: u64, value: anytype) void {
            if (!unconnected) @compileError("set Config.limits.unconnected_cap > 0 to use connectionless messages");
            var tmp: [cfg.max_datagram]u8 = undefined;
            var w = bitpack.Writer.init(&tmp);
            serde.write(&w, value);
            if (w.overflowed) return;
            self.sendUnconnectedRaw(addr, w.finish());
        }

        pub const Unconnected = struct { addr: u64, bytes: []const u8 };
        /// Drain the next received connectionless datagram (bytes valid until the next
        /// `receiveUnconnectedRaw`), or null. `scratch` must be ≥ `cfg.max_datagram`.
        pub fn receiveUnconnectedRaw(self: *Self, scratch: []u8) ?Unconnected {
            if (!unconnected) @compileError("set Config.limits.unconnected_cap > 0 to use connectionless messages");
            const m = self.unc_in.pop() orelse return null;
            @memcpy(scratch[0..m.len], m.data[0..m.len]);
            return .{ .addr = m.addr, .bytes = scratch[0..m.len] };
        }
        /// Typed connectionless receive: pop + deserialize into `T` (derived `wire.serde`);
        /// null if the queue is empty or the bytes don't parse as `T`.
        pub fn receiveUnconnected(self: *Self, comptime T: type) ?struct { addr: u64, msg: T } {
            if (!unconnected) @compileError("set Config.limits.unconnected_cap > 0 to use connectionless messages");
            const m = self.unc_in.peek() orelse return null;
            var r = bitpack.Reader.init(m.data[0..m.len]);
            const v = serde.read(T, &r) orelse {
                _ = self.unc_in.pop(); // malformed → discard
                return null;
            };
            const addr = m.addr;
            _ = self.unc_in.pop();
            return .{ .addr = addr, .msg = v };
        }

        pub const Outgoing = struct { addr: u64, len: usize };
        pub fn pollTransmit(self: *Self, buf: []u8, now: i64) ?Outgoing {
            if (unconnected) {
                // connectionless datagrams go out first (marker byte + payload).
                if (self.unc_out.pop()) |m| {
                    buf[0] = unconnected_bit;
                    @memcpy(buf[1 .. 1 + m.len], m.data[0..m.len]);
                    return .{ .addr = m.addr, .len = 1 + @as(usize, m.len) };
                }
            }
            if (sec) {
                // stateless challenge replies go out first (no session needed).
                if (self.sec_state.pending.pop()) |r| {
                    @memcpy(buf[0..r.len], r.data[0..r.len]);
                    return .{ .addr = r.addr, .len = r.len };
                }
            }
            for (self.used, 0..) |u, i| {
                if (!u) continue;
                if (self.conns[i].pollTransmit(buf, now)) |len| {
                    return .{ .addr = self.addrs[i], .len = len };
                }
            }
            return null;
        }
    };
}

const testing = std.testing;
const channels = @import("channel/schema.zig").channels;

const DemuxSchema = channels(.{ .un = .{ .mode = .unreliable, .Message = void } });
const DemuxCfg = Config{ .channels = DemuxSchema, .limits = .{ .max_connections = 4, .channel_cap = 16, .max_payload = 32 } };

test "endpoint demuxes two peers into separate sessions" {
    const E = Endpoint(DemuxCfg);
    var ep = try testing.allocator.create(E);
    defer testing.allocator.destroy(ep);
    ep.* = .{};

    var src1 = try testing.allocator.create(E.Session);
    defer testing.allocator.destroy(src1);
    src1.* = .{};
    src1.setup();
    var src2 = try testing.allocator.create(E.Session);
    defer testing.allocator.destroy(src2);
    src2.* = .{};
    src2.setup();

    var buf: [64]u8 = undefined;
    try src1.sendRaw(.un, "from-one");
    const n1 = src1.pollTransmit(&buf, 0).?;
    ep.feedFrom(100, buf[0..n1], 0);
    try src2.sendRaw(.un, "from-two");
    const n2 = src2.pollTransmit(&buf, 0).?;
    ep.feedFrom(200, buf[0..n2], 0);

    try testing.expectEqual(@as(usize, 2), ep.liveCount());
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), ep.receiveRawFrom(100, .un, &out).?);
    try testing.expectEqualSlices(u8, "from-one", out[0..8]);
    try testing.expectEqual(@as(usize, 8), ep.receiveRawFrom(200, .un, &out).?);
    try testing.expectEqualSlices(u8, "from-two", out[0..8]);
}

const Ping = struct { magic: u32, version: u16 };
const Info = struct { players: u16, map_id: u8 };
const UncCfg = Config{ .channels = DemuxSchema, .limits = .{ .max_connections = 4, .channel_cap = 16, .max_payload = 32, .unconnected_cap = 8 } };

test "connectionless (typed, serde): discovery ping/info, no slot allocated, flood-safe" {
    const E = Endpoint(UncCfg);
    var server = try testing.allocator.create(E);
    defer testing.allocator.destroy(server);
    server.* = .{};
    var client = try testing.allocator.create(E);
    defer testing.allocator.destroy(client);
    client.* = .{};

    const srv: u64 = 2;
    const cli: u64 = 1;
    var buf: [64]u8 = undefined;

    // client → server: a typed discovery ping (serde-encoded), carried unconnected.
    client.sendUnconnected(srv, Ping{ .magic = 0xCAFE, .version = 3 });
    const d = client.pollTransmit(&buf, 0).?;
    try testing.expectEqual(srv, d.addr);
    try testing.expect((buf[0] & 0x20) != 0); // the unconnected marker bit
    server.feedFrom(cli, buf[0..d.len], 0);

    // server receives it typed - and allocates NO connection slot.
    const got = server.receiveUnconnected(Ping).?;
    try testing.expectEqual(cli, got.addr);
    try testing.expectEqual(@as(u32, 0xCAFE), got.msg.magic);
    try testing.expectEqual(@as(u16, 3), got.msg.version);
    try testing.expectEqual(@as(usize, 0), server.liveCount()); // pre-connection, no slot

    // server → client: a typed info reply, also unconnected.
    server.sendUnconnected(got.addr, Info{ .players = 7, .map_id = 42 });
    const r = server.pollTransmit(&buf, 0).?;
    client.feedFrom(srv, buf[0..r.len], 0);
    const info = client.receiveUnconnected(Info).?;
    try testing.expectEqual(@as(u16, 7), info.msg.players);
    try testing.expectEqual(@as(u8, 42), info.msg.map_id);
    try testing.expectEqual(@as(usize, 0), client.liveCount());

    // a spoofed-source unconnected flood allocates nothing (checked before routing).
    var i: usize = 0;
    while (i < 100) : (i += 1) server.feedFrom(0xBADBAD, &.{ 0x20, 'x' }, 0);
    try testing.expectEqual(@as(usize, 0), server.liveCount());
}

const Discovery = union(enum) { ping: Ping, info: Info, bye: void };

test "connectionless: one tagged union carries several message kinds (serde dispatch)" {
    const E = Endpoint(UncCfg);
    var a = try testing.allocator.create(E);
    defer testing.allocator.destroy(a);
    a.* = .{};
    var b = try testing.allocator.create(E);
    defer testing.allocator.destroy(b);
    b.* = .{};

    var buf: [64]u8 = undefined;
    // three different kinds, all sent as the one union type
    a.sendUnconnected(2, Discovery{ .ping = .{ .magic = 1, .version = 2 } });
    a.sendUnconnected(2, Discovery{ .info = .{ .players = 9, .map_id = 5 } });
    a.sendUnconnected(2, Discovery{ .bye = {} });
    while (a.pollTransmit(&buf, 0)) |d| b.feedFrom(1, buf[0..d.len], 0);

    // the receiver dispatches on the tag - it didn't need to know the order/kind ahead.
    var tags: [3]std.meta.Tag(Discovery) = undefined;
    var n: usize = 0;
    while (b.receiveUnconnected(Discovery)) |m| {
        tags[n] = std.meta.activeTag(m.msg);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(tags[0] == .ping and tags[1] == .info and tags[2] == .bye);
}
