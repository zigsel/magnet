//! `runtime` module barrel - drivers / test substrate. The top layer: the only place
//! real IO lives. Imported by name. Deps: core, config, proto.

pub const sim = @import("sim.zig");
pub const poll = @import("poll.zig");
pub const reactor = @import("reactor.zig");
pub const sharded = @import("sharded.zig");
pub const task = @import("task.zig");
pub const pool = @import("pool.zig");
pub const record = @import("record.zig");
pub const io = @import("io.zig");
pub const io_linux = @import("io_linux.zig");

test {
    _ = @import("sim.zig");
    _ = @import("poll.zig");
    _ = @import("reactor.zig");
    _ = @import("sharded.zig");
    _ = @import("task.zig");
    _ = @import("pool.zig");
    _ = @import("record.zig");
    _ = @import("io.zig");
    _ = @import("io_linux.zig");
}
