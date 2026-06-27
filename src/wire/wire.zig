//! `wire` module barrel - serialization. Imported by name (`@import("wire")`).
//! A leaf above `core` only (self-contained today); no `../../wire/...` paths.

pub const bitpack = @import("bitpack.zig");
pub const serde = @import("serde.zig");
pub const Bounded = serde.Bounded;
pub const quantize = @import("quantize.zig");
pub const delta = @import("delta.zig");

test {
    _ = @import("bitpack.zig");
    _ = @import("serde.zig");
    _ = @import("quantize.zig");
    _ = @import("delta.zig");
}
