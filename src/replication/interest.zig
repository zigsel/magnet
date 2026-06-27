//! Interest management: which entities replicate to which client. Two schemes,
//! composable per game:
//!   - **rooms** (`Rooms`) - bitsets; an entity is visible to a client iff their room
//!     sets intersect (`popcount(viewer & entity) != 0`). ECS-agnostic, opaque handles.
//!   - **spatial grid / AoI** (`Grid`) - cell-bucketed broadphase, generalized over
//!     `dims` (2D or 3D) and storage `layout`:
//!       · `.dense`  - a bounded `extent` of cells in a flat array (arena worlds);
//!       · `.sparse` - an **unbounded** open-addressed hash of *occupied* cells, so a
//!         huge voxel world costs memory ∝ entities, not world volume.
//!     Both rebuild per tick by **counting sort** (zero-alloc, contiguous passes) so a
//!     neighborhood query touches only the entities in the `(2r+1)^dims` cells around
//!     the viewer (`O(neighbors)`). Same `Dense`/`Sparse` vocabulary as the rollback
//!     backends. Integer cell math, no floats on the interest path.
//! Interest filters the per-client replication set → drives per-client deltas and
//! bounds bandwidth before the priority/budget stage even runs.

const std = @import("std");
const BitSet = @import("core").BitSet;

/// A membership bitset over `n` rooms.
pub fn Rooms(comptime n: usize) type {
    return struct {
        const Self = @This();
        bits: BitSet(n) = .{},
        pub fn join(self: *Self, room: usize) void {
            self.bits.set(room);
        }
        pub fn leave(self: *Self, room: usize) void {
            self.bits.clear(room);
        }
        pub fn in(self: *const Self, room: usize) bool {
            return self.bits.isSet(room);
        }
        /// Visible iff the two room sets share at least one room.
        pub fn visible(viewer: *const Self, entity: *const Self) bool {
            return viewer.bits.intersects(&entity.bits);
        }
    };
}

/// Storage layout for `Grid`: `.dense` = a bounded flat cell array; `.sparse` = an
/// unbounded hash of occupied cells (memory ∝ entities, not world volume).
pub const Layout = enum { dense, sparse };

pub const GridConfig = struct {
    /// World dimensionality (2 or 3).
    dims: usize = 2,
    /// Cell (chunk) size in world units.
    cell: i32,
    layout: Layout = .dense,
    max_entities: usize,
    /// `.dense` only: bounded cell extent per axis (first `dims` used). Coordinates
    /// outside clamp to the edge cells.
    extent: [3]usize = .{ 64, 64, 64 },
    /// `.sparse` only: occupied-cell hash size (power of two); 0 = auto (≈ 2×entities).
    buckets: usize = 0,
    /// World coordinate of cell (0,…)'s corner per axis.
    origin: [3]i32 = .{ 0, 0, 0 },
};

