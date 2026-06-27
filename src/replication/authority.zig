//! Per-entity authority + transfer (client-authoritative replication). By default the
//! server owns (simulates + replicates) every entity. Authority over an entity can be
//! *transferred* to a client: that client then simulates it locally and ships its
//! authoritative state up to the server, which stores it (without simulating) and
//! re-replicates to the *other* clients - and never echoes it back to the owner. This
//! is what makes client-spawned objects (a thrown grenade, a dropped item) feel instant
//! while still becoming server-managed. The owner is server-decided; transfer flows as a
//! tiny request/grant exchanged over a reliable channel (the app routes the bytes).

const std = @import("std");

/// 0 = the server; a client owns with id `client + 1`.
pub const server: u16 = 0;
pub fn client(id: u16) u16 {
    return id + 1;
}

/// Fixed table mapping a network id (entity slot) → its owner. Zero-alloc.
pub fn Table(comptime max: usize) type {
    return struct {
        const Self = @This();
        owner: [max]u16 = [_]u16{server} ** max,

        pub fn set(self: *Self, net_id: u32, who: u16) void {
            if (net_id < max) self.owner[net_id] = who;
        }
        pub fn get(self: *const Self, net_id: u32) u16 {
            return if (net_id < max) self.owner[net_id] else server;
        }
        pub fn serverOwns(self: *const Self, net_id: u32) bool {
            return self.get(net_id) == server;
        }
        pub fn ownedBy(self: *const Self, net_id: u32, who: u16) bool {
            return self.get(net_id) == who;
        }
    };
}

/// A client asks the server for authority over `net_id`.
pub const Request = struct { net_id: u32, client_id: u16 };
/// The server assigns `net_id`'s authority to `owner` (broadcast to all clients so the
/// new owner starts simulating and the old one stops). `owner == server` revokes.
pub const Grant = struct { net_id: u32, owner: u16 };

const testing = std.testing;

test "authority table: server-owned by default, transfer + revoke" {
    var t = Table(16){};
    try testing.expect(t.serverOwns(3)); // default
    t.set(3, client(2)); // grant to client 2
    try testing.expect(!t.serverOwns(3));
    try testing.expect(t.ownedBy(3, client(2)));
    try testing.expect(!t.ownedBy(3, client(0)));
    t.set(3, server); // revoke back to server
    try testing.expect(t.serverOwns(3));
}

test "request/grant identify owner ids consistently" {
    const req = Request{ .net_id = 7, .client_id = 4 };
    const grant = Grant{ .net_id = req.net_id, .owner = client(req.client_id) };
    try testing.expectEqual(@as(u16, 5), grant.owner); // client 4 → owner id 5
    try testing.expectEqual(server, @as(u16, 0));
}
