//! **Pool** driver: a work-stealing pool for CPU-heavy fan-out (serialization,
//! snapshot diffing) across cores. Two pieces:
//!   - **connection pinning** (`pin`): a connection is always handled by the same
//!     worker, so its sans-IO state stays single-owner and lock-free - only the
//!     *work distribution* is parallel, never a single connection's hot path.
//!   - **`parallelFor`**: run a disjoint-index job across N workers. Each worker
//!     owns a contiguous stripe, so there is no shared mutable state between them.
//!
//! Under a real `std.Io` this dispatch is `io.asyncConcurrent`; here it uses
//! `std.Thread` directly so the fan-out is genuinely parallel and testable.

const std = @import("std");

/// Deterministically pin `conn_id` to one of `workers` (same connection → same
/// worker forever). Mixed so sequential ids spread across workers.
pub fn pin(conn_id: u64, workers: usize) usize {
    var h = conn_id *% 0x9E37_79B9_7F4A_7C15;
    h ^= h >> 29;
    return @intCast(h % workers);
}

pub const Stripe = struct { start: usize, end: usize };

/// Contiguous partition of `[0, len)` for `worker` of `workers` (disjoint, covers all).
pub fn stripe(len: usize, worker: usize, workers: usize) Stripe {
    const base = len / workers;
    const rem = len % workers;
    const start = worker * base + @min(worker, rem);
    const extra: usize = if (worker < rem) 1 else 0;
    return .{ .start = start, .end = start + base + extra };
}

/// Run `job(ctx, i)` for every `i` in `[0, len)`, fanned out across `workers`
/// threads (each owning a disjoint stripe). `job` must only touch index `i`'s slot.
pub fn parallelFor(
    comptime Ctx: type,
    len: usize,
    workers: usize,
    ctx: Ctx,
    comptime job: fn (Ctx, usize) void,
) void {
    const w = @max(1, @min(workers, len));
    if (w == 1) {
        var i: usize = 0;
        while (i < len) : (i += 1) job(ctx, i);
        return;
    }
    const Runner = struct {
        fn run(c: Ctx, s: Stripe) void {
            var i = s.start;
            while (i < s.end) : (i += 1) job(c, i);
        }
    };
    var threads: [64]?std.Thread = [_]?std.Thread{null} ** 64;
    // workers 1..w-1 on spawned threads; worker 0 on this thread.
    var k: usize = 1;
    while (k < w and k < 64) : (k += 1) {
        threads[k] = std.Thread.spawn(.{}, Runner.run, .{ ctx, stripe(len, k, w) }) catch null;
    }
    Runner.run(ctx, stripe(len, 0, w));
    for (threads[1..w]) |t| {
        if (t) |th| th.join();
    }
    // any worker whose spawn failed runs inline (correctness over parallelism).
    k = 1;
    while (k < w and k < 64) : (k += 1) {
        if (threads[k] == null) Runner.run(ctx, stripe(len, k, w));
    }
}

const testing = std.testing;

test "pin is stable and spreads ids across workers" {
    try testing.expectEqual(pin(42, 4), pin(42, 4)); // stable
    var hits = [_]usize{0} ** 4;
    var id: u64 = 0;
    while (id < 4000) : (id += 1) hits[pin(id, 4)] += 1;
    for (hits) |h| try testing.expect(h > 700); // each worker gets a fair share
}

test "stripe partitions disjointly and covers everything" {
    const len: usize = 100;
    const w: usize = 7;
    var covered = [_]bool{false} ** 100;
    var prev_end: usize = 0;
    var k: usize = 0;
    while (k < w) : (k += 1) {
        const s = stripe(len, k, w);
        try testing.expectEqual(prev_end, s.start); // contiguous
        for (s.start..s.end) |i| {
            try testing.expect(!covered[i]); // disjoint
            covered[i] = true;
        }
        prev_end = s.end;
    }
    try testing.expectEqual(len, prev_end);
    for (covered) |c| try testing.expect(c); // complete
}

const SquareCtx = struct { in: []const u64, out: []u64 };
fn squareJob(ctx: SquareCtx, i: usize) void {
    ctx.out[i] = ctx.in[i] * ctx.in[i];
}

test "parallelFor computes a disjoint fan-out across workers" {
    const n = 10_000;
    var in: [n]u64 = undefined;
    var out: [n]u64 = undefined;
    for (&in, 0..) |*v, i| v.* = i;
    parallelFor(SquareCtx, n, 8, .{ .in = &in, .out = &out }, squareJob);
    for (out, 0..) |v, i| try testing.expectEqual(@as(u64, @intCast(i * i)), v);
}