/// Generalized cell-bucketed AoI broadphase. See the module doc.
pub fn Grid(comptime cfg: GridConfig) type {
    if (cfg.cell <= 0) @compileError("Grid: cell must be positive");
    if (cfg.dims < 1 or cfg.dims > 3) @compileError("Grid: dims must be 1..3");
    if (cfg.max_entities == 0) @compileError("Grid: max_entities must be > 0");

    const dims = cfg.dims;
    const cell = cfg.cell;
    const max = cfg.max_entities;
    const Index = if (max <= std.math.maxInt(u32)) u32 else usize;

    const ncells = blk: {
        var p: usize = 1;
        for (0..dims) |d| p *= cfg.extent[d];
        break :blk if (cfg.layout == .dense) p else 1;
    };
    const nbuckets = blk: {
        if (cfg.layout != .sparse) break :blk 1;
        const b = if (cfg.buckets != 0) cfg.buckets else (std.math.ceilPowerOfTwo(usize, @max(2 * max, 16)) catch unreachable);
        if (b & (b - 1) != 0) @compileError("Grid: buckets must be a power of two");
        break :blk b;
    };

    return struct {
        const Self = @This();
        pub const Coord = [dims]i32;
        pub const Item = struct { id: u32, pos: Coord };
        pub const capacity = max;
        pub const dimensions = dims;
        pub const layout = cfg.layout;

        const Slot = struct { key: Coord = undefined, used: bool = false, start: Index = 0, count: Index = 0, cursor: Index = 0 };

        dense: [max]Item = undefined, // entities sorted by cell
        count: usize = 0,
        // dense storage: prefix-sum offsets over a flat cell array
        cell_start: if (cfg.layout == .dense) [ncells + 1]Index else void = if (cfg.layout == .dense) [_]Index{0} ** (ncells + 1) else {},
        cursor: if (cfg.layout == .dense) [ncells]Index else void = undefined,
        // sparse storage: open-addressed hash of occupied cells → contiguous dense range
        table: if (cfg.layout == .sparse) [nbuckets]Slot else void = if (cfg.layout == .sparse) [_]Slot{.{}} ** nbuckets else {},

        // ---- shared cell math ----

        /// The cell coordinate of world position `pos`.
        pub fn cellOf(pos: Coord) Coord {
            var c: Coord = undefined;
            inline for (0..dims) |d| c[d] = @divFloor(pos[d] - cfg.origin[d], cell);
            return c;
        }
        /// Chebyshev: are world points `a` and `b` within `radius` cells of each other?
        pub fn within(a: Coord, b: Coord, radius: i32) bool {
            const ca = cellOf(a);
            const cb = cellOf(b);
            inline for (0..dims) |d| {
                if (@abs(ca[d] - cb[d]) > radius) return false;
            }
            return true;
        }

        // ---- dense flat index ----
        fn denseIndexClamped(coord: Coord) usize {
            var idx: usize = 0;
            inline for (0..dims) |d| {
                const cd: usize = @intCast(std.math.clamp(coord[d], 0, @as(i32, @intCast(cfg.extent[d])) - 1));
                idx = idx * cfg.extent[d] + cd;
            }
            return idx;
        }
        fn denseIndexExact(coord: Coord) usize { // caller guarantees in-range
            var idx: usize = 0;
            inline for (0..dims) |d| idx = idx * cfg.extent[d] + @as(usize, @intCast(coord[d]));
            return idx;
        }

        // ---- sparse open-addressed cell hash ----
        fn hashCell(coord: Coord) usize {
            var h: u64 = 1469598103934665603; // FNV-1a
            inline for (0..dims) |d| h = (h ^ @as(u64, @as(u32, @bitCast(coord[d])))) *% 1099511628211;
            return @intCast(h & (nbuckets - 1));
        }
        fn keyEq(a: Coord, b: Coord) bool {
            inline for (0..dims) |d| if (a[d] != b[d]) return false;
            return true;
        }
        fn findSlot(self: *Self, coord: Coord) ?*Slot {
            var i = hashCell(coord);
            var probes: usize = 0;
            while (probes < nbuckets) : (probes += 1) {
                const s = &self.table[i];
                if (!s.used) return null;
                if (keyEq(s.key, coord)) return s;
                i = (i + 1) & (nbuckets - 1);
            }
            return null;
        }
        fn findOrInsert(self: *Self, coord: Coord) *Slot {
            var i = hashCell(coord);
            while (true) {
                const s = &self.table[i];
                if (!s.used) {
                    s.* = .{ .used = true, .key = coord };
                    return s;
                }
                if (keyEq(s.key, coord)) return s;
                i = (i + 1) & (nbuckets - 1);
            }
        }

        /// Rebuild the index from `items` (counting sort). Call once per tick after the
        /// entities have moved. `items.len` must be ≤ `max_entities`.
        pub fn rebuild(self: *Self, items: []const Item) void {
            std.debug.assert(items.len <= max);
            self.count = items.len;
            if (cfg.layout == .dense) {
                @memset(self.cell_start[0 .. ncells + 1], 0);
                for (items) |it| self.cell_start[denseIndexClamped(cellOf(it.pos)) + 1] += 1;
                var c: usize = 1;
                while (c <= ncells) : (c += 1) self.cell_start[c] += self.cell_start[c - 1];
                @memcpy(self.cursor[0..ncells], self.cell_start[0..ncells]);
                for (items) |it| {
                    const ci = denseIndexClamped(cellOf(it.pos));
                    self.dense[self.cursor[ci]] = it;
                    self.cursor[ci] += 1;
                }
            } else {
                for (&self.table) |*s| s.used = false;
                for (items) |it| self.findOrInsert(cellOf(it.pos)).count += 1;
                var acc: Index = 0;
                for (&self.table) |*s| {
                    if (!s.used) continue;
                    s.start = acc;
                    s.cursor = acc;
                    acc += s.count;
                }
                for (items) |it| {
                    const s = self.findOrInsert(cellOf(it.pos)); // already present
                    self.dense[s.cursor] = it;
                    s.cursor += 1;
                }
            }
        }

        /// Visit every entity within `radius` cells of `center` (Chebyshev), calling
        /// `ctx.visit(Item)`. Only the cells in the neighborhood are scanned.
        pub fn forEachNear(self: *Self, center: Coord, radius: i32, ctx: anytype) void {
            const cc = cellOf(center);
            var lo: Coord = undefined;
            var hi: Coord = undefined;
            inline for (0..dims) |d| {
                lo[d] = cc[d] - radius;
                hi[d] = cc[d] + radius;
                if (cfg.layout == .dense) {
                    const ext = @as(i32, @intCast(cfg.extent[d])) - 1;
                    lo[d] = std.math.clamp(lo[d], 0, ext);
                    hi[d] = std.math.clamp(hi[d], 0, ext);
                }
            }
            var idx = lo;
            while (true) {
                if (cfg.layout == .dense) {
                    const ci = denseIndexExact(idx);
                    var i: usize = self.cell_start[ci];
                    const end: usize = self.cell_start[ci + 1];
                    while (i < end) : (i += 1) ctx.visit(self.dense[i]);
                } else if (self.findSlot(idx)) |s| {
                    var i: usize = s.start;
                    const end: usize = @as(usize, s.start) + s.count;
                    while (i < end) : (i += 1) ctx.visit(self.dense[i]);
                }
                // odometer over the (2r+1)^dims neighborhood
                var d: usize = 0;
                while (true) {
                    idx[d] += 1;
                    if (idx[d] <= hi[d]) break;
                    idx[d] = lo[d];
                    d += 1;
                    if (d == dims) return;
                }
            }
        }

        /// Collect ids within `radius` cells of `center` into `out`; returns the count
        /// (capped at `out.len`).
        pub fn collectNear(self: *Self, center: Coord, radius: i32, out: []u32) usize {
            const Collector = struct {
                out: []u32,
                n: usize = 0,
                fn visit(c: *@This(), it: Item) void {
                    if (c.n < c.out.len) {
                        c.out[c.n] = it.id;
                        c.n += 1;
                    }
                }
            };
            var c = Collector{ .out = out };
            self.forEachNear(center, radius, &c);
            return c.n;
        }
    };
}

