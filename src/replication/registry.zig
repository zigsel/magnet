//! The comptime **component registry**. `registry(.{ .components = .{A, B, …} })`
//! assigns each replicated component type a **stable small integer id** (its
//! declaration index) and monomorphizes per-type serialize / deserialize (via the
//! `@typeInfo`-derived `wire.serde`) and equality (for diffing). No `TypeId` sort
//! fragility, no `unsafe fn()` transmutes - Zig does the per-type dispatch natively.

const std = @import("std");
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;

pub fn registry(comptime spec: anytype) type {
    const comps = spec.components;
    const Tuple = @TypeOf(comps);
    const n = @typeInfo(Tuple).@"struct".fields.len;
    if (n == 0) @compileError("registry needs at least one component");
    if (n > 64) @compileError("registry supports at most 64 components (u64 change mask)");

    return struct {
        pub const count = n;
        /// The input type for prediction; `void` if unset.
        pub const Input = if (@hasField(@TypeOf(spec), "Input")) spec.Input else void;
        /// Bitmask over the component set (one bit per component id).
        pub const Mask = std.meta.Int(.unsigned, n);

        pub fn Type(comptime id: usize) type {
            return comps[id];
        }

        /// The stable wire id (declaration index) of component type `T`.
        pub fn idOf(comptime T: type) u8 {
            inline for (0..n) |i| {
                if (comps[i] == T) return @intCast(i);
            }
            @compileError("registry: " ++ @typeName(T) ++ " is not a registered component");
        }

        pub fn maskOf(comptime T: type) Mask {
            return @as(Mask, 1) << @intCast(idOf(T));
        }

        /// Serialize component `id`'s value (bit-packed, derived).
        pub fn write(comptime id: usize, w: *bitpack.Writer, value: Type(id)) void {
            serde.write(w, value);
        }
        /// Deserialize component `id`'s value; null on malformed bytes.
        pub fn read(comptime id: usize, r: *bitpack.Reader) ?Type(id) {
            return serde.read(Type(id), r);
        }
        pub fn eql(comptime id: usize, a: Type(id), b: Type(id)) bool {
            return std.meta.eql(a, b);
        }
    };
}

const testing = std.testing;

const Pos = struct { x: i16, y: i16 };
const Vel = struct { dx: i8, dy: i8 };
const Health = struct { hp: u16 };
const TestReg = registry(.{ .components = .{ Pos, Vel, Health } });

test "registry assigns stable ids and a change mask" {
    try testing.expectEqual(@as(usize, 3), TestReg.count);
    try testing.expectEqual(@as(u8, 0), TestReg.idOf(Pos));
    try testing.expectEqual(@as(u8, 1), TestReg.idOf(Vel));
    try testing.expectEqual(@as(u8, 2), TestReg.idOf(Health));
    try testing.expectEqual(@as(TestReg.Mask, 0b100), TestReg.maskOf(Health));
}

test "registry round-trips component values via the derived serializer" {
    var buf: [32]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    TestReg.write(TestReg.idOf(Pos), &w, .{ .x = -5, .y = 9 });
    var r = bitpack.Reader.init(w.finish());
    const back = TestReg.read(TestReg.idOf(Pos), &r).?;
    try testing.expectEqual(@as(i16, -5), back.x);
    try testing.expectEqual(@as(i16, 9), back.y);
}

test "registry equality drives diffing" {
    try testing.expect(TestReg.eql(0, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 2 }));
    try testing.expect(!TestReg.eql(0, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 }));
}
