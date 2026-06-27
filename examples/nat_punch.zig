//! nat_punch - two peers behind NATs, with no direct route, find each other. Each
//! gathers candidate addresses (its private "host" and its public "srflx"), they swap
//! candidate lists over signaling, then probe every pair simultaneously. The probes that
//! get through win, and both peers nominate the working public path.

const std = @import("std");
const magnet = @import("magnet");
const ice = magnet.proto.conn.ice;

// a NAT model: a datagram only arrives if it's aimed at a *public* mapping; the receiver
// sees the sender's public address (private "host" addresses can't be reached).
const a_pub: u64 = 0xA;
const b_pub: u64 = 0xB;
var net = Net{};
const Net = struct {
    a_in: [16]Msg = undefined,
    a_n: usize = 0,
    b_in: [16]Msg = undefined,
    b_n: usize = 0,
};
const Msg = struct { from: u64, len: usize, data: [32]u8 = undefined };

pub fn main() void {
    var a = ice.Agent(8){ .controlling = true, .tx_seed = 0xA }; // the initiator nominates
    var b = ice.Agent(8){ .controlling = false, .tx_seed = 0xB };
    a.addRemote(.{ .addr = 0x000B, .kind = .host }, 100); // B's private addr (unreachable)
    a.addRemote(.{ .addr = b_pub, .kind = .srflx }, 100); // B's public mapping
    b.addRemote(.{ .addr = 0x000A, .kind = .host }, 100);
    b.addRemote(.{ .addr = a_pub, .kind = .srflx }, 100);

    var now: i64 = 0;
    var step: usize = 0;
    while (step < 100 and (a.selected() == null or b.selected() == null)) : (step += 1) {
        pump(&a, true, now);
        pump(&b, false, now);
        now += 25;
    }

    std.debug.print("nat_punch: A nominated 0x{X}, B nominated 0x{X} - direct path established\n", .{
        a.selected() orelse 0, b.selected() orelse 0,
    });
}

// drive one agent for a tick: send its next probe, and answer any inbound checks
fn pump(agent: *ice.Agent(8), is_a: bool, now: i64) void {
    const my_pub = if (is_a) a_pub else b_pub;
    var pbuf: [64]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    if (agent.pollProbe(&pbuf, now)) |pr| deliver(pr.to, my_pub, pbuf[0..pr.len]);
    while (recv(is_a)) |m| {
        // a request gets a response back to the sender; a response is processed in place
        if (agent.onCheck(m.from, m.data[0..m.len], &rbuf)) |rn| deliver(m.from, my_pub, rbuf[0..rn]);
    }
}
fn deliver(to: u64, from: u64, bytes: []const u8) void {
    if (to != a_pub and to != b_pub) return; // NAT drops anything not aimed at a public mapping
    var m = Msg{ .from = from, .len = bytes.len };
    @memcpy(m.data[0..bytes.len], bytes);
    if (to == a_pub) {
        net.a_in[net.a_n] = m;
        net.a_n += 1;
    } else {
        net.b_in[net.b_n] = m;
        net.b_n += 1;
    }
}
fn recv(is_a: bool) ?Msg {
    const n = if (is_a) &net.a_n else &net.b_n;
    if (n.* == 0) return null;
    const inbox = if (is_a) &net.a_in else &net.b_in;
    const m = inbox[0];
    for (1..n.*) |i| inbox[i - 1] = inbox[i];
    n.* -= 1;
    return m;
}