const testing = std.testing;

test "rooms: visible iff sets intersect" {
    const R = Rooms(64);
    var client = R{};
    var ent_a = R{};
    var ent_b = R{};
    client.join(3);
    client.join(10);
    ent_a.join(10); // shares room 10
    ent_b.join(20); // disjoint
    try testing.expect(R.visible(&client, &ent_a));
    try testing.expect(!R.visible(&client, &ent_b));
    ent_b.join(3);
    try testing.expect(R.visible(&client, &ent_b)); // now shares room 3
}

test "grid: cell math (cellOf / Chebyshev within)" {
    const G = Grid(.{ .dims = 2, .cell = 32, .max_entities = 16 });
    try testing.expectEqual(@as(i32, 3), G.cellOf(.{ 100, 0 })[0]); // 100/32
    try testing.expect(G.within(.{ 0, 0 }, .{ 31, 31 }, 1)); // adjacent cell
    try testing.expect(G.within(.{ 0, 0 }, .{ 95, 0 }, 3)); // 3 cells on x
    try testing.expect(!G.within(.{ 0, 0 }, .{ 200, 0 }, 3)); // out on x
    try testing.expect(!G.within(.{ 0, 0 }, .{ 0, 200 }, 3)); // out on y
}

test "grid (dense 2D): counting-sort rebuild + O(neighbors) query returns only nearby" {
    const G = Grid(.{ .dims = 2, .cell = 10, .layout = .dense, .extent = .{ 16, 16, 0 }, .max_entities = 1024 });
    var grid = G{};
    var items: [1000]G.Item = undefined;
    var prng = std.Random.DefaultPrng.init(0x5);
    const rnd = prng.random();
    for (&items, 0..) |*it, i| it.* = .{ .id = @intCast(i), .pos = .{ rnd.intRangeAtMost(i32, 0, 159), rnd.intRangeAtMost(i32, 0, 159) } };
    grid.rebuild(&items);
    try testing.expectEqual(@as(usize, 1000), grid.count);

    var out: [1024]u32 = undefined;
    const n = grid.collectNear(.{ 75, 75 }, 1, &out);
    var brute: usize = 0;
    for (items) |it| {
        const cdx = @abs(@divFloor(it.pos[0], 10) - 7);
        const cdy = @abs(@divFloor(it.pos[1], 10) - 7);
        if (cdx <= 1 and cdy <= 1) brute += 1;
    }
    try testing.expectEqual(brute, n);
    try testing.expect(n < 1000); // a query touches a fraction
    for (out[0..n]) |id| {
        const it = items[id];
        try testing.expect(@abs(@divFloor(it.pos[0], 10) - 7) <= 1 and @abs(@divFloor(it.pos[1], 10) - 7) <= 1);
    }
}

