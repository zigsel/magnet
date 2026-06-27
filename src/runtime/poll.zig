//! Minimal poll-driver helpers: shuttle datagrams between an `Endpoint` and a
//! duck-typed transport (`recv(buf, now) ?{addr,len}` / `send(addr, bytes, now)`).
//! The real `std.Io` socket/event-loop drivers (reactor/sharded/task) build on the
//! same shape with the real socket drivers; the sim transport uses it now for tests.

/// Comptime contract check for a transport: `recv(buf, now) ?{addr,len}` /
/// `send(addr, bytes, now)`. `runtime.sim.Transport` is the ready-made example to copy.
pub fn assertTransport(comptime T: type) void {
    const D = if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T;
    if (!@hasDecl(D, "recv")) @compileError("transport '" ++ @typeName(D) ++ "' is missing `recv(buf, now) ?Recv` (see sim.Transport)");
    if (!@hasDecl(D, "send")) @compileError("transport '" ++ @typeName(D) ++ "' is missing `send(addr, bytes, now)` (see sim.Transport)");
}

/// Drain all ready inbound datagrams into the endpoint.
pub fn recvAll(ep: anytype, transport: anytype, scratch: []u8, now: i64) void {
    comptime assertTransport(@TypeOf(transport));
    while (transport.recv(scratch, now)) |r| ep.feedFrom(r.addr, scratch[0..r.len], now);
}

/// Flush all queued outbound datagrams from the endpoint to the transport.
pub fn flushAll(ep: anytype, transport: anytype, scratch: []u8, now: i64) void {
    comptime assertTransport(@TypeOf(transport));
    while (ep.pollTransmit(scratch, now)) |d| transport.send(d.addr, scratch[0..d.len], now);
}
