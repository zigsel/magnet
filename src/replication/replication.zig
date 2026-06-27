//! `replication` module barrel - generic world sync (sans-IO; never imports
//! `runtime`). The module root, imported by name. Deps: core, wire.

pub const registry = @import("registry.zig").registry;
pub const World = @import("world.zig").World;
pub const EntityMap = @import("entity_map.zig").EntityMap;
pub const EntityRef = @import("entity_map.zig").EntityRef;
pub const auth = @import("authority.zig");
pub const Snapshot = @import("snapshot.zig").Snapshot;
pub const interest = @import("interest.zig");
pub const Priority = @import("priority.zig").Priority;
pub const History = @import("history.zig").History;
pub const MismatchMask = @import("history.zig").MismatchMask;
pub const Predictor = @import("predict.zig").Predictor;
pub const correction = @import("correction.zig");
pub const Interpolator = @import("interpolate.zig").Interpolator;
pub const InputBuffer = @import("input.zig").InputBuffer;
pub const tick = @import("tick.zig");
pub const LagComp = @import("lagcomp.zig").LagComp;
pub const prespawn = @import("prespawn.zig");
pub const Lockstep = @import("lockstep.zig").Lockstep;
pub const P2p = @import("p2p.zig").P2p;
pub const engine = @import("engine.zig").Engine;
pub const Dense = @import("store.zig").Dense;
pub const Scoped = @import("store.zig").Scoped;
pub const Sparse = @import("store.zig").Sparse;

pub const Authority = enum { server, p2p_rollback, lockstep };

/// Genre-as-config front door: pick the authority model and get the matching engine
/// type. `.server` → the prediction/rollback `Engine` (spec = `.{ .components, .Input,
/// .step, … }`); `.p2p_rollback` → `P2p`; `.lockstep` → `Lockstep` (spec carries the
/// deterministic `State`/`Input`/`step`/peer count). One entry point, three models.
pub fn authority(comptime mode: Authority, comptime spec: anytype) type {
    return switch (mode) {
        .server => engine(spec),
        .p2p_rollback => P2p(spec.State, spec.Input, spec.step, spec.cap),
        .lockstep => Lockstep(spec.State, spec.Input, spec.step, spec.n_peers, spec.cap),
    };
}

test {
    _ = @import("registry.zig");
    _ = @import("world.zig");
    _ = @import("entity_map.zig");
    _ = @import("interest.zig");
    _ = @import("priority.zig");
    _ = @import("snapshot.zig");
    _ = @import("history.zig");
    _ = @import("predict.zig");
    _ = @import("correction.zig");
    _ = @import("interpolate.zig");
    _ = @import("input.zig");
    _ = @import("tick.zig");
    _ = @import("lagcomp.zig");
    _ = @import("prespawn.zig");
    _ = @import("lockstep.zig");
    _ = @import("p2p.zig");
    _ = @import("engine.zig");
    _ = @import("store.zig");
    _ = @import("authority.zig");
}
