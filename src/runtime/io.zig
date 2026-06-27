//! The `std.Io` seam (*all* direct `std.Io` usage is confined to this
//! file). A UDP socket + address conversion exposed so the drivers run over a real
//! network. Addresses are encoded as `(ipv4:u32 << 32 | port:u16)` - the same
//! convention the migration heuristic (`conn/cid.zig`) classifies - so the rest of
//! the stack stays integer-addressed and `std.Io`-free.
//!
//! `runBlocking` is the simplest real driver: block on one datagram, feed it, drain
//! the endpoint's transmits. A reactor/sharded/task variant adds `io.select` timers
//! and `io.async`; those wrap the *same* sans-IO core (see `reactor.zig` etc.).

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

/// Encode an IPv4 address + port as `(ip << 32) | port`.
pub fn u64FromIp4(bytes: [4]u8, port: u16) u64 {
    const ip = std.mem.readInt(u32, &bytes, .big);
    return (@as(u64, ip) << 32) | port;
}

/// Stable u64 key for a peer address. IPv4 packs losslessly to `(ip<<32)|port` and is
/// reconstructable. IPv6 can't fit 144 bits, so it gets a deterministic SipHash of the
/// 16-byte address + port with the top bit set (so it never collides with a v4 key);
/// the real address is recovered via `AddrTable` (populated on receive). Determinism
/// means a stateless server recomputes the same key for the same v6 peer.
pub fn u64FromAddr(a: net.IpAddress) u64 {
    return switch (a) {
        .ip4 => |v| u64FromIp4(v.bytes, v.port),
        .ip6 => |v| ip6Key(v.bytes, v.port),
    };
}

const Sip = std.crypto.auth.siphash.SipHash64(1, 3);
fn ip6Key(bytes: [16]u8, port: u16) u64 {
    var msg: [18]u8 = undefined;
    @memcpy(msg[0..16], &bytes);
    std.mem.writeInt(u16, msg[16..18], port, .little);
    var out: [8]u8 = undefined;
    Sip.create(&out, &msg, &([_]u8{0x6} ** 16));
    return std.mem.readInt(u64, &out, .little) | (@as(u64, 1) << 63); // top bit marks v6
}

/// Is this a hashed IPv6 key (vs a directly-decodable IPv4 key)?
pub fn isIp6Key(a: u64) bool {
    return (a >> 63) != 0;
}

pub fn addrFromU64(a: u64) net.IpAddress {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast((a >> 32) & 0xffff_ffff), .big);
    return .{ .ip4 = .{ .bytes = bytes, .port = @intCast(a & 0xffff) } };
}

/// Recovers full peer addresses (incl. IPv6) from their u64 keys. A driver records each
/// source address on receive and looks it up on send, so the sans-IO core stays
/// integer-addressed while v6 round-trips. Fixed-capacity, drop-oldest, zero-alloc.
pub fn AddrTable(comptime cap: usize) type {
    return struct {
        const Self = @This();
        keys: [cap]u64 = [_]u64{0} ** cap,
        addrs: [cap]net.IpAddress = undefined,
        len: usize = 0,
        next: usize = 0,

        pub fn record(self: *Self, key: u64, addr: net.IpAddress) void {
            if (!isIp6Key(key)) return; // v4 is reconstructable; no need to store
            for (self.keys[0..self.len]) |k| {
                if (k == key) return; // already known
            }
            self.keys[self.next] = key;
            self.addrs[self.next] = addr;
            self.next = (self.next + 1) % cap;
            if (self.len < cap) self.len += 1;
        }
        pub fn lookup(self: *const Self, key: u64) net.IpAddress {
            if (!isIp6Key(key)) return addrFromU64(key);
            for (self.keys[0..self.len], 0..) |k, i| {
                if (k == key) return self.addrs[i];
            }
            return addrFromU64(key); // unknown v6 → best-effort (shouldn't happen post-recv)
        }
    };
}

/// Bind a UDP (datagram) socket to `addr_u64`. Pass port 0 for an ephemeral port;
/// `Socket.address` then holds the resolved one.
pub fn bindUdp(io: Io, addr_u64: u64) !net.Socket {
    var addr = addrFromU64(addr_u64);
    return addr.bind(io, .{ .mode = .dgram });
}