test "grid (dense 2D): out-of-bounds clamps to the edge cells" {
    const G = Grid(.{ .dims = 2, .cell = 10, .layout = .dense, .extent = .{ 8, 8, 0 }, .max_entities = 16 });
    var grid = G{};
    const items = [_]G.Item{
        .{ .id = 0, .pos = .{ 5, 5 } }, // cell (0,0)
        .{ .id = 1, .pos = .{ -100, -100 } }, // clamps to edge (0,0)
        .{ .id = 2, .pos = .{ 9999, 9999 } }, // clamps to edge (7,7)
    };
    grid.rebuild(&items);
    var out: [16]u32 = undefined;
    try testing.expectEqual(@as(usize, 2), grid.collectNear(.{ 5, 5 }, 0, &out)); // ids 0,1
    try testing.expectEqual(@as(usize, 1), grid.collectNear(.{ 75, 75 }, 0, &out)); // id 2
    try testing.expectEqual(@as(u32, 2), out[0]);
}

test "grid (sparse 3D): unbounded voxel world, O(neighbors) query == brute force" {
    // a huge 3D world (coords span millions) - a dense grid here would need an
    // astronomically large cell array; the sparse hash costs memory ∝ entities.
    const G = Grid(.{ .dims = 3, .cell = 16, .layout = .sparse, .max_entities = 4096 });
    var grid = G{};
    var items: [3000]G.Item = undefined;
    var prng = std.Random.DefaultPrng.init(0xB0BB1E);
    const rnd = prng.random();
    for (&items, 0..) |*it, i| it.* = .{ .id = @intCast(i), .pos = .{
        rnd.intRangeAtMost(i32, -2_000_000, 2_000_000),
        rnd.intRangeAtMost(i32, -2_000_000, 2_000_000),
        rnd.intRangeAtMost(i32, -2_000_000, 2_000_000),
    } };
    grid.rebuild(&items);
    try testing.expectEqual(@as(usize, 3000), grid.count);

    const center: G.Coord = .{ 12345, -67890, 54321 };
    var out: [4096]u32 = undefined;
    const n = grid.collectNear(center, 2, &out);
    // brute force the same Chebyshev-2 cell neighborhood
    const cc = G.cellOf(center);
    var brute: usize = 0;
    for (items) |it| {
        const ic = G.cellOf(it.pos);
        if (@abs(ic[0] - cc[0]) <= 2 and @abs(ic[1] - cc[1]) <= 2 and @abs(ic[2] - cc[2]) <= 2) brute += 1;
    }
    try testing.expectEqual(brute, n);
    for (out[0..n]) |id| try testing.expect(G.within(center, items[id].pos, 2));
}

test "grid: dense and sparse layouts return identical neighborhoods (differential)" {
    const Dense = Grid(.{ .dims = 2, .cell = 10, .layout = .dense, .extent = .{ 32, 32, 0 }, .max_entities = 2048 });
    const Sparse = Grid(.{ .dims = 2, .cell = 10, .layout = .sparse, .max_entities = 2048 });
    var dg = Dense{};
    var sg = Sparse{};

    var di: [1500]Dense.Item = undefined;
    var si: [1500]Sparse.Item = undefined;
    var prng = std.Random.DefaultPrng.init(0xD1FF);
    const rnd = prng.random();
    for (&di, &si, 0..) |*d, *s, i| {
        const p = [2]i32{ rnd.intRangeAtMost(i32, 0, 319), rnd.intRangeAtMost(i32, 0, 319) };
        d.* = .{ .id = @intCast(i), .pos = p };
        s.* = .{ .id = @intCast(i), .pos = p };
    }
    dg.rebuild(&di);
    sg.rebuild(&si);

    var od: [2048]u32 = undefined;
    var os: [2048]u32 = undefined;
    var q: usize = 0;
    while (q < 50) : (q += 1) {
        const center = [2]i32{ rnd.intRangeAtMost(i32, 0, 319), rnd.intRangeAtMost(i32, 0, 319) };
        const nd = dg.collectNear(center, 1, &od);
        const ns = sg.collectNear(center, 1, &os);
        try testing.expectEqual(nd, ns); // same count
        std.mem.sort(u32, od[0..nd], {}, std.sort.asc(u32));
        std.mem.sort(u32, os[0..ns], {}, std.sort.asc(u32));
        try testing.expectEqualSlices(u32, od[0..nd], os[0..ns]); // identical id sets
    }
}
