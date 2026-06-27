//! `core` module barrel - zero-dependency primitives. This is the module
//! root: every other layer imports it by name (`@import("core")`), never by file path,
//! so there are no fragile `../../core/...` paths and `core` is a true leaf (it imports
//! nothing above it - the compiler enforces that via the module graph in build.zig).

pub const seq = @import("seq.zig");
pub const SequenceBuffer = @import("sequence_buffer.zig").SequenceBuffer;

pub const bitset = @import("bitset.zig");
pub const BitSet = bitset.BitSet;
pub const ReplayWindow = bitset.ReplayWindow;

pub const Ring = @import("ring.zig").Ring;
pub const Spsc = @import("spsc.zig").Spsc;

pub const pool = @import("pool.zig");
pub const Pool = pool.Pool;
pub const IntrusiveList = pool.IntrusiveList;

pub const fixed = @import("fixed.zig");
pub const Fixed = fixed.Fixed;

test {
    _ = @import("seq.zig");
    _ = @import("sequence_buffer.zig");
    _ = @import("bitset.zig");
    _ = @import("ring.zig");
    _ = @import("spsc.zig");
    _ = @import("pool.zig");
    _ = @import("fixed.zig");
}
