//! The bridge: maps a transmitted packet number to the reliable message
//! ids it carried (plus its send time), so an ACK translates to per-message acks
//! and a loss makes those messages re-eligible for packing. Backed by the
//! `SequenceBuffer` keyed by packet number; no per-packet allocation.

const std = @import("std");
const SequenceBuffer = @import("core").SequenceBuffer;

pub fn Bridge(comptime Pn: type, comptime Id: type, comptime cap: usize, comptime max_msgs: usize) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { ids: [max_msgs]Id, n: u8, time: i64, size: u32 };

        buf: SequenceBuffer(Entry, cap, Pn) = .{},

        pub fn record(self: *Self, pn: Pn, ids: []const Id, size: u32, time: i64) void {
            std.debug.assert(ids.len <= max_msgs);
            var e = Entry{ .ids = undefined, .n = @intCast(ids.len), .time = time, .size = size };
            @memcpy(e.ids[0..ids.len], ids);
            self.buf.insert(pn, e);
        }

        pub fn get(self: *Self, pn: Pn) ?*Entry {
            return self.buf.get(pn);
        }

        pub fn remove(self: *Self, pn: Pn) void {
            self.buf.remove(pn);
        }
    };
}

const testing = std.testing;

test "bridge records and retrieves message ids" {
    var b = Bridge(u16, u16, 64, 8){};
    b.record(5, &.{ 100, 101, 102 }, 42, 1234);
    const e = b.get(5).?;
    try testing.expectEqual(@as(u8, 3), e.n);
    try testing.expectEqual(@as(u32, 42), e.size);
    try testing.expectEqual(@as(u16, 101), e.ids[1]);
    try testing.expectEqual(@as(i64, 1234), e.time);
    b.remove(5);
    try testing.expect(b.get(5) == null);
}
