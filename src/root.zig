//! magnet - generic, zero-allocation UDP game-networking stack.
//!
//! Public surface. Layers are exposed as
//! namespaces; nothing here imports `runtime/` (the sans-IO inversion).

const std = @import("std");

/// The comptime configuration spine - `Endpoint(cfg)` / `Session(cfg)` derive everything from it.
pub const Config = @import("config").Config;
pub const Limits = @import("config").Limits;
pub const Security = @import("config").Security;
/// Observability.
pub const trace = @import("trace");

/// Shared zero-dependency primitives (the building blocks every layer reuses).
pub const core = @import("core");

/// Serialization - comptime-derived, bit-level, range-checked.
pub const wire = @import("wire");

/// The connection table for a `Config`. `Server`/`Client` are role-named aliases
/// (a client typically `connectTo`s one peer; a server accepts many).
pub fn Endpoint(comptime cfg: Config) type {
    return @import("proto").Endpoint(cfg);
}
pub const Server = Endpoint;
pub const Client = Endpoint;

/// Allocating convenience over the sans-IO surface: heap-allocate an
/// `Endpoint(cfg)` once and hand back a pointer; the hot path still never allocates.
/// `close(allocator, ep)` frees it. Use the bare `Endpoint(cfg)` directly when you
/// want to own the storage (e.g. embed it, or `allocator.create` it yourself).
pub fn open(comptime cfg: Config, allocator: std.mem.Allocator) !*Endpoint(cfg) {
    const ep = try allocator.create(Endpoint(cfg));
    ep.* = .{};
    return ep;
}
pub fn close(comptime cfg: Config, allocator: std.mem.Allocator, ep: *Endpoint(cfg)) void {
    allocator.destroy(ep);
}

/// Convenience real-`std.Io` blocking driver: pump one endpoint over a UDP socket
/// until `stop.stopped()`. The same sans-IO core runs under every runtime driver.
pub const serve = @import("runtime").io.runBlocking;

/// The sans-IO protocol core (never imports `runtime/`).
pub const proto = @import("proto");

/// Replication - generic, genre-agnostic world sync (sans-IO; never imports `runtime/`).
pub const replication = @import("replication");

/// Runtime drivers / test substrate. The only place real IO lives.
pub const runtime = @import("runtime");

/// Replication ↔ transport bridge: one-call helpers to drive the L5 engine over an
/// `Endpoint` (`pushSnapshots` server-side, `applySnapshots` client-side).
pub const host = @import("host.zig");

test {
    // Only the `magnet` module's own bridge files. Every layer (core/wire/config/trace/
    // proto/replication/runtime) is its own module with its own `test` block - build.zig
    // runs each module's tests separately; the module graph enforces the layering.
    _ = @import("integration.zig");
    _ = @import("conformance.zig");
    _ = @import("host.zig");
}

test "smoke" {
    try std.testing.expect(true);
}
