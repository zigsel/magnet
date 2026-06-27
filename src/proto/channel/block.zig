//! Block channel: a single large blob (initial world state, an asset) carried over
//! a reliable-ordered channel, fragmented with `delivery/frag.zig` and reassembled
//! at the far end. A thin composition of fragmentation + reliable ordering
//! (the reliable channel guarantees every fragment arrives; frag handles assembly).

const std = @import("std");
const frag = @import("../delivery/frag.zig");

pub const fragmentCount = frag.fragmentCount;
pub const fragmentSlice = frag.fragmentSlice;

/// Receives one block at a time (`slots = 1`), reassembling its fragments.
pub fn Block(comptime frag_payload: usize, comptime max_frags: usize) type {
    return struct {
        const Self = @This();
        const Reasm = frag.Reassembler(frag_payload, max_frags, 1);
        pub const max_block = Reasm.max_message;
        pub const payload = frag_payload;

        reasm: Reasm = .{},

        /// Feed a fragment; returns the full block when complete (valid until the
        /// next feed), else null.
        pub fn feed(self: *Self, group: u16, index: u16, count: u16, chunk: []const u8) ?[]const u8 {
            const c = self.reasm.feed(0, .{ .group = group, .index = index, .count = count }, chunk) orelse return null;
            return c.bytes;
        }
    };
}

const testing = std.testing;

test "block transfer fragments and reassembles a large blob over reliable-ordered" {
    const FP = 256;
    var blob: [4096]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = @truncate(i *% 91 +% 3);

    const n = fragmentCount(blob.len, FP);
    var b = Block(FP, 32){};
    var done: ?[]const u8 = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        done = b.feed(1, @intCast(i), @intCast(n), fragmentSlice(&blob, i, FP));
    }
    try testing.expect(done != null);
    try testing.expectEqualSlices(u8, &blob, done.?);
}
