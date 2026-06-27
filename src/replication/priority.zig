//! Replication **priority accumulator** + byte budget. Each entity's send
//! priority climbs every tick it goes unsent (`accumulate`), so a starved entity
//! eventually wins regardless of how busy the link is; sending it resets it. The
//! per-tick byte budget then takes the highest-priority entities first - far/idle
//! entities update less often, near/important ones more, for free. (Same shape as
//! the WFQ accumulator, applied to entities instead of lanes.)

const std = @import("std");

pub fn Priority(comptime max: usize) type {
    return struct {
        const Self = @This();
        acc: [max]i64 = [_]i64{0} ** max,

        /// Climb entity `e`'s priority (e.g. `base * distance_weight`).
        pub fn accumulate(self: *Self, e: usize, amount: i64) void {
            self.acc[e] += amount;
        }
        pub fn priorityOf(self: *const Self, e: usize) i64 {
            return self.acc[e];
        }
        /// It was sent this tick → reset.
        pub fn reset(self: *Self, e: usize) void {
            self.acc[e] = 0;
        }

        /// Sort `entities` in place by descending accumulated priority (insertion
        /// sort - `entities` is the small per-client interest set, already filtered).
        pub fn order(self: *const Self, entities: []u32) void {
            var i: usize = 1;
            while (i < entities.len) : (i += 1) {
                const v = entities[i];
                const pv = self.acc[v];
                var j = i;
                while (j > 0 and self.acc[entities[j - 1]] < pv) : (j -= 1) {
                    entities[j] = entities[j - 1];
                }
                entities[j] = v;
            }
        }
    };
}

/// A simple byte budget (measure-before-commit), mirroring `proto.channel.packer`
/// but local to the replication layer.
pub const Budget = struct {
    remaining_bytes: usize,
    pub fn init(bytes: usize) Budget {
        return .{ .remaining_bytes = bytes };
    }
    pub fn take(self: *Budget, bytes: usize) bool {
        if (bytes > self.remaining_bytes) return false;
        self.remaining_bytes -= bytes;
        return true;
    }
};

const testing = std.testing;

test "accumulate, reset, and descending order" {
    var p = Priority(8){};
    p.accumulate(0, 10);
    p.accumulate(1, 50);
    p.accumulate(2, 30);
    var ents = [_]u32{ 0, 1, 2 };
    p.order(&ents);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, &ents); // 50, 30, 10
    p.reset(1);
    try testing.expectEqual(@as(i64, 0), p.priorityOf(1));
    p.order(&ents);
    try testing.expectEqual(@as(u32, 2), ents[0]); // 30 now highest
}

test "budget takes until exhausted" {
    var b = Budget.init(100);
    try testing.expect(b.take(60));
    try testing.expect(!b.take(50)); // 40 left
    try testing.expect(b.take(40));
    try testing.expect(!b.take(1));
}
