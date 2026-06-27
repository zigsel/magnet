//! `Channel(comptime mode, T, cap)` - the per-channel state, **monomorphized** per
//! reliability mode. An unreliable channel compiles out the retransmit send queue
//! *and* the reorder window (zero state beyond a tiny sequencer); reliable-ordered
//! carries both. Send-side uses lazy dense numbering (`ordering.Sequencer`);
//! receive-side delegates to `ordering.Receiver`.

const std = @import("std");
const ordering = @import("ordering.zig");
const SequenceBuffer = @import("core").SequenceBuffer;

pub const Mode = ordering.Mode;

pub fn Channel(comptime mode: Mode, comptime T: type, comptime cap: usize) type {
    const reliable = ordering.isReliable(mode);
    const OutMsg = struct { value: T, acked: bool, ever_sent: bool, last_sent: i64 };

    return struct {
        const Self = @This();
        pub const channel_mode = mode;
        pub const is_reliable = reliable;

        seqr: ordering.Sequencer = .{},
        recv: ordering.Receiver(mode, T, cap, u16) = .{},
        // retransmit window - only for reliable modes (compiled out otherwise)
        send_q: if (reliable) SequenceBuffer(OutMsg, cap, u16) else void =
            if (reliable) .{} else {},

        /// Assign a data-sequence for a new outgoing message; for reliable modes,
        /// also store it for retransmission. Returns the sequence.
        pub fn send(self: *Self, value: T) u16 {
            const s = self.seqr.alloc();
            if (reliable) {
                self.send_q.insert(s, .{ .value = value, .acked = false, .ever_sent = false, .last_sent = 0 });
            }
            return s;
        }

        /// Mark a sent message acknowledged (reliable modes).
        pub fn onAck(self: *Self, s: u16) void {
            if (reliable) {
                if (self.send_q.get(s)) |m| m.acked = true;
            }
        }

        /// Is sequence `s` still awaiting ack (and thus eligible for resend)?
        pub fn unacked(self: *Self, s: u16) ?*OutMsg {
            if (!reliable) return null;
            const m = self.send_q.get(s) orelse return null;
            return if (m.acked) null else m;
        }

        /// Feed a received message; delivered items (possibly several) go to `out`.
        pub fn accept(self: *Self, s: u16, value: T, out: anytype) void {
            self.recv.accept(s, value, out);
        }
    };
}

const testing = std.testing;

fn Collector(comptime N: usize) type {
    return struct {
        items: [N]u32 = undefined,
        n: usize = 0,
        pub fn push(self: *@This(), v: u32) void {
            self.items[self.n] = v;
            self.n += 1;
        }
    };
}

test "unreliable channel is (near) stateless; reliable carries the send queue" {
    try testing.expect(@sizeOf(Channel(.unreliable, u32, 64)) < @sizeOf(Channel(.reliable_ordered, u32, 64)));
    // unreliable: only the 2-byte sequencer
    try testing.expect(@sizeOf(Channel(.unreliable, u32, 64)) <= 8);
}

test "reliable channel: send stores, ack clears, dense sequences" {
    var ch = Channel(.reliable_ordered, u32, 64){};
    const s0 = ch.send(100);
    const s1 = ch.send(200);
    try testing.expectEqual(@as(u16, 0), s0);
    try testing.expectEqual(@as(u16, 1), s1);
    try testing.expect(ch.unacked(s0) != null);
    ch.onAck(s0);
    try testing.expect(ch.unacked(s0) == null); // acked
    try testing.expect(ch.unacked(s1) != null);
}

test "channel routes receive through its mode (reliable_ordered reorders)" {
    var ch = Channel(.reliable_ordered, u32, 64){};
    var c = Collector(8){};
    ch.accept(1, 10, &c);
    ch.accept(0, 0, &c);
    try testing.expectEqual(@as(usize, 2), c.n);
    try testing.expectEqual(@as(u32, 0), c.items[0]);
    try testing.expectEqual(@as(u32, 10), c.items[1]);
}
