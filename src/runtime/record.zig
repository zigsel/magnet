//! Record / replay capture sink. Every datagram crossing the wire is appended as a
//! length-prefixed frame `[now:i64][dir:u8][addr:u64][len:u16][bytes]` into a
//! caller-owned buffer (zero-alloc; overflow is counted, never a crash). Replay
//! walks the log and re-feeds it, so a captured lossy session can be debugged
//! offline and "identical transmit intents" can be asserted across runs - the
//! determinism guarantee the sans-IO core (time in → transmit intents out) provides.

const std = @import("std");

pub const Dir = enum(u8) { outbound = 0, inbound = 1 };

pub const Recorder = struct {
    buf: []u8,
    pos: usize = 0,
    dropped: u64 = 0,

    pub fn init(buf: []u8) Recorder {
        return .{ .buf = buf };
    }

    pub fn record(self: *Recorder, now: i64, dir: Dir, addr: u64, bytes: []const u8) void {
        const need = 8 + 1 + 8 + 2 + bytes.len;
        if (self.pos + need > self.buf.len) {
            self.dropped += 1;
            return;
        }
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], now, .little);
        self.buf[self.pos + 8] = @intFromEnum(dir);
        std.mem.writeInt(u64, self.buf[self.pos + 9 ..][0..8], addr, .little);
        std.mem.writeInt(u16, self.buf[self.pos + 17 ..][0..2], @intCast(bytes.len), .little);
        @memcpy(self.buf[self.pos + 19 ..][0..bytes.len], bytes);
        self.pos += need;
    }

    pub fn frames(self: *const Recorder) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub const Frame = struct { now: i64, dir: Dir, addr: u64, bytes: []const u8 };

pub const Replayer = struct {
    log: []const u8,
    pos: usize = 0,

    pub fn init(log: []const u8) Replayer {
        return .{ .log = log };
    }

    pub fn next(self: *Replayer) ?Frame {
        if (self.pos + 19 > self.log.len) return null;
        const now = std.mem.readInt(i64, self.log[self.pos..][0..8], .little);
        const dir: Dir = @enumFromInt(self.log[self.pos + 8]);
        const addr = std.mem.readInt(u64, self.log[self.pos + 9 ..][0..8], .little);
        const len = std.mem.readInt(u16, self.log[self.pos + 17 ..][0..2], .little);
        const start = self.pos + 19;
        if (start + len > self.log.len) return null;
        self.pos = start + len;
        return .{ .now = now, .dir = dir, .addr = addr, .bytes = self.log[start .. start + len] };
    }
};

const testing = std.testing;
const sim = @import("sim.zig");
const poll = @import("poll.zig");
const Config = @import("config").Config;
const Endpoint = @import("proto").endpoint.Endpoint;
const channels = @import("proto").schema.channels;
const session = @import("proto").session;

const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
const Cfg = Config{ .channels = Schema, .limits = .{ .max_connections = 4, .channel_cap = 128, .max_payload = 64, .bridge_cap = 1024, .recvpn_cap = 256 } };
const TestEndpoint = Endpoint(Cfg);

const cli: u64 = 1;
const srv: u64 = 2;

// Run the reliable scenario, capturing every datagram into `rec`; return delivered.
fn captureRun(alloc: std.mem.Allocator, seed: u64, rec: *Recorder) !usize {
    const link = try alloc.create(sim.DefaultLink);
    defer alloc.destroy(link);
    link.* = .{ .params = .{ .latency_ms = 40, .jitter_ms = 20, .loss_permille = 200, .seed = seed }, .prng = std.Random.DefaultPrng.init(seed) };
    const client = try alloc.create(TestEndpoint);
    defer alloc.destroy(client);
    client.* = .{};
    const server = try alloc.create(TestEndpoint);
    defer alloc.destroy(server);
    server.* = .{};

    var ctx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_a, .send_dir = .to_b, .peer_addr = srv };
    var stx: sim.Transport(sim.DefaultLink) = .{ .link = link, .recv_dir = .to_b, .send_dir = .to_a, .peer_addr = cli };

    const N: u32 = 50;
    var scratch: [session.mtu]u8 = undefined;
    var out: [64]u8 = undefined;
    var queued: u32 = 0;
    var delivered: usize = 0;
    var now: i64 = 0;
    var step: usize = 0;
    while (step < 4000 and delivered < N) : (step += 1) {
        while (queued < N) : (queued += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, queued, .little);
            client.sendRawTo(srv, .rel, &b) catch break;
        }
        // capture client→server transmit intents
        while (client.pollTransmit(&scratch, now)) |d| {
            rec.record(now, .outbound, d.addr, scratch[0..d.len]);
            stx.link.send(.to_b, scratch[0..d.len], now);
        }
        poll.recvAll(server, &stx, &scratch, now);
        poll.flushAll(server, &stx, &scratch, now);
        poll.recvAll(client, &ctx, &scratch, now);
        while (server.receiveRawFrom(cli, .rel, &out)) |_| delivered += 1;
        now += 5;
    }
    return delivered;
}

test "capture: a seeded session records identical transmit intents across runs (determinism)" {
    const alloc = testing.allocator;
    var b1: [16384]u8 = undefined;
    var b2: [16384]u8 = undefined;
    var r1 = Recorder.init(&b1);
    var r2 = Recorder.init(&b2);
    const d1 = try captureRun(alloc, 0xDEC0DE, &r1);
    const d2 = try captureRun(alloc, 0xDEC0DE, &r2);
    try testing.expectEqual(d1, d2);
    try testing.expectEqual(@as(u64, 0), r1.dropped);
    try testing.expectEqualSlices(u8, r1.frames(), r2.frames()); // byte-identical capture
}

test "replay: captured client→server datagrams re-feed a fresh server to the same delivery" {
    const alloc = testing.allocator;
    var b1: [16384]u8 = undefined;
    var rec = Recorder.init(&b1);
    const delivered = try captureRun(alloc, 0x1234, &rec);

    // replay the captured outbound (client→server) frames into a brand-new server.
    const server = try alloc.create(TestEndpoint);
    defer alloc.destroy(server);
    server.* = .{};
    var rp = Replayer.init(rec.frames());
    var replayed: usize = 0;
    var out: [64]u8 = undefined;
    while (rp.next()) |f| {
        server.feedFrom(cli, f.bytes, f.now);
        while (server.receiveRawFrom(cli, .rel, &out)) |_| replayed += 1;
    }
    try testing.expectEqual(delivered, replayed); // replay reproduces the delivery
}
