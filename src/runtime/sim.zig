//! Deterministic network simulator: a plain virtual-clock, seeded link between
//! two peers (no `std.Io` - the sans-IO core needs none). The test substrate the
//! whole protocol is verified against. Real `std.Io` socket drivers land later.

const std = @import("std");

pub const Params = struct {
    latency_ms: i64 = 50,
    jitter_ms: i64 = 0,
    loss_permille: u32 = 0,
    dup_permille: u32 = 0,
    seed: u64 = 0,
    max_datagram: u16 = 1200,
};

/// `to_b` = A→B, `to_a` = B→A.
pub const Dir = enum { to_a, to_b };

pub fn Link(comptime cap: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            used: bool = false,
            deliver_at: i64 = 0,
            len: u16 = 0,
            data: [1200]u8 = undefined,
        };

        params: Params,
        prng: std.Random.DefaultPrng,
        to_a: [cap]Slot = [_]Slot{.{}} ** cap,
        to_b: [cap]Slot = [_]Slot{.{}} ** cap,
        sent: u64 = 0,
        dropped: u64 = 0,

        pub fn init(params: Params) Self {
            return .{ .params = params, .prng = std.Random.DefaultPrng.init(params.seed) };
        }

        fn queue(self: *Self, dir: Dir) *[cap]Slot {
            return switch (dir) {
                .to_a => &self.to_a,
                .to_b => &self.to_b,
            };
        }

        fn enqueue(self: *Self, q: *[cap]Slot, bytes: []const u8, at: i64) void {
            for (q) |*s| {
                if (!s.used) {
                    s.used = true;
                    s.deliver_at = at;
                    s.len = @intCast(bytes.len);
                    @memcpy(s.data[0..bytes.len], bytes);
                    return;
                }
            }
            self.dropped += 1;
        }

        pub fn send(self: *Self, dir: Dir, bytes: []const u8, now: i64) void {
            std.debug.assert(bytes.len <= self.params.max_datagram);
            self.sent += 1;
            const rnd = self.prng.random();
            if (self.params.loss_permille > 0 and rnd.uintLessThan(u32, 1000) < self.params.loss_permille) {
                self.dropped += 1;
                return;
            }
            const jitter: i64 = if (self.params.jitter_ms > 0)
                rnd.intRangeAtMost(i64, 0, self.params.jitter_ms)
            else
                0;
            const at = now + self.params.latency_ms + jitter;
            self.enqueue(self.queue(dir), bytes, at);
            if (self.params.dup_permille > 0 and rnd.uintLessThan(u32, 1000) < self.params.dup_permille) {
                self.enqueue(self.queue(dir), bytes, at + 1);
            }
        }

        pub fn poll(self: *Self, dir: Dir, now: i64, out: []u8) ?usize {
            const q = self.queue(dir);
            var best: ?usize = null;
            for (q, 0..) |*s, i| {
                if (s.used and s.deliver_at <= now) {
                    if (best == null or s.deliver_at < q[best.?].deliver_at) best = i;
                }
            }
            const idx = best orelse return null;
            const s = &q[idx];
            @memcpy(out[0..s.len], s.data[0..s.len]);
            const len = s.len;
            s.used = false;
            return len;
        }
    };
}

pub const DefaultLink = Link(2048);

/// Adapts one side of a `Link` to the `recv`/`send` duck-typed transport that the
/// poll driver expects. `peer_addr` is the constant address of the far side.
pub fn Transport(comptime LinkT: type) type {
    return struct {
        const Self = @This();
        pub const Recv = struct { addr: u64, len: usize };

        link: *LinkT,
        recv_dir: Dir,
        send_dir: Dir,
        peer_addr: u64,

        pub fn recv(self: *Self, buf: []u8, now: i64) ?Recv {
            const n = self.link.poll(self.recv_dir, now, buf) orelse return null;
            return .{ .addr = self.peer_addr, .len = n };
        }
        pub fn send(self: *Self, addr: u64, bytes: []const u8, now: i64) void {
            _ = addr;
            self.link.send(self.send_dir, bytes, now);
        }
    };
}

const testing = std.testing;

test "sim delivers after latency; 100% loss drops all" {
    // small link (DefaultLink is multi-MB; real callers heap-allocate it).
    var link = Link(8).init(.{ .latency_ms = 50, .seed = 1 });
    var buf: [16]u8 = undefined;
    link.send(.to_b, "hi", 0);
    try testing.expect(link.poll(.to_b, 49, &buf) == null);
    const n = link.poll(.to_b, 50, &buf).?;
    try testing.expectEqualSlices(u8, "hi", buf[0..n]);

    var lossy = Link(8).init(.{ .latency_ms = 10, .loss_permille = 1000, .seed = 2 });
    var i: usize = 0;
    while (i < 10) : (i += 1) lossy.send(.to_b, "x", 0);
    try testing.expect(lossy.poll(.to_b, 1000, &buf) == null);
}
