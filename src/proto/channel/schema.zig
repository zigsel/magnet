//! `channels(.{ .name = .{ .mode = …, .priority = …, .weight = … }, … })` - the
//! comptime channel schema. Channels are selected by **enum literal** (`.chat`,
//! `.moves`) and resolved at compile time via `@tagName` + `@field`; each also has
//! a stable integer `idOf` (its wire channel id) so the rest of the stack can
//! `inline for` over a fixed, named channel set and index per-channel state.

const std = @import("std");
const Mode = @import("ordering.zig").Mode;

pub const ChannelConfig = struct {
    mode: Mode,
    priority: u8 = 0,
    weight: u32 = 1,
    Message: type = void,
};

pub fn channels(comptime spec: anytype) type {
    const sfields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    if (sfields.len == 0) @compileError("channels(): at least one channel required");

    return struct {
        pub const count = sfields.len;

        /// Channel field names in declaration order (index == wire channel id).
        pub const names: [sfields.len][]const u8 = blk: {
            var n: [sfields.len][]const u8 = undefined;
            for (sfields, 0..) |f, i| n[i] = f.name;
            break :blk n;
        };

        /// Per-index runtime tables (index == wire channel id).
        pub const modes: [sfields.len]Mode = blk: {
            var m: [sfields.len]Mode = undefined;
            for (sfields, 0..) |f, i| m[i] = @field(spec, f.name).mode;
            break :blk m;
        };
        pub const priorities: [sfields.len]u8 = blk: {
            var p: [sfields.len]u8 = undefined;
            for (sfields, 0..) |f, i| {
                const c = @field(spec, f.name);
                p[i] = if (@hasField(@TypeOf(c), "priority")) c.priority else 0;
            }
            break :blk p;
        };
        pub const weights: [sfields.len]u32 = blk: {
            var w: [sfields.len]u32 = undefined;
            for (sfields, 0..) |f, i| {
                const c = @field(spec, f.name);
                w[i] = if (@hasField(@TypeOf(c), "weight")) c.weight else 1;
            }
            break :blk w;
        };

        pub fn configOf(comptime ch: anytype) ChannelConfig {
            const c = @field(spec, @tagName(ch));
            const C = @TypeOf(c);
            return .{
                .mode = c.mode,
                .priority = if (@hasField(C, "priority")) c.priority else 0,
                .weight = if (@hasField(C, "weight")) c.weight else 1,
                .Message = if (@hasField(C, "Message")) c.Message else void,
            };
        }
        /// The payload type carried by channel `ch`.
        pub fn MessageOf(comptime ch: anytype) type {
            return configOf(ch).Message;
        }
        pub fn modeOf(comptime ch: anytype) Mode {
            return configOf(ch).mode;
        }
        pub fn priorityOf(comptime ch: anytype) u8 {
            return configOf(ch).priority;
        }
        pub fn weightOf(comptime ch: anytype) u32 {
            return configOf(ch).weight;
        }
        /// Stable wire channel id (declaration index) for `ch`.
        pub fn idOf(comptime ch: anytype) u8 {
            inline for (sfields, 0..) |f, i| {
                if (comptime std.mem.eql(u8, f.name, @tagName(ch))) return @intCast(i);
            }
            @compileError("channels: unknown channel ." ++ @tagName(ch));
        }
    };
}

const testing = std.testing;

const Set = channels(.{
    .moves = .{ .mode = .unreliable_sequenced, .priority = 3, .weight = 1 },
    .state = .{ .mode = .unreliable, .priority = 2, .weight = 4 },
    .events = .{ .mode = .reliable_unordered, .priority = 1 },
    .chat = .{ .mode = .reliable_ordered, .priority = 0 },
    .voice = .{ .mode = .reliable_sequenced, .priority = 2 },
});

test "schema exposes per-channel config by name + stable wire ids" {
    try testing.expectEqual(@as(usize, 5), Set.count);
    try testing.expectEqual(Mode.reliable_ordered, Set.modeOf(.chat));
    try testing.expectEqual(Mode.unreliable_sequenced, Set.modeOf(.moves));
    try testing.expectEqual(@as(u8, 3), Set.priorityOf(.moves));
    try testing.expectEqual(@as(u32, 4), Set.weightOf(.state));
    try testing.expectEqual(@as(u8, 0), Set.idOf(.moves));
    try testing.expectEqual(@as(u8, 3), Set.idOf(.chat));
    try testing.expectEqual(Mode.reliable_sequenced, comptime Set.configOf(.voice).mode);
}

test "inline for over the channel set" {
    const isReliable = @import("ordering.zig").isReliable;
    comptime var reliable_count: usize = 0;
    inline for (.{ .moves, .state, .events, .chat, .voice }) |ch| {
        if (comptime isReliable(Set.modeOf(ch))) reliable_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), reliable_count); // events, chat, voice
}
