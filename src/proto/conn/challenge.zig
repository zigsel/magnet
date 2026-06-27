//! Stateless SipHash challenge cookie (GNS `udp.cpp` model). On a connection
//! request the server stores **zero** per-client state: it returns
//! `cookie = SipHash(secret, client_addr ++ coarse_time)` together with the coarse
//! timestamp. The client must echo both back; the server recomputes the cookie and
//! checks it (constant-time) plus the timestamp's freshness - no table of issued
//! challenges. This is SYN-cookie-grade DoS resistance: an off-path attacker cannot
//! force the server to allocate a connection slot. The secret rotates on an
//! interval; validation accepts the current and the previous secret.

const std = @import("std");

const Sip = std.crypto.auth.siphash.SipHash64(1, 3);

pub const Challenger = struct {
    secret: [16]u8,
    prev: [16]u8,
    has_prev: bool = false,
    rotate_at_s: i64 = 0,
    rotation_s: i64 = 4,
    /// Accept a cookie whose coarse time is within this many seconds of now.
    freshness_s: i64 = 5,

    pub fn init(secret: [16]u8, rotation_s: i64) Challenger {
        return .{ .secret = secret, .prev = secret, .rotation_s = rotation_s };
    }

    /// Coarse time used in the cookie (seconds since the epoch the caller chose).
    pub fn coarse(now_ms: i64) u32 {
        return @intCast(@as(u64, @bitCast(@divTrunc(now_ms, 1000))) & 0xffff_ffff);
    }

    fn compute(secret: *const [16]u8, addr: u64, coarse_s: u32) u64 {
        var msg: [12]u8 = undefined;
        std.mem.writeInt(u64, msg[0..8], addr, .little);
        std.mem.writeInt(u32, msg[8..12], coarse_s, .little);
        var out: [8]u8 = undefined;
        Sip.create(&out, &msg, secret);
        return std.mem.readInt(u64, &out, .little);
    }

    /// Rotate the active secret if the interval elapsed. `new_secret` is supplied by
    /// the caller (e.g. a CSPRNG draw) since this module takes no clock/RNG of its own.
    pub fn maybeRotate(self: *Challenger, now_ms: i64, new_secret: [16]u8) void {
        const now_s = @divTrunc(now_ms, 1000);
        if (self.rotate_at_s == 0) {
            self.rotate_at_s = now_s + self.rotation_s;
            return;
        }
        if (now_s >= self.rotate_at_s) {
            self.prev = self.secret;
            self.has_prev = true;
            self.secret = new_secret;
            self.rotate_at_s = now_s + self.rotation_s;
        }
    }

    /// Issue a cookie for `addr` at `now_ms`. Returns `(coarse, cookie)` to put on
    /// the wire. No state is stored.
    pub fn issue(self: *const Challenger, addr: u64, now_ms: i64) struct { coarse: u32, cookie: u64 } {
        const c = coarse(now_ms);
        return .{ .coarse = c, .cookie = compute(&self.secret, addr, c) };
    }

    /// Verify an echoed `(coarse, cookie)` for `addr` at `now_ms`: constant-time
    /// match against the current or previous secret, and the coarse time fresh.
    pub fn verify(self: *const Challenger, addr: u64, coarse_s: u32, cookie: u64, now_ms: i64) bool {
        const now_s = @divTrunc(now_ms, 1000);
        const age = now_s - @as(i64, coarse_s);
        if (age < -self.freshness_s or age > self.freshness_s) return false;
        const want_cur = compute(&self.secret, addr, coarse_s);
        var ok = ctEqU64(want_cur, cookie);
        if (self.has_prev) {
            const want_prev = compute(&self.prev, addr, coarse_s);
            ok = ok or ctEqU64(want_prev, cookie);
        }
        return ok;
    }
};

/// Constant-time u64 equality (avoid a timing oracle on the cookie).
fn ctEqU64(a: u64, b: u64) bool {
    var ab: [8]u8 = undefined;
    var bb: [8]u8 = undefined;
    std.mem.writeInt(u64, &ab, a, .little);
    std.mem.writeInt(u64, &bb, b, .little);
    return std.crypto.timing_safe.eql([8]u8, ab, bb);
}

const testing = std.testing;

test "valid echoed cookie verifies; wrong addr/cookie rejected" {
    const ch = Challenger.init([_]u8{0xAB} ** 16, 4);
    const addr: u64 = 0xDEAD_BEEF;
    const now: i64 = 10_000_000;
    const c = ch.issue(addr, now);
    try testing.expect(ch.verify(addr, c.coarse, c.cookie, now));
    try testing.expect(!ch.verify(addr + 1, c.coarse, c.cookie, now)); // different client
    try testing.expect(!ch.verify(addr, c.coarse, c.cookie ^ 1, now)); // forged cookie
}

test "stale cookie rejected by freshness" {
    const ch = Challenger.init([_]u8{1} ** 16, 4);
    const addr: u64 = 7;
    const c = ch.issue(addr, 0);
    try testing.expect(ch.verify(addr, c.coarse, c.cookie, 3_000)); // 3s later, fresh
    try testing.expect(!ch.verify(addr, c.coarse, c.cookie, 60_000)); // 60s later, stale
}

test "previous secret still accepted across a rotation" {
    var ch = Challenger.init([_]u8{2} ** 16, 4);
    const addr: u64 = 99;
    const c = ch.issue(addr, 0);
    ch.maybeRotate(0, [_]u8{2} ** 16); // arm rotate_at
    ch.maybeRotate(5_000, [_]u8{9} ** 16); // rotate: prev = old secret
    try testing.expect(ch.has_prev);
    try testing.expect(ch.verify(addr, c.coarse, c.cookie, 5_000)); // old cookie still ok
}
