//! Connection IDs & migration (a-la-carte; `Security.connection_ids = true`).
//!
//! A connection is identified by an opaque **connection id** carried in the packet
//! header, not by the 4-tuple - so it survives a NAT rebinding or an IP change. Each
//! side derives its own *local* CID (the value the peer stamps when addressing it)
//! and learns the peer's CID during the handshake.
//!
//! Migration uses quinn's NAT-rebind heuristic over a `(ip:u32 << 32 | port:u32)`
//! address convention: same IP + new port ⇒ a port remap (keep RTT/cc/MTU); new IP
//! ⇒ reset path state and validate the new path with PATH_CHALLENGE/PATH_RESPONSE
//! before resuming full send. The 8-byte challenge token is unguessable to an
//! off-path attacker, so it cannot complete validation for a spoofed path.

const std = @import("std");

pub const Cid = u64;
pub const none: Cid = 0;

const Sip = std.crypto.auth.siphash.SipHash64(1, 3);

/// Deterministically derive a (nonzero) local CID for a peer address from a secret,
/// so a stateless server can recompute the CID it issued without storing it.
pub fn derive(secret: [16]u8, addr: u64) Cid {
    var msg: [8]u8 = undefined;
    std.mem.writeInt(u64, &msg, addr, .little);
    var out: [8]u8 = undefined;
    Sip.create(&out, &msg, &secret);
    const c = std.mem.readInt(u64, &out, .little);
    return if (c == none) 1 else c;
}

/// How a new source address relates to the connection's current one.
pub const Rebind = enum { same, port_only, ip_change };

pub fn classify(old_addr: u64, new_addr: u64) Rebind {
    if (old_addr == new_addr) return .same;
    if ((old_addr >> 32) == (new_addr >> 32)) return .port_only; // same IP, new port
    return .ip_change;
}

/// The set of local CIDs we currently accept (peer addresses us by one of these).
/// Small fixed ring; issuing past capacity retires the oldest.
pub fn CidQueue(comptime cap: usize) type {
    if (cap == 0) @compileError("CidQueue cap must be > 0");
    return struct {
        const Self = @This();
        cids: [cap]Cid = [_]Cid{none} ** cap,

        pub fn issue(self: *Self, c: Cid) void {
            // shift down, append (drop-oldest)
            var i: usize = 0;
            while (i + 1 < cap) : (i += 1) self.cids[i] = self.cids[i + 1];
            self.cids[cap - 1] = c;
        }
        pub fn has(self: *const Self, c: Cid) bool {
            if (c == none) return false;
            for (self.cids) |x| {
                if (x == c) return true;
            }
            return false;
        }
        pub fn retire(self: *Self, c: Cid) void {
            for (&self.cids) |*x| {
                if (x.* == c) x.* = none;
            }
        }
    };
}

/// Per-path validation. A new (unvalidated) path is probed with a PATH_CHALLENGE
/// carrying `token`; the peer echoes it in a PATH_RESPONSE. The handshake validates
/// the initial path, so `validated` starts true.
pub const PathValidator = struct {
    token: u64 = 0,
    pending: bool = false,
    validated: bool = true,

    /// Begin validating a new path with `token` (data send pauses until validated).
    pub fn begin(self: *PathValidator, token: u64) void {
        self.token = token;
        self.pending = true;
        self.validated = false;
    }
    /// A PATH_RESPONSE arrived; returns true if it validates the pending challenge.
    pub fn onResponse(self: *PathValidator, token: u64) bool {
        if (self.pending and token == self.token) {
            self.pending = false;
            self.validated = true;
            return true;
        }
        return false;
    }
};

const testing = std.testing;

test "classify port vs ip change" {
    const a: u64 = (0x0A00_0001 << 32) | 5000; // 10.0.0.1:5000
    const b: u64 = (0x0A00_0001 << 32) | 6000; // 10.0.0.1:6000 (port remap)
    const c: u64 = (0x0A00_0002 << 32) | 5000; // 10.0.0.2:5000 (new IP)
    try testing.expectEqual(Rebind.same, classify(a, a));
    try testing.expectEqual(Rebind.port_only, classify(a, b));
    try testing.expectEqual(Rebind.ip_change, classify(a, c));
}

test "derive is deterministic, nonzero, address-specific" {
    const secret = [_]u8{0x33} ** 16;
    const x = derive(secret, 1234);
    try testing.expectEqual(x, derive(secret, 1234));
    try testing.expect(x != none);
    try testing.expect(derive(secret, 1234) != derive(secret, 1235));
}

test "cid queue issues, matches, retires (drop-oldest)" {
    var q = CidQueue(3){};
    q.issue(10);
    q.issue(20);
    q.issue(30);
    try testing.expect(q.has(10) and q.has(20) and q.has(30));
    try testing.expect(!q.has(99));
    try testing.expect(!q.has(none));
    q.issue(40); // drops 10
    try testing.expect(!q.has(10));
    try testing.expect(q.has(40));
    q.retire(20);
    try testing.expect(!q.has(20));
}

test "path validator: handshake path valid; new path needs an echoed token" {
    var p = PathValidator{};
    try testing.expect(p.validated);
    p.begin(0xABCD);
    try testing.expect(!p.validated and p.pending);
    try testing.expect(!p.onResponse(0x1111)); // wrong token
    try testing.expect(!p.validated);
    try testing.expect(p.onResponse(0xABCD)); // correct
    try testing.expect(p.validated and !p.pending);
}
