//! Client-side prediction + reconciliation around the **single `step` function**
//! The user writes one deterministic fixed-step sim `step(state, input) ->
//! state`; magnet runs it in three contexts the user never wires by hand:
//!   1. predict - advance owned entities from local input every tick (zero-latency).
//!   2. (server authoritative - same `step` over buffered inputs).
//!   3. reconcile - on a misprediction, restore to the authoritative state at tick T
//!      and **replay `step`** forward over the buffered input history to "now".
//! Because the same `step` runs in all three, the netcode is consistent by
//! construction. `step` is a comptime parameter, so it inlines (no indirect call).

const std = @import("std");
const History = @import("history.zig").History;
const MismatchMask = @import("history.zig").MismatchMask;

pub fn Predictor(
    comptime St: type,
    comptime In: type,
    comptime stepFn: fn (St, In) St,
    comptime cap: usize,
) type {
    return struct {
        const Self = @This();
        const InputSlot = struct { tick: u32 = 0, used: bool = false, in: In = undefined };

        states: History(St, cap) = .{}, // predicted state per tick
        inputs: [cap]InputSlot = [_]InputSlot{.{}} ** cap, // input per tick (dense ring)
        tick: u32 = 0,
        present: St = undefined, // latest predicted ("now") state
        mismatch: MismatchMask = .{},
        rollbacks: u32 = 0,

        pub fn init(self: *Self, initial: St) void {
            self.* = .{};
            self.present = initial;
            self.states.record(0, initial);
        }

        fn putInput(self: *Self, t: u32, in: In) void {
            self.inputs[t % cap] = .{ .tick = t, .used = true, .in = in };
        }
        fn getInput(self: *const Self, t: u32) In {
            const s = self.inputs[t % cap];
            return if (s.used and s.tick == t) s.in else std.mem.zeroes(In);
        }

        /// Advance one tick from local input, immediately (no waiting on the server).
        /// Returns the new present state - this is what makes prediction responsive.
        pub fn predict(self: *Self, in: In) St {
            self.tick += 1;
            self.putInput(self.tick, in);
            self.present = stepFn(self.present, in);
            self.states.record(self.tick, self.present);
            return self.present;
        }

        /// An authoritative state for `auth_tick` arrived. If it matches what we
        /// predicted, nothing happens. Otherwise restore to it and **replay** `step`
        /// over the buffered inputs up to the current tick. Returns true if rolled back.
        pub fn reconcile(self: *Self, auth_tick: u32, auth: St) bool {
            if (auth_tick > self.tick) return false; // future; can't compare yet
            const predicted = self.states.get(auth_tick) orelse return false;
            if (std.meta.eql(predicted, auth)) return false; // correct prediction
            self.mismatch.mark(auth_tick);
            self.rollbacks += 1;

            var s = auth;
            self.states.record(auth_tick, s);
            var t = auth_tick + 1;
            while (t <= self.tick) : (t += 1) {
                s = stepFn(s, self.getInput(t));
                self.states.record(t, s);
            }
            self.present = s;
            return true;
        }

        /// Drop history strictly older than `tick` (e.g. the last fully-acked tick).
        pub fn trim(self: *Self, tick: u32) void {
            self.states.popUntil(tick);
        }
    };
}

// ---- a deterministic point-mass sim used by the tests ----

const State = struct { pos: i32, vel: i32 };
const Input = struct { accel: i8 };
fn step(s: State, in: Input) State {
    return .{ .pos = s.pos + s.vel, .vel = s.vel + in.accel };
}
const TestPredictor = Predictor(State, Input, step, 128);

const testing = std.testing;

test "prediction advances immediately every tick (responsive)" {
    var p: TestPredictor = undefined;
    p.init(.{ .pos = 0, .vel = 0 });
    var t: u32 = 0;
    while (t < 10) : (t += 1) {
        _ = p.predict(.{ .accel = 1 });
        try testing.expectEqual(t + 1, p.tick); // never lags behind input
    }
    // pos = sum of vel; vel grows by 1 each tick → pos = 0+1+2+...+9 = 45
    try testing.expectEqual(@as(i32, 45), p.present.pos);
    try testing.expectEqual(@as(i32, 10), p.present.vel);
}

