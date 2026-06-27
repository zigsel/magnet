//! Linux UDP datagram backend - the capabilities `std.Io.net` (0.16) can't express,
//! built on raw `std.os.linux` syscalls (the only place IO lives):
//!   - **`sendmmsg` / `recvmmsg` batch I/O** - one syscall for up to N datagrams, possibly
//!     to/from different peers (the high-value primitive for a many-connection server;
//!     `Endpoint.pollTransmit`'s `(addr, datagram)` stream maps straight onto it).
//!   - **deadline-bounded recv** (`recvmmsg` timeout / `poll`) - the reactor waits on the
//!     socket with a timer and *never* blocks past its `pollDeadline`, so the idle-recv
//!     cancellation problem (D2) is solved natively, no `Io.Select` cancel dance.
//!   - **don't-fragment** (`IP_MTU_DISCOVER`) for live PMTUD, and **GSO** (`UDP_SEGMENT`).
//!
//! It exposes the same duck-typed transport (`recv(buf, now) ?Recv` / `send(addr, bytes,
//! now)`) the sim and the generic drivers already use, plus the batch/deadline extras -
//! so the reactor/sharded/poll drivers run over it unchanged. Addresses use the same
//! `(ip:big-endian-u32 << 32 | port)` u64 convention as `io.zig`.
//!
//! Compiled **only on Linux**; on every other target `UdpSocket` is `void` (the portable
//! `std.Io` path in `io.zig` is used instead). Cross-compile-check: `-Dtarget=x86_64-linux`.

const std = @import("std");
const builtin = @import("builtin");

pub const UdpSocket = if (builtin.os.tag == .linux) LinuxUdp else void;

const linux = std.os.linux;

