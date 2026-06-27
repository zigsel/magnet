//! fps - the shooter recipe. The client predicts its own avatar immediately (no input
//! lag), then reconciles against the late authoritative state by rolling back and
//! replaying. The server keeps a hitbox history so shots are tested against the world
//! the shooter actually saw ("favor the shooter").

const std = @import("std");
const magnet = @import("magnet");

const State = struct { x: i32, vx: i32 };
const Input = struct { thrust: i8 };
fn step(s: State, in: Input) State {
    return .{ .x = s.x + s.vx, .vx = s.vx + in.thrust };
}

const Predictor = magnet.replication.Predictor(State, Input, step, 128);
const LagComp = magnet.replication.LagComp(8, 64);

pub fn main() void {
    const latency: u32 = 6;
    var client: Predictor = undefined;
    client.init(.{ .x = 0, .vx = 0 });
    var server = State{ .x = 0, .vx = 0 };
    var lag = LagComp{};

    var inflight: [128]struct { arrive: u32, tick: u32, state: State } = undefined;
    var n: usize = 0;

    var t: u32 = 1;
    while (t <= 60) : (t += 1) {
        _ = client.predict(.{ .thrust = 1 }); // responsive: the avatar moves now
        server = step(server, .{ .thrust = 1 });
        if (t == 25) server.vx += 30; // a server-only event the client couldn't predict

        inflight[n] = .{ .arrive = t + latency, .tick = t, .state = server };
        n += 1;

        const boxes = lag.beginFrame(t); // record where a target is each tick
        boxes[1] = .{ .present = true, .x = @floatFromInt(t * 10), .y = 0, .r = 5 };

        for (inflight[0..n]) |snap| {
            if (snap.arrive == t) _ = client.reconcile(snap.tick, snap.state);
        }
    }
    for (inflight[0..n]) |snap| if (snap.arrive > 60) {
        _ = client.reconcile(snap.tick, snap.state);
    };

    // a shot aimed where the target was `latency` ticks ago hits; the same shot tested
    // against the current world misses (the target has since moved on).
    const view = 60 - latency;
    const hit = lag.rewindRaycast(view, 0, @floatFromInt(view * 10), -50, 0, 1, 100);
    const miss = lag.rewindRaycast(60, 0, @floatFromInt(view * 10), -50, 0, 1, 100);

    std.debug.print("fps: {d} rollbacks; avatar ({d},{d}) == authoritative ({d},{d})\n", .{
        client.rollbacks, client.present.x, client.present.vx, server.x, server.vx,
    });
    std.debug.print("  lag-comp: hit at the shooter's view = {}, miss at 'now' = {}\n", .{ hit != null, miss == null });
}