/// Current monotonic time in ms from the injected `Io` clock - the sans-IO core
/// takes relative ms, so a monotonic source is exactly right (and `std.time`'s
/// wall-clock helpers were removed in 0.16).
pub fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .boot).nanoseconds, std.time.ns_per_ms));
}

/// Blocking single-thread server loop: receive one datagram, feed it (with the
/// source address as a u64), then flush all queued outbound datagrams. The endpoint
/// is the sans-IO core; this is the only place IO happens. Loops until `stop()`.
pub fn runBlocking(io: Io, sock: *const net.Socket, ep: anytype, stop: anytype) !void {
    var scratch: [1500]u8 = undefined;
    var table = AddrTable(256){};
    while (!stop.stopped()) {
        const msg = try sock.receive(io, &scratch);
        const now = nowMs(io);
        const key = u64FromAddr(msg.from);
        table.record(key, msg.from);
        ep.feedFrom(key, msg.data, now);
        var out: [1500]u8 = undefined;
        while (ep.pollTransmit(&out, now)) |d| {
            var dest = table.lookup(d.addr);
            sock.send(io, &dest, out[0..d.len]) catch {};
        }
    }
}

/// Real-`std.Io` **reactor**: races a `receive` against a timer armed at the
/// endpoint's `pollDeadline` via `Io.Select`, so an idle connection wakes on its
/// own schedule instead of blocking forever on recv (the driver shape over
/// real async IO, not just the sim). Same sans-IO core as every other driver.
///
/// Note: when the timer wins while a recv is still blocked, `cancelDiscard` relies
/// on the `Io` implementation cancelling an in-flight datagram read; idle-cancel
/// hardening across every backend is the remaining real-network item. GSO/GRO
/// batching is *not* offered - `std.Io.net` (0.16) exposes no `sendmmsg`/`recvmmsg`
/// and posix was removed, so there is no batch primitive to build on.
pub fn runReactor(io: Io, sock: *const net.Socket, ep: anytype, stop: anytype) !void {
    const RecvR = struct { len: usize, addr: u64, from: net.IpAddress, ok: bool };
    const Ev = union(enum) { recv: RecvR, timer: void };
    const Tasks = struct {
        fn recv(s: *const net.Socket, i: Io, buf: []u8) RecvR {
            const m = s.receive(i, buf) catch return .{ .len = 0, .addr = 0, .from = undefined, .ok = false };
            return .{ .len = m.data.len, .addr = u64FromAddr(m.from), .from = m.from, .ok = true };
        }
        fn timer(i: Io, ns: i96) void {
            std.Io.sleep(i, .{ .nanoseconds = ns }, .boot) catch {};
        }
    };
    var rxbuf: [1500]u8 = undefined;
    var out: [1500]u8 = undefined;
    var table = AddrTable(256){};
    while (!stop.stopped()) {
        const now = nowMs(io);
        while (ep.pollTransmit(&out, now)) |d| {
            var dest = table.lookup(d.addr);
            sock.send(io, &dest, out[0..d.len]) catch {};
        }
        const dl = ep.pollDeadline(now) orelse (now + 50); // idle tick when nothing pending
        const wait_ns: i96 = @as(i96, @intCast(@max(dl - now, 1))) * std.time.ns_per_ms;

        var sbuf: [2]Ev = undefined;
        var sel = std.Io.Select(Ev).init(io, &sbuf);
        sel.async(.recv, Tasks.recv, .{ sock, io, rxbuf[0..] });
        sel.async(.timer, Tasks.timer, .{ io, wait_ns });
        const ev = sel.await() catch {
            sel.cancelDiscard();
            return;
        };
        sel.cancelDiscard();
        switch (ev) {
            .recv => |r| if (r.ok) {
                table.record(r.addr, r.from);
                ep.feedFrom(r.addr, rxbuf[0..r.len], nowMs(io));
            },
            .timer => {},
        }
    }
}

/// Generic batch send: use the transport's native `sendBatch` (Linux `sendmmsg`) when it
/// has one, else fall back to a loop of single sends. Drivers call this so they batch
/// where the backend supports it and degrade gracefully where it doesn't - the capability
/// seam that lets the same driver run over `std.Io` *or* the Linux backend.
pub fn sendBatch(transport: anytype, out: anytype) usize {
    const T = @TypeOf(transport.*);
    if (@hasDecl(T, "sendBatch")) return transport.sendBatch(out);
    for (out) |o| transport.send(o.addr, o.bytes, 0);
    return out.len;
}