const LinuxUdp = struct {
    const Self = @This();
    fd: i32,

    pub const Recv = struct { addr: u64, len: usize };
    pub const Outgoing = struct { addr: u64, bytes: []const u8 };
    pub const batch_max = 64;

    // optnames not surfaced by std (stable Linux ABI).
    const UDP_SEGMENT: u32 = 103;
    const UDP_GRO: u32 = 104;
    const IP_MTU_DISCOVER: u32 = 10;
    const IP_PMTUDISC_DO: i32 = 2;

    fn ok(rc: usize) !void {
        if (linux.errno(rc) != .SUCCESS) return error.Syscall;
    }
    fn sa(addr_u64: u64) linux.sockaddr.in {
        return .{
            .port = std.mem.nativeToBig(u16, @intCast(addr_u64 & 0xffff)),
            .addr = std.mem.nativeToBig(u32, @intCast(addr_u64 >> 32)),
        };
    }
    fn fromSa(s: linux.sockaddr.in) u64 {
        return (@as(u64, std.mem.bigToNative(u32, s.addr)) << 32) | std.mem.bigToNative(u16, s.port);
    }

    /// Bind a non-blocking UDP socket (`port 0` = ephemeral; `reuseport` for sharded servers).
    pub fn bind(addr_u64: u64, reuseport: bool) !Self {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK, linux.IPPROTO.UDP);
        if (linux.errno(rc) != .SUCCESS) return error.Socket;
        var self = Self{ .fd = @intCast(rc) };
        errdefer self.close();
        const one: u32 = 1;
        try ok(linux.setsockopt(self.fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(u32)));
        if (reuseport) try ok(linux.setsockopt(self.fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&one), @sizeOf(u32)));
        var a = sa(addr_u64);
        try ok(linux.bind(self.fd, @ptrCast(&a), @sizeOf(linux.sockaddr.in)));
        return self;
    }

    pub fn close(self: *Self) void {
        _ = linux.close(self.fd);
    }

    /// The bound address (resolved ephemeral port), as a u64.
    pub fn localAddr(self: *Self) u64 {
        var a: linux.sockaddr.in = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = linux.getsockname(self.fd, @ptrCast(&a), &len);
        return fromSa(a);
    }

    // ---- duck-typed single transport (drives the generic reactor/poll/sharded) ----

    pub fn recv(self: *Self, buf: []u8, now: i64) ?Recv {
        _ = now;
        var from: linux.sockaddr.in = undefined;
        var fromlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const rc = linux.recvfrom(self.fd, buf.ptr, buf.len, 0, @ptrCast(&from), &fromlen);
        if (linux.errno(rc) != .SUCCESS) return null; // EAGAIN (non-blocking) → nothing ready
        return .{ .addr = fromSa(from), .len = rc };
    }

    pub fn send(self: *Self, addr_u64: u64, bytes: []const u8, now: i64) void {
        _ = now;
        var to = sa(addr_u64);
        _ = linux.sendto(self.fd, bytes.ptr, bytes.len, 0, @ptrCast(&to), @sizeOf(linux.sockaddr.in));
    }

    // ---- batch I/O (the D1 win) ----

    /// One `sendmmsg` for up to `batch_max` datagrams (different destinations OK). Returns
    /// how many the kernel accepted.
    pub fn sendBatch(self: *Self, out: []const Outgoing) usize {
        const n = @min(out.len, batch_max);
        var names: [batch_max]linux.sockaddr.in = undefined;
        var iovs: [batch_max]std.posix.iovec = undefined;
        var hdrs: [batch_max]linux.mmsghdr = undefined;
        for (0..n) |i| {
            names[i] = sa(out[i].addr);
            iovs[i] = .{ .base = @constCast(out[i].bytes.ptr), .len = out[i].bytes.len };
            hdrs[i] = .{ .hdr = .{
                .name = @ptrCast(&names[i]),
                .namelen = @sizeOf(linux.sockaddr.in),
                .iov = @ptrCast(&iovs[i]),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            }, .len = 0 };
        }
        const rc = linux.sendmmsg(self.fd, &hdrs, @intCast(n), 0);
        if (linux.errno(rc) != .SUCCESS) return 0;
        return rc;
    }

    /// One `recvmmsg` draining up to `bufs.len` datagrams; fills `out[0..count]`. Each
    /// `bufs[i]` must be ≥ max datagram size. With `timeout_ns == 0` it is non-blocking;
    /// otherwise it blocks until ≥1 datagram or the deadline (the idle-recv solution).
    pub fn recvBatch(self: *Self, bufs: [][]u8, out: []Recv, timeout_ns: u64) usize {
        const n = @min(@min(bufs.len, out.len), batch_max);
        var names: [batch_max]linux.sockaddr.in = undefined;
        var iovs: [batch_max]std.posix.iovec = undefined;
        var hdrs: [batch_max]linux.mmsghdr = undefined;
        for (0..n) |i| {
            iovs[i] = .{ .base = bufs[i].ptr, .len = bufs[i].len };
            hdrs[i] = .{ .hdr = .{
                .name = @ptrCast(&names[i]),
                .namelen = @sizeOf(linux.sockaddr.in),
                .iov = @ptrCast(&iovs[i]),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            }, .len = 0 };
        }
        const MSG_WAITFORONE: u32 = 0x10000;
        var ts: linux.timespec = .{ .sec = @intCast(timeout_ns / std.time.ns_per_s), .nsec = @intCast(timeout_ns % std.time.ns_per_s) };
        const flags: u32 = if (timeout_ns > 0) MSG_WAITFORONE else 0;
        const rc = linux.recvmmsg(self.fd, &hdrs, @intCast(n), flags, if (timeout_ns > 0) &ts else null);
        if (linux.errno(rc) != .SUCCESS) return 0;
        const got = rc;
        for (0..got) |i| out[i] = .{ .addr = fromSa(names[i]), .len = hdrs[i].len };
        return got;
    }

    /// Block until the socket is readable or `timeout_ns` elapses (the reactor's wait).
    pub fn waitReadable(self: *Self, timeout_ns: u64) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ms: i32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32)));
        const n = std.posix.poll(&fds, ms) catch return false;
        return n > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
    }

    // ---- live-PMTUD + GSO knobs ----

    /// Set the don't-fragment bit (kernel path-MTU discovery) so DF-padded `mtu.zig`
    /// probes are honored and an oversized datagram errors instead of fragmenting.
    pub fn setDontFragment(self: *Self, on: bool) !void {
        const v: i32 = if (on) IP_PMTUDISC_DO else 0;
        try ok(linux.setsockopt(self.fd, linux.IPPROTO.IP, IP_MTU_DISCOVER, std.mem.asBytes(&v), @sizeOf(i32)));
    }
    /// Enable kernel GSO: a single large `send` of N×`segment` bytes is split into N
    /// datagrams by the NIC/kernel.
    pub fn enableGso(self: *Self, segment: u16) !void {
        const v: u32 = segment;
        try ok(linux.setsockopt(self.fd, linux.IPPROTO.UDP, UDP_SEGMENT, std.mem.asBytes(&v), @sizeOf(u32)));
    }
    /// Enable kernel GRO: the kernel coalesces several same-flow datagrams into one
    /// `recv`, reporting the original segment size via a `UDP_GRO` control message.
    pub fn enableGro(self: *Self) !void {
        const v: u32 = 1;
        try ok(linux.setsockopt(self.fd, linux.IPPROTO.UDP, UDP_GRO, std.mem.asBytes(&v), @sizeOf(u32)));
    }

    pub const Gro = struct { addr: u64, bytes: []u8, seg: usize };

    /// Receive one (possibly GRO-coalesced) buffer and report the per-segment size from
    /// the `UDP_GRO` cmsg (`seg == bytes.len` when not coalesced). Split `bytes` into
    /// `seg`-sized datagrams (the last may be shorter) and `feed` each. Non-blocking.
    pub fn recvGro(self: *Self, buf: []u8) ?Gro {
        var from: linux.sockaddr.in = undefined;
        var ctrl: [64]u8 align(8) = undefined;
        var iov = [1]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
        var msg: linux.msghdr = .{
            .name = @ptrCast(&from),
            .namelen = @sizeOf(linux.sockaddr.in),
            .iov = &iov,
            .iovlen = 1,
            .control = &ctrl,
            .controllen = ctrl.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(self.fd, &msg, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const len = rc;
        var seg: usize = len; // default: a single datagram
        // walk control messages for a UDP_GRO segment size (u16)
        var off: usize = 0;
        const Cmsghdr = extern struct { len: usize, level: i32, type: i32 };
        while (off + @sizeOf(Cmsghdr) <= msg.controllen) {
            const c: *const Cmsghdr = @ptrCast(@alignCast(&ctrl[off]));
            if (c.len < @sizeOf(Cmsghdr)) break;
            if (c.level == linux.IPPROTO.UDP and c.type == UDP_GRO) {
                const data_off = off + ((@sizeOf(Cmsghdr) + 7) & ~@as(usize, 7));
                seg = std.mem.readInt(u16, ctrl[data_off..][0..2], .little);
            }
            off += (c.len + 7) & ~@as(usize, 7);
        }
        return .{ .addr = fromSa(from), .bytes = buf[0..len], .seg = if (seg == 0) len else seg };
    }
};

// A poll-based reactor over the Linux backend: wait (deadline) → drain recv → feed →
// flush transmits via `sendmmsg`. No `Io.Select`, so no blocked-recv cancellation issue.
pub fn runReactor(sock: *UdpSocket, ep: anytype, stop: anytype) void {
    if (comptime builtin.os.tag != .linux) return;
    var scratch: [1500]u8 = undefined;
    var out_bufs: [UdpSocket.batch_max][1500]u8 = undefined;
    var recvs: [UdpSocket.batch_max]UdpSocket.Recv = undefined;
    var bufs: [UdpSocket.batch_max][]u8 = undefined;
    for (0..UdpSocket.batch_max) |i| bufs[i] = &out_bufs[i];
    var outq: [UdpSocket.batch_max]UdpSocket.Outgoing = undefined;
    var outbuf: [UdpSocket.batch_max][1500]u8 = undefined;

    while (!stop.stopped()) {
        const now = nowMs();
        const deadline = ep.pollDeadline(now) orelse (now + 50);
        const wait_ns: u64 = @intCast(@max(deadline - now, 0) * std.time.ns_per_ms);
        const got = sock.recvBatch(&bufs, &recvs, wait_ns);
        for (0..got) |i| ep.feedFrom(recvs[i].addr, bufs[i][0..recvs[i].len], nowMs());
        // drain transmits and ship them in one sendmmsg.
        var nq: usize = 0;
        while (ep.pollTransmit(&scratch, now)) |d| {
            @memcpy(outbuf[nq][0..d.len], scratch[0..d.len]);
            outq[nq] = .{ .addr = d.addr, .bytes = outbuf[nq][0..d.len] };
            nq += 1;
            if (nq == UdpSocket.batch_max) {
                _ = sock.sendBatch(outq[0..nq]);
                nq = 0;
            }
        }
        if (nq > 0) _ = sock.sendBatch(outq[0..nq]);
    }
}

// A GRO-using reactor for the single-hot-flow case (a client, or a server behind one
// busy peer): the kernel coalesces a burst of same-flow datagrams into one `recvGro`,
// which we split back into `seg`-sized datagrams and feed individually. Fewer syscalls
// than per-datagram recv; complements the many-peer `recvmmsg` reactor above.
pub fn runReactorGro(sock: *UdpSocket, ep: anytype, stop: anytype) void {
    if (comptime builtin.os.tag != .linux) return;
    sock.enableGro() catch {};
    var rx: [64 * 1024]u8 = undefined; // GRO can coalesce up to ~64 KiB
    var scratch: [1500]u8 = undefined;
    while (!stop.stopped()) {
        const now = nowMs();
        const deadline = ep.pollDeadline(now) orelse (now + 50);
        const wait_ns: u64 = @intCast(@max(deadline - now, 0) * std.time.ns_per_ms);
        if (sock.waitReadable(wait_ns)) {
            while (sock.recvGro(&rx)) |g| {
                var off: usize = 0;
                while (off < g.bytes.len) {
                    const end = @min(off + g.seg, g.bytes.len);
                    ep.feedFrom(g.addr, g.bytes[off..end], nowMs()); // each coalesced segment
                    off = end;
                }
            }
        }
        while (ep.pollTransmit(&scratch, now)) |d| sock.send(d.addr, scratch[0..d.len], now);
    }
}

fn nowMs() i64 {
    return @intCast(@divTrunc(linux.timestamp(.MONOTONIC), std.time.ns_per_ms));
}

const testing = std.testing;

test "linux udp backend: loopback batch send/recv (linux only)" {
    if (comptime builtin.os.tag == .linux) {
        var srv = try UdpSocket.bind(0, false);
        defer srv.close();
        var cli = try UdpSocket.bind(0, false);
        defer cli.close();
        const srv_addr = srv.localAddr();

        // batch-send two datagrams to the server in one syscall.
        const out = [_]UdpSocket.Outgoing{
            .{ .addr = srv_addr, .bytes = "alpha" },
            .{ .addr = srv_addr, .bytes = "beta" },
        };
        try testing.expectEqual(@as(usize, 2), cli.sendBatch(&out));

        // batch-recv them (deadline-bounded so it can't hang the test).
        var b0: [64]u8 = undefined;
        var b1: [64]u8 = undefined;
        var bufs = [_][]u8{ &b0, &b1 };
        var recvs: [2]UdpSocket.Recv = undefined;
        const got = srv.recvBatch(&bufs, &recvs, 500 * std.time.ns_per_ms);
        try testing.expectEqual(@as(usize, 2), got);
        try testing.expect(recvs[0].len == 5 or recvs[0].len == 4);
    }
}

// A genuine real-network test: two magnet Endpoints over two real non-blocking UDP
// sockets, exchanging reliable-ordered messages through the actual kernel loopback
// stack (not the sim). Runs on the Linux CI runner; compiled out elsewhere.
const Config = @import("config").Config;
const Endpoint = @import("proto").Endpoint;
const channels = @import("proto").channels;

test "two endpoints exchange reliable data over real kernel UDP loopback (linux only)" {
    if (comptime builtin.os.tag != .linux) return;
    const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
    const Cfg = Config{ .channels = Schema, .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };
    const Ep = Endpoint(Cfg);
    const alloc = testing.allocator;

    var csock = UdpSocket.bind(0, false) catch return; // sandbox may forbid → skip
    defer csock.close();
    var ssock = UdpSocket.bind(0, false) catch return;
    defer ssock.close();
    const caddr = csock.localAddr();
    const saddr = ssock.localAddr();

    const client = try alloc.create(Ep);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(Ep);
    defer alloc.destroy(server);
    server.* = .{};

    const N: u32 = 50;
    var queued: u32 = 0;
    var delivered: usize = 0;
    var scratch: [1500]u8 = undefined;
    var out: [64]u8 = undefined;
    var step: usize = 0;
    while (step < 200_000 and delivered < N) : (step += 1) {
        const now = nowMs();
        while (queued < N) : (queued += 1) {
            var w: [4]u8 = undefined;
            std.mem.writeInt(u32, &w, queued, .little);
            client.sendRawTo(saddr, .rel, &w) catch break;
        }
        // pump both endpoints over the real sockets (non-blocking recv → null on EAGAIN)
        while (client.pollTransmit(&scratch, now)) |d| csock.send(d.addr, scratch[0..d.len], now);
        while (ssock.recv(&scratch, now)) |r| server.feedFrom(r.addr, scratch[0..r.len], now);
        while (server.pollTransmit(&scratch, now)) |d| ssock.send(d.addr, scratch[0..d.len], now);
        while (csock.recv(&scratch, now)) |r| client.feedFrom(r.addr, scratch[0..r.len], now);
        while (server.receiveRawFrom(caddr, .rel, &out)) |_| delivered += 1;
    }
    try testing.expectEqual(@as(usize, N), delivered); // reliable delivery over real UDP
}
