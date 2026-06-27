//! mmo_interest - you don't replicate the whole world to every client. The spatial grid
//! buckets entities by cell and answers "who's near this viewer?" in time proportional
//! to the neighbours, not the world size - so a client only receives what it can see.

const std = @import("std");
const magnet = @import("magnet");
const Grid = magnet.replication.interest.Grid;

// a 2-D area-of-interest grid: 8-unit cells, sparse storage (memory ∝ entities).
const World = Grid(.{ .dims = 2, .cell = 8, .layout = .sparse, .max_entities = 4096 });

pub fn main() void {
    var grid = World{};

    var items: [2000]World.Item = undefined; // 2000 entities scattered over a large map
    var rng = std.Random.DefaultPrng.init(0x5);
    for (&items, 0..) |*it, i| it.* = .{
        .id = @intCast(i),
        .pos = .{ rng.random().intRangeAtMost(i32, -500, 500), rng.random().intRangeAtMost(i32, -500, 500) },
    };
    grid.rebuild(&items); // once per tick, O(n) counting sort

    // a client standing at the origin sees only entities within ~2 cells.
    var nearby: [256]u32 = undefined;
    const viewer = .{ 0, 0 };
    const visible = grid.collectNear(viewer, 2, &nearby);

    std.debug.print("mmo_interest: {d} entities in the world, {d} within the viewer's interest\n", .{ items.len, visible });
    std.debug.print("  only those {d} would be replicated - the other {d} cost the client nothing\n", .{
        visible, items.len - visible,
    });
}
