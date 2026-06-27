//! Lag compensation. The server keeps a short ring of world snapshots
//! (hitbox positions per tick). The client ships its `interpolation_delay` (and the
//! input tick) with each input, so when the server processes a shot it knows exactly
//! *which past world the shooter saw* and rewinds the others to that view-time before
//! the hit test - "favor the shooter". Here the rewind is read-only: the raycast
//! runs against the stored snapshot, so no live state is mutated and no restore is
//! needed. Geometry is render/hit-side float (single authority → no cross-machine
//! determinism requirement, unlike the CC/sim path).

const std = @import("std");

pub fn LagComp(comptime max: usize, comptime history: usize) type {
    return struct {
        const Self = @This();
        pub const Box = struct { present: bool = false, x: f32 = 0, y: f32 = 0, r: f32 = 0 };
        const Frame = struct { tick: u32 = 0, used: bool = false, boxes: [max]Box = [_]Box{.{}} ** max };
        pub const Hit = struct { entity: usize, dist: f32 };

        frames: [history]Frame = [_]Frame{.{}} ** history,

        /// Begin recording the snapshot for `tick`; returns the box array to fill
        /// (one per entity id) for this server tick.
        pub fn beginFrame(self: *Self, tick: u32) *[max]Box {
            const f = &self.frames[tick % history];
            f.tick = tick;
            f.used = true;
            f.boxes = [_]Box{.{}} ** max;
            return &f.boxes;
        }

        fn frameAt(self: *Self, view_tick: u32) ?*const Frame {
            const f = &self.frames[view_tick % history];
            return if (f.used and f.tick == view_tick) f else null;
        }

        /// Rewind the world to `view_tick` (the shooter's view-time) and raycast a
        /// unit-direction ray from `(ox,oy)` for `max_len`, ignoring `shooter`.
        /// Returns the nearest hit entity, or null.
        pub fn rewindRaycast(self: *Self, view_tick: u32, shooter: usize, ox: f32, oy: f32, dx: f32, dy: f32, max_len: f32) ?Hit {
            const f = self.frameAt(view_tick) orelse return null;
            var best: ?Hit = null;
            for (f.boxes, 0..) |b, i| {
                if (!b.present or i == shooter) continue;
                if (rayCircle(ox, oy, dx, dy, max_len, b.x, b.y, b.r)) |t| {
                    if (best == null or t < best.?.dist) best = .{ .entity = i, .dist = t };
                }
            }
            return best;
        }
    };
}

/// Ray (unit `D`) vs circle: nearest `t ∈ [0, len]` where the ray meets the circle, or null.
fn rayCircle(ox: f32, oy: f32, dx: f32, dy: f32, len: f32, cx: f32, cy: f32, r: f32) ?f32 {
    const mx = cx - ox;
    const my = cy - oy;
    const tca = mx * dx + my * dy; // projection of center onto the ray
    const d2 = (mx * mx + my * my) - tca * tca; // squared distance from center to the ray line
    const r2 = r * r;
    if (d2 > r2) return null;
    const thc = @sqrt(r2 - d2);
    var t = tca - thc;
    if (t < 0) t = tca + thc; // origin inside the circle → far intersection
    if (t < 0 or t > len) return null;
    return t;
}

const testing = std.testing;
const TestLagComp = LagComp(8, 32);

test "favor the shooter: hit at the rewound view-time, miss at the current time" {
    var lc = TestLagComp{};
    // record 21 ticks; target (id 1) slides along +x at 10 units/tick, radius 5.
    var tick: u32 = 0;
    while (tick <= 20) : (tick += 1) {
        const boxes = lc.beginFrame(tick);
        boxes[0] = .{ .present = true, .x = 0, .y = -50, .r = 5 }; // shooter parked
        boxes[1] = .{ .present = true, .x = @floatFromInt(tick * 10), .y = 0, .r = 5 };
    }

    // shooter at (100,-50) fires straight up (+y). At view tick 10 the target was at x=100.
    const now: u32 = 20;
    const interp_delay: u32 = 10; // shipped by the client
    const view_tick = now - interp_delay; // = 10

    const hit = lc.rewindRaycast(view_tick, 0, 100, -50, 0, 1, 100);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(usize, 1), hit.?.entity); // hits the target where the shooter saw it

    // the SAME shot tested against the *current* world (target now at x=200) misses.
    const miss = lc.rewindRaycast(now, 0, 100, -50, 0, 1, 100);
    try testing.expect(miss == null);
}

test "raycast ignores the shooter and respects range" {
    var lc = TestLagComp{};
    const boxes = lc.beginFrame(0);
    boxes[0] = .{ .present = true, .x = 0, .y = 0, .r = 5 }; // shooter at origin
    boxes[1] = .{ .present = true, .x = 0, .y = 1000, .r = 5 }; // far target
    // short range: nothing in reach (shooter is ignored)
    try testing.expect(lc.rewindRaycast(0, 0, 0, 0, 0, 1, 100) == null);
    // long range: reaches the target
    try testing.expectEqual(@as(usize, 1), lc.rewindRaycast(0, 0, 0, 0, 0, 1, 2000).?.entity);
}
