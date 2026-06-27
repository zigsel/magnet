//! bench_spatial - scale check for the bucketed spatial-grid interest broadphase.
//! Processes 100k entities at interactive scale (counting-sort rebuild is O(n), three
//! linear passes over contiguous memory; a neighborhood query is O(entities in the
//! (2r+1)² cells), not O(n)). Run optimized: `-Doptimize=ReleaseFast`.

const std = @import("std");
const magnet = @import("magnet");

// Dense 2D broadphase over a bounded 4096×4096 world (256×256 cells of 16 units).
// (Swap `.layout = .sparse` for an unbounded world - memory then ∝ entities, not cells.)
const Grid = magnet.replication.interest.Grid(.{
    .dims = 2,
    .cell = 16,
    .layout = .dense,
    .extent = .{ 256, 256, 0 },
    .max_entities = 100_000,
});

pub fn main() !void {
    const a = std.heap.page_allocator;
    const grid = try a.create(Grid);
    defer a.destroy(grid);
    grid.* = .{};

    const N = 100_000; // entities in a 4096×4096 world (256×256 cells of 16 units)
    const items = try a.alloc(Grid.Item, N);
    defer a.free(items);
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    for (items, 0..) |*it, i| it.* = .{ .id = @intCast(i), .pos = .{ rnd.intRangeAtMost(i32, 0, 4095), rnd.intRangeAtMost(i32, 0, 4095) } };

    // 200 ticks: rebuild the index each tick, then run 1000 neighborhood queries.
    var total_hits: u64 = 0;
    var max_hits: usize = 0;
    var out: [8192]u32 = undefined;
    var tick: usize = 0;
    while (tick < 200) : (tick += 1) {
        grid.rebuild(items); // O(n) counting sort
        var q: usize = 0;
        while (q < 1000) : (q += 1) {
            const x = rnd.intRangeAtMost(i32, 0, 4095);
            const y = rnd.intRangeAtMost(i32, 0, 4095);
            const n = grid.collectNear(.{ x, y }, 2, &out); // O(neighbors), not O(N)
            total_hits += n;
            max_hits = @max(max_hits, n);
        }
    }
    // a radius-2 query over a uniform 100k/65536-cell world touches ~25 cells ≈ 38 hits,
    // never the whole world - that's the whole point of the broadphase.
    std.debug.print(
        "bench_spatial: 200 rebuilds of {d} entities + 200k queries done.\n  avg hits/query = {d}, max = {d} (vs {d} brute-force)\n",
        .{ N, total_hits / 200_000, max_hits, N },
    );
}