/// Driver-model-selecting entry point over a real `std.Io` socket.
pub const Driver = enum { blocking, reactor };
pub fn serve(io: Io, sock: *const net.Socket, ep: anytype, stop: anytype, driver: Driver) !void {
    switch (driver) {
        .blocking => try runBlocking(io, sock, ep, stop),
        .reactor => try runReactor(io, sock, ep, stop),
    }
}

const testing = std.testing;

test "u64 address encoding roundtrips ip + port" {
    const a = u64FromIp4(.{ 10, 0, 0, 7 }, 5000);
    try testing.expectEqual(@as(u32, 0x0A00_0007), @as(u32, @intCast(a >> 32)));
    try testing.expectEqual(@as(u16, 5000), @as(u16, @intCast(a & 0xffff)));
    // roundtrip through IpAddress
    const back = u64FromAddr(addrFromU64(a));
    try testing.expectEqual(a, back);
}

test "ipv6 keys are distinct + stable, and the AddrTable recovers the full address" {
    const a6: net.IpAddress = .{ .ip6 = .{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 14 ++ [_]u8{0x1}, .port = 9000 } };
    const b6: net.IpAddress = .{ .ip6 = .{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 14 ++ [_]u8{0x2}, .port = 9000 } };
    const ka = u64FromAddr(a6);
    const kb = u64FromAddr(b6);
    try testing.expect(isIp6Key(ka) and isIp6Key(kb));
    try testing.expect(ka != kb); // distinct v6 peers → distinct keys (no collapse)
    try testing.expectEqual(ka, u64FromAddr(a6)); // deterministic (stateless recompute)
    // a v4 key is never confused for a v6 key
    try testing.expect(!isIp6Key(u64FromIp4(.{ 10, 0, 0, 1 }, 5000)));

    var table = AddrTable(8){};
    table.record(ka, a6);
    const back = table.lookup(ka);
    try testing.expect(back == .ip6);
    try testing.expectEqualSlices(u8, &a6.ip6.bytes, &back.ip6.bytes);
    try testing.expectEqual(@as(u16, 9000), back.ip6.port);
}

test "udp loopback over std.Io (best-effort; skipped if sockets unavailable)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var sock = addr.bind(io, .{ .mode = .dgram }) catch return; // sandbox may forbid → skip
    defer sock.close(io);

    var dest = sock.address; // resolved ephemeral port
    sock.send(io, &dest, "ping") catch return;

    var buf: [16]u8 = undefined;
    const msg = sock.receive(io, &buf) catch return;
    try testing.expectEqualSlices(u8, "ping", msg.data);
    try testing.expectEqual(dest.getPort(), msg.from.getPort());
}

test "reactor over real std.Io: select races recv vs the deadline timer (loopback)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var saddr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = saddr.bind(io, .{ .mode = .dgram }) catch return; // skip if sandbox forbids
    defer server.close(io);
    var caddr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var client = caddr.bind(io, .{ .mode = .dgram }) catch return;
    defer client.close(io);

    // pre-send so the reactor's first recv returns immediately (recv wins the select,
    // so no blocked-recv cancellation is exercised).
    var dest = server.address;
    client.send(io, &dest, "ping") catch return;

    const Stub = struct {
        got: usize = 0,
        last: [16]u8 = undefined,
        const O = struct { addr: u64, len: usize };
        pub fn feedFrom(self: *@This(), addr: u64, bytes: []const u8, now: i64) void {
            _ = addr;
            _ = now;
            @memcpy(self.last[0..bytes.len], bytes);
            self.got = bytes.len;
        }
        pub fn pollTransmit(self: *@This(), b: []u8, now: i64) ?O {
            _ = self;
            _ = b;
            _ = now;
            return null;
        }
        pub fn pollDeadline(self: *@This(), now: i64) ?i64 {
            _ = self;
            _ = now;
            return null;
        }
        pub fn stopped(self: *@This()) bool {
            return self.got > 0;
        }
    };
    var stub = Stub{};
    runReactor(io, &server, &stub, &stub) catch return;
    try testing.expectEqualSlices(u8, "ping", stub.last[0..stub.got]); // drove a real-Io select reactor tick
}