test "matching authoritative state causes no rollback" {
    var p: TestPredictor = undefined;
    p.init(.{ .pos = 0, .vel = 0 });
    var t: u32 = 0;
    while (t < 5) : (t += 1) _ = p.predict(.{ .accel = 2 });
    // recompute the true state at tick 3 (same step, same inputs)
    var s = State{ .pos = 0, .vel = 0 };
    var k: u32 = 0;
    while (k < 3) : (k += 1) s = step(s, .{ .accel = 2 });
    try testing.expect(!p.reconcile(3, s)); // prediction was correct
    try testing.expectEqual(@as(u32, 0), p.rollbacks);
}

test "misprediction reconciles and replay == eventual authoritative state" {
    const latency: u32 = 6;
    const impulse_tick: u32 = 20;

    var client: TestPredictor = undefined;
    client.init(.{ .pos = 0, .vel = 0 });

    var server = State{ .pos = 0, .vel = 0 };
    var server_tick: u32 = 0;
    // pending authoritative snapshots: {deliver_at_tick, snap_tick, state}
    var pending: [256]struct { at: u32, tick: u32, st: State } = undefined;
    var np: usize = 0;

    var t: u32 = 1;
    while (t <= 60) : (t += 1) {
        const in = Input{ .accel = 1 };
        // client predicts locally (no knowledge of the server impulse)
        _ = client.predict(in);
        // server advances authoritatively; a one-time external impulse at impulse_tick
        server = step(server, in);
        if (t == impulse_tick) server.vel += 50; // the divergence the client can't predict
        server_tick = t;
        pending[np] = .{ .at = t + latency, .tick = t, .st = server }; // snapshot, delivered late
        np += 1;
        // deliver any snapshots whose time has come → reconcile
        for (pending[0..np]) |snap| {
            if (snap.at == t) _ = client.reconcile(snap.tick, snap.st);
        }
    }
    // drain the last in-flight snapshots so the client catches up to the server tick
    for (pending[0..np]) |snap| {
        if (snap.at > 60) _ = client.reconcile(snap.tick, snap.st);
    }

    try testing.expect(client.rollbacks > 0); // the impulse was a real misprediction
    try testing.expectEqual(server_tick, client.tick); // client stayed at "now"
    // after replay, the client's present state equals the authoritative state at the
    // same tick (the impulse, once learned, is carried forward by re-running `step`).
    try testing.expectEqual(server.pos, client.present.pos);
    try testing.expectEqual(server.vel, client.present.vel);
}

const Smoother = @import("correction.zig").Smoother;

test "reconciliation correction is bounded and smooths to zero (no visual snap)" {
    const latency: u32 = 5;
    var client: TestPredictor = undefined;
    client.init(.{ .pos = 0, .vel = 0 });
    var server = State{ .pos = 0, .vel = 0 };
    var smoother = Smoother(.smooth){};

    var pending: [256]struct { at: u32, tick: u32, st: State } = undefined;
    var np: usize = 0;
    var max_err: f32 = 0;
    var t: u32 = 1;
    while (t <= 80) : (t += 1) {
        const in = Input{ .accel = 1 };
        _ = client.predict(in);
        server = step(server, in);
        if (t == 15) server.vel += 40; // unpredicted divergence
        pending[np] = .{ .at = t + latency, .tick = t, .st = server };
        np += 1;
        for (pending[0..np]) |snap| {
            if (snap.at == t) {
                const before = client.present.pos;
                if (client.reconcile(snap.tick, snap.st)) {
                    const delta: f32 = @floatFromInt(client.present.pos - before);
                    smoother.onCorrection(delta); // carry the jump into the visual offset
                }
            }
        }
        const e = @abs(smoother.advance(16));
        max_err = @max(max_err, e);
    }

    try testing.expect(client.rollbacks > 0);
    try testing.expect(max_err > 0); // a correction was actually carried
    try testing.expect(max_err < 5000); // …but bounded (never an unbounded blow-up)
    try testing.expect(@abs(smoother.err) < 1.0); // …and decayed to ~zero by the end
}
