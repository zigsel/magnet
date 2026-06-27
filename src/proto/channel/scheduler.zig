//! Weighted-fair lane scheduler (GNS-style): strict priority across classes,
//! weighted-fair queueing within a class via virtual finish time, plus anti-
//! starvation aging so a lower-priority lane that has waited too long is boosted
//! and eventually serviced. O(lanes) per pick.

const std = @import("std");

pub fn Scheduler(comptime n: usize) type {
    return struct {
        const Self = @This();
        const base_vt: i64 = 65536;
        const starve_boost_after: u32 = 16;
        const boost: i32 = 1000;

        const Lane = struct {
            priority: u8 = 0, // higher = more important
            weight: u32 = 1, // larger = more bandwidth within its class
            virt: i64 = 0, // virtual finish time
            pending: u32 = 0, // bytes queued
            starved: u32 = 0, // rounds waited with data but not serviced
        };

        lanes: [n]Lane = [_]Lane{.{}} ** n,

        pub fn configure(self: *Self, lane: usize, priority: u8, weight: u32) void {
            self.lanes[lane].priority = priority;
            self.lanes[lane].weight = @max(weight, 1);
        }

        pub fn enqueue(self: *Self, lane: usize, bytes: u32) void {
            self.lanes[lane].pending += bytes;
        }

        /// The next lane to service, or null if nothing is queued.
        pub fn pick(self: *Self) ?usize {
            var best: ?usize = null;
            var best_eff: i32 = std.math.minInt(i32);
            var best_virt: i64 = 0;
            for (self.lanes, 0..) |l, i| {
                if (l.pending == 0) continue;
                const eff: i32 = @as(i32, l.priority) + (if (l.starved >= starve_boost_after) boost else 0);
                if (best == null or eff > best_eff or (eff == best_eff and l.virt < best_virt)) {
                    best = i;
                    best_eff = eff;
                    best_virt = l.virt;
                }
            }
            return best;
        }

        /// Charge `bytes` to `lane`: advance its virtual clock, reset its starvation
        /// counter, and age every other waiting lane.
        pub fn service(self: *Self, lane: usize, bytes: u32) void {
            const l = &self.lanes[lane];
            l.pending -= @min(l.pending, bytes);
            l.virt += @divTrunc(base_vt * @as(i64, bytes), @as(i64, l.weight));
            l.starved = 0;
            for (&self.lanes, 0..) |*o, i| {
                if (i != lane and o.pending > 0) o.starved += 1;
            }
        }

        // ---- ready-set variant (datagram packing) ----
        // The packer recomputes a per-lane "has a sendable message right now" set
        // each step (dueness/fit/cwnd change as the datagram fills), rather than
        // streaming bytes through enqueue/pending. `pickReady` chooses by the same
        // strict-priority + virtual-finish-time + anti-starvation rule; `charge`
        // advances the picked lane's virtual clock and ages the other ready lanes.

        /// The next lane to service among those flagged ready, or null if none.
        pub fn pickReady(self: *Self, ready: []const bool) ?usize {
            var best: ?usize = null;
            var best_eff: i32 = std.math.minInt(i32);
            var best_virt: i64 = 0;
            for (self.lanes, 0..) |l, i| {
                if (!ready[i]) continue;
                const eff: i32 = @as(i32, l.priority) + (if (l.starved >= starve_boost_after) boost else 0);
                if (best == null or eff > best_eff or (eff == best_eff and l.virt < best_virt)) {
                    best = i;
                    best_eff = eff;
                    best_virt = l.virt;
                }
            }
            return best;
        }

        /// Advance `lane`'s virtual clock by `bytes`, reset its starvation, and age
        /// the other lanes that were ready this step.
        pub fn charge(self: *Self, lane: usize, bytes: u32, ready: []const bool) void {
            const l = &self.lanes[lane];
            l.virt += @divTrunc(base_vt * @as(i64, bytes), @as(i64, l.weight));
            l.starved = 0;
            for (&self.lanes, 0..) |*o, i| {
                if (i != lane and ready[i]) o.starved += 1;
            }
        }
    };
}

const testing = std.testing;

test "WFQ weighted fairness within a class (3:1)" {
    var s = Scheduler(2){};
    s.configure(0, 0, 3);
    s.configure(1, 0, 1);
    s.enqueue(0, 1_000_000);
    s.enqueue(1, 1_000_000);
    var c0: usize = 0;
    var c1: usize = 0;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const l = s.pick().?;
        s.service(l, 100);
        if (l == 0) c0 += 1 else c1 += 1;
    }
    // lane 0 has 3× the weight → ~3× the service
    try testing.expect(c0 > c1 * 2 and c0 < c1 * 4);
}

test "strict priority + anti-starvation across five channels (no HOL)" {
    var s = Scheduler(5){};
    s.configure(0, 5, 1); // high priority, never empties
    s.enqueue(0, 10_000_000);
    var ch: usize = 1;
    while (ch < 5) : (ch += 1) {
        s.configure(ch, 1, 1); // low priority, a little data each
        s.enqueue(ch, 100);
    }

    var serviced = [_]bool{false} ** 5;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const l = s.pick().?;
        s.service(l, 100);
        serviced[l] = true;
    }
    // every channel that had data is eventually serviced - strict priority does
    // not permanently starve the low-priority lanes.
    for (serviced) |sv| try testing.expect(sv);
}
