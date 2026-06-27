//! bench_throughput - Stage 17 perf pass. Reports serialization ns/message, the
//! in-process reliable-session message rate (protocol CPU, no sockets), and the
//! comptime-known per-connection memory. Run optimized: `-Doptimize=ReleaseFast`.

const std = @import("std");
const magnet = @import("magnet");

const Msg = struct { id: u32, x: i16, y: i16, vx: i8, vy: i8, flags: u8 };
const Schema = magnet.proto.channels(.{ .data = .{ .mode = .reliable_ordered, .Message = Msg } });
const Cfg = magnet.Config{ .channels = Schema, .limits = .{
    .channel_cap = 256,
    .max_payload = 64,
    .bridge_cap = 2048,
    .recvpn_cap = 512,
} };
const Session = magnet.proto.Session(Cfg);

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .boot).nanoseconds; // monotonic, ns granularity
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sample = Msg{ .id = 42, .x = -1, .y = 2, .vx = 3, .vy = -4, .flags = 0xA5 };
    var serde_ns: u64 = 0;
    var msg_per_sec: u64 = 0;

    // 1. serialization: encode + decode, ns/message.
    {
        var buf: [64]u8 = undefined;
        const N: usize = 4_000_000;
        var sink: u64 = 0;
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            var w = magnet.wire.bitpack.Writer.init(&buf);
            magnet.wire.serde.write(&w, sample);
            var r = magnet.wire.bitpack.Reader.init(w.finish());
            sink +%= magnet.wire.serde.read(Msg, &r).?.id;
        }
        const ns: u64 = @intCast(@divTrunc(nowNs(io) - t0, N));
        serde_ns = ns;
        std.mem.doNotOptimizeAway(sink);
        std.debug.print("serde:   {d} ns/message (encode+decode) - wire {d}B vs sizeof {d}B\n", .{
            ns, magnet.wire.serde.measureBytes(sample), @sizeOf(Msg),
        });
    }

    // 2. reliable session message rate (in-process, lossless - pure protocol CPU).
    {
        const alloc = std.heap.page_allocator;
        const a = try alloc.create(Session);
        defer alloc.destroy(a);
        a.* = .{};
        a.setup();
        const b = try alloc.create(Session);
        defer alloc.destroy(b);
        b.* = .{};
        b.setup();

        var scratch: [1500]u8 = undefined;
        const M: u32 = 2_000_000;
        var sent: u32 = 0;
        var recv: u32 = 0;
        var now: i64 = 0;
        const t0 = nowNs(io);
        while (recv < M) {
            while (sent < M) : (sent += 1) {
                a.send(.data, sample) catch break; // backpressure → drain, retry next round
            }
            while (a.pollTransmit(&scratch, now)) |len| b.feed(scratch[0..len], now);
            while (b.receive(.data)) |_| recv += 1;
            while (b.pollTransmit(&scratch, now)) |len| a.feed(scratch[0..len], now); // acks
            now += 1;
        }
        const elapsed: u64 = @intCast(nowNs(io) - t0);
        const per_sec = @as(u64, M) * std.time.ns_per_s / elapsed;
        msg_per_sec = per_sec;
        std.debug.print("session: {d} reliable msgs/sec in-process ({d} ms for {d} msgs)\n", .{
            per_sec, elapsed / std.time.ns_per_ms, M,
        });
    }

    // 3. per-connection memory (comptime-known, bounded - the zero-alloc audit).
    std.debug.print("memory:  {d} KiB per connection (Session), {d} KiB per Endpoint\n", .{
        @sizeOf(Session) / 1024,
        @sizeOf(magnet.Endpoint(Cfg)) / 1024,
    });

    // Soft regression gates - VERY loose (≈40–60× current headroom), so only a
    // catastrophic regression fails `zig build bench`; normal machine variance can't.
    if (serde_ns > 2_000) {
        std.debug.print("PERF REGRESSION: serde {d} ns/msg > 2000\n", .{serde_ns});
        return error.PerfRegression;
    }
    if (msg_per_sec < 50_000) {
        std.debug.print("PERF REGRESSION: {d} msgs/sec < 50000\n", .{msg_per_sec});
        return error.PerfRegression;
    }
    if (@sizeOf(Session) > 4 * 1024 * 1024) {
        std.debug.print("PERF REGRESSION: Session {d} bytes > 4 MiB\n", .{@sizeOf(Session)});
        return error.PerfRegression;
    }
}
