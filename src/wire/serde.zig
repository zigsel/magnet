//! Comptime-derived serialization. One `serialize` body, specialized at compile
//! time into write / read / measure via the `Coder(mode)` - the yojimbo unified
//! read/write/measure trick, but the field walk is *derived from `@typeInfo`*, so
//! plain data types need no hand-written serde (the upgrade over every reference).
//!
//! A type may override the derived walk with `pub fn magnetSerialize(coder, self)`
//! (the `@hasDecl` hook, e.g. to quantize fields). Reads are range-checked: a
//! malformed enum tag or a truncated buffer marks the reader failed and `read()`
//! returns null. No allocation; the writer targets a caller-owned buffer.

const std = @import("std");
const bitpack = @import("bitpack.zig");
const quantize = @import("quantize.zig");

pub const Mode = enum { write, read, measure };

/// A bounded, length-prefixed sequence of `T` (≤ `max` elements) - the serializable
/// stand-in for a slice (raw slices/pointers are not derivable). Stores a fixed
/// `[max]T` inline; the on-wire form is `[len: minimal bits for 0..max][elems]`.
pub fn Bounded(comptime T: type, comptime max: usize) type {
    return struct {
        const Self = @This();
        pub const Elem = T;
        pub const capacity = max;

        items: [max]T = undefined,
        len: usize = 0,

        pub fn fromSlice(s: []const T) Self {
            var self: Self = .{ .len = @min(s.len, max) };
            @memcpy(self.items[0..self.len], s[0..self.len]);
            return self;
        }
        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }
        pub fn append(self: *Self, v: T) bool {
            if (self.len >= max) return false;
            self.items[self.len] = v;
            self.len += 1;
            return true;
        }

        pub fn magnetSerialize(coder: anytype, self: *Self) void {
            var n: usize = self.len;
            coder.intRanged(&n, 0, @intCast(max));
            if (@TypeOf(coder.*).coder_mode == .read) {
                if (n > max) {
                    coder.fail();
                    return;
                }
                self.len = n;
            }
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                serialize(coder, T, &self.items[i]);
                if (coder.failed()) return;
            }
        }
    };
}

pub fn Coder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        pub const coder_mode = mode;

        w: if (mode == .write) *bitpack.Writer else void =
            if (mode == .write) undefined else {},
        r: if (mode == .read) *bitpack.Reader else void =
            if (mode == .read) undefined else {},
        bits: usize = 0,

        pub fn failed(self: *Self) bool {
            return mode == .read and self.r.failed;
        }
        pub fn fail(self: *Self) void {
            if (mode == .read) self.r.failed = true;
        }

        /// Quantized-float field helper for custom `magnetSerialize` bodies.
        pub fn floatQ(self: *Self, ptr: *f32, comptime mn: f32, comptime mx: f32, comptime nbits: u6) void {
            if (mode == .write) {
                quantize.writeFloat(self.w, ptr.*, mn, mx, nbits);
            } else if (mode == .read) {
                ptr.* = quantize.readFloat(self.r, mn, mx, nbits);
            } else {
                self.bits += nbits;
            }
        }

        /// Bounded-integer field helper for custom `magnetSerialize` bodies.
        pub fn intRanged(self: *Self, ptr: anytype, comptime mn: i64, comptime mx: i64) void {
            if (mode == .write) {
                quantize.writeRangedInt(self.w, @intCast(ptr.*), mn, mx);
            } else if (mode == .read) {
                ptr.* = @intCast(quantize.readRangedInt(self.r, mn, mx));
            } else {
                self.bits += quantize.bitsForRange(mn, mx);
            }
        }
    };
}

/// Recursively encode/decode `ptr.*` of type `T` through `coder`.
pub fn serialize(coder: anytype, comptime T: type, ptr: *T) void {
    const mode = @TypeOf(coder.*).coder_mode;
    if (coder.failed()) return;

    const ti = @typeInfo(T);
    if ((ti == .@"struct" or ti == .@"union" or ti == .@"enum") and @hasDecl(T, "magnetSerialize")) {
        T.magnetSerialize(coder, ptr);
        return;
    }

    switch (ti) {
        .int => |info| {
            const nbits: u7 = info.bits;
            const U = std.meta.Int(.unsigned, info.bits);
            if (mode == .write) {
                const uval: U = @bitCast(ptr.*);
                coder.w.writeBits64(@as(u64, uval), nbits);
            } else if (mode == .read) {
                const raw = coder.r.readBits64(nbits);
                const uval: U = @intCast(raw);
                ptr.* = @bitCast(uval);
            } else {
                coder.bits += nbits;
            }
        },
        .bool => {
            if (mode == .write) {
                coder.w.writeBool(ptr.*);
            } else if (mode == .read) {
                ptr.* = coder.r.readBool();
            } else {
                coder.bits += 1;
            }
        },
        .float => |fl| {
            const U = std.meta.Int(.unsigned, fl.bits);
            var u: U = if (mode == .read) undefined else @bitCast(ptr.*);
            serialize(coder, U, &u);
            if (mode == .read) ptr.* = @bitCast(u);
        },
        .@"enum" => |e| {
            var t: e.tag_type = if (mode == .read) undefined else @intFromEnum(ptr.*);
            serialize(coder, e.tag_type, &t);
            if (mode == .read and !coder.failed()) {
                ptr.* = std.enums.fromInt(T, t) orelse {
                    coder.fail();
                    return;
                };
            }
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const Backing = s.backing_integer.?;
                var bi: Backing = if (mode == .read) undefined else @bitCast(ptr.*);
                serialize(coder, Backing, &bi);
                if (mode == .read) ptr.* = @bitCast(bi);
            } else {
                inline for (s.fields) |f| {
                    serialize(coder, f.type, &@field(ptr.*, f.name));
                    if (coder.failed()) return;
                }
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("only tagged unions serialize: " ++ @typeName(T));
            const Tag = u.tag_type.?;
            var tag_val: Tag = if (mode == .read) undefined else std.meta.activeTag(ptr.*);
            serialize(coder, Tag, &tag_val);
            if (coder.failed()) return;
            inline for (u.fields) |f| {
                if (tag_val == @field(Tag, f.name)) {
                    if (mode == .read) {
                        var payload: f.type = undefined;
                        serialize(coder, f.type, &payload);
                        ptr.* = @unionInit(T, f.name, payload);
                    } else {
                        serialize(coder, f.type, &@field(ptr.*, f.name));
                    }
                }
            }
        },
        .optional => |o| {
            if (mode == .read) {
                if (coder.r.readBool()) {
                    var child: o.child = undefined;
                    serialize(coder, o.child, &child);
                    ptr.* = if (coder.failed()) null else child;
                } else {
                    ptr.* = null;
                }
            } else {
                const present = ptr.* != null;
                if (mode == .write) coder.w.writeBool(present) else coder.bits += 1;
                if (present) {
                    var child = ptr.*.?;
                    serialize(coder, o.child, &child);
                }
            }
        },
        .array => |a| {
            for (ptr) |*elem| {
                serialize(coder, a.child, elem);
                if (coder.failed()) return;
            }
        },
        .void => {},
        .pointer => @compileError("slices/pointers need a bounded wrapper (wire.Bounded); not derivable: " ++ @typeName(T)),
        else => @compileError("magnet.wire cannot serialize " ++ @typeName(T)),
    }
}

/// Encode `value` into `w` (derived). Returns nothing; check `w.overflowed`.
pub fn write(w: *bitpack.Writer, value: anytype) void {
    var coder = Coder(.write){ .w = w };
    var v = value;
    serialize(&coder, @TypeOf(value), &v);
}

/// Decode a `T` from `r`. Returns null if the bytes were malformed/truncated.
pub fn read(comptime T: type, r: *bitpack.Reader) ?T {
    var coder = Coder(.read){ .r = r };
    var v: T = undefined;
    serialize(&coder, T, &v);
    return if (r.failed) null else v;
}

/// Exact serialized size of `value` in bits, without writing (measure-before-commit).
pub fn measureBits(value: anytype) usize {
    var coder = Coder(.measure){};
    var v = value;
    serialize(&coder, @TypeOf(value), &v);
    return coder.bits;
}

pub fn measureBytes(value: anytype) usize {
    return (measureBits(value) + 7) / 8;
}

const testing = std.testing;

const Inner = struct { a: u7, flag: bool };
const Color = enum(u2) { red, green, blue };
const Event = union(enum) {
    none: void,
    spawn: struct { id: u16, kind: u10 },
    score: i16,
};
const Buttons = packed struct(u8) { fire: bool, jump: bool, crouch: bool, _pad: u5 = 0 };

const Msg = struct {
    seq: u16,
    health: i16,
    speed: f32,
    color: Color,
    inner: Inner,
    maybe: ?u12,
    nothing: ?u8,
    triple: [3]u8,
    ev: Event,
    btn: Buttons,
};

fn sample() Msg {
    return .{
        .seq = 0xBEEF,
        .health = -123,
        .speed = 3.5,
        .color = .blue,
        .inner = .{ .a = 100, .flag = true },
        .maybe = 4000,
        .nothing = null,
        .triple = .{ 9, 8, 7 },
        .ev = .{ .spawn = .{ .id = 777, .kind = 33 } },
        .btn = .{ .fire = true, .jump = false, .crouch = true },
    };
}

fn expectEqualMsg(a: Msg, b: Msg) !void {
    try testing.expectEqual(a.seq, b.seq);
    try testing.expectEqual(a.health, b.health);
    try testing.expectEqual(a.speed, b.speed);
    try testing.expectEqual(a.color, b.color);
    try testing.expectEqual(a.inner, b.inner);
    try testing.expectEqual(a.maybe, b.maybe);
    try testing.expectEqual(a.nothing, b.nothing);
    try testing.expectEqualSlices(u8, &a.triple, &b.triple);
    try testing.expectEqual(a.btn, b.btn);
    try testing.expectEqual(std.meta.activeTag(a.ev), std.meta.activeTag(b.ev));
    try testing.expectEqual(a.ev.spawn.id, b.ev.spawn.id);
    try testing.expectEqual(a.ev.spawn.kind, b.ev.spawn.kind);
}

test "derived roundtrip of a rich message" {
    const msg = sample();
    var buf: [128]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, msg);
    const bytes = w.finish();
    try testing.expect(!w.overflowed);

    var r = bitpack.Reader.init(bytes);
    const back = read(Msg, &r).?;
    try expectEqualMsg(msg, back);
}

test "measureBits matches what write produces" {
    const msg = sample();
    const measured = measureBits(msg);
    var buf: [128]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, msg);
    try testing.expectEqual(measured, w.bitCount());
}

test "truncated buffer -> read returns null" {
    const msg = sample();
    var buf: [128]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, msg);
    const bytes = w.finish();
    var r = bitpack.Reader.init(bytes[0 .. bytes.len - 2]);
    try testing.expect(read(Msg, &r) == null);
}

test "different union variant roundtrips" {
    var msg = sample();
    msg.ev = .{ .score = -42 };
    var buf: [128]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, msg);
    var r = bitpack.Reader.init(w.finish());
    const back = read(Msg, &r).?;
    try testing.expectEqual(@as(i16, -42), back.ev.score);
}

const Vec2q = struct {
    x: f32,
    y: f32,
    pub fn magnetSerialize(coder: anytype, self: *@This()) void {
        coder.floatQ(&self.x, -10, 10, 16);
        coder.floatQ(&self.y, -10, 10, 16);
    }
};

test "custom magnetSerialize override (quantized) roundtrips within tolerance" {
    const Wrap = struct { tag: u8, pos: Vec2q };
    const val = Wrap{ .tag = 7, .pos = .{ .x = 1.2345, .y = -6.78 } };
    var buf: [32]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, val);
    var r = bitpack.Reader.init(w.finish());
    const back = read(Wrap, &r).?;
    try testing.expectEqual(@as(u8, 7), back.tag);
    const res = quantize.floatResolution(-10, 10, 16);
    try testing.expect(@abs(back.pos.x - val.pos.x) <= res);
    try testing.expect(@abs(back.pos.y - val.pos.y) <= res);
}

fn randomMsg(rnd: std.Random) Msg {
    return .{
        .seq = rnd.int(u16),
        .health = rnd.int(i16),
        .speed = @bitCast(rnd.int(u32)),
        .color = @enumFromInt(rnd.uintLessThan(u8, 3)),
        .inner = .{ .a = rnd.int(u7), .flag = rnd.boolean() },
        .maybe = if (rnd.boolean()) rnd.int(u12) else null,
        .nothing = if (rnd.boolean()) rnd.int(u8) else null,
        .triple = .{ rnd.int(u8), rnd.int(u8), rnd.int(u8) },
        .ev = switch (rnd.uintLessThan(u8, 3)) {
            0 => .{ .none = {} },
            1 => .{ .spawn = .{ .id = rnd.int(u16), .kind = rnd.int(u10) } },
            else => .{ .score = rnd.int(i16) },
        },
        .btn = @bitCast(rnd.int(u8)),
    };
}

test "fuzz: random messages survive write/read/write byte-identically" {
    var prng = std.Random.DefaultPrng.init(0xA5A5A5);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const msg = randomMsg(rnd);
        var b1: [128]u8 = undefined;
        var w1 = bitpack.Writer.init(&b1);
        write(&w1, msg);
        const bytes1 = w1.finish();
        var r = bitpack.Reader.init(bytes1);
        const back = read(Msg, &r) orelse return error.TestUnexpectedResult;
        var b2: [128]u8 = undefined;
        var w2 = bitpack.Writer.init(&b2);
        write(&w2, back);
        try testing.expectEqualSlices(u8, bytes1, w2.finish());
    }
}

test "bounded slice roundtrips (length-prefixed, range-checked)" {
    const B = Bounded(u16, 8);
    const v = B.fromSlice(&.{ 10, 20, 30 });
    var buf: [64]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    write(&w, v);
    var r = bitpack.Reader.init(w.finish());
    const back = read(B, &r).?;
    try testing.expectEqual(@as(usize, 3), back.len);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 30 }, back.slice());

    // nested in a struct
    const Wrap = struct { tag: u8, names: Bounded(u8, 4) };
    const wv = Wrap{ .tag = 7, .names = Bounded(u8, 4).fromSlice(&.{ 1, 2 }) };
    var b2: [64]u8 = undefined;
    var w2 = bitpack.Writer.init(&b2);
    write(&w2, wv);
    var r2 = bitpack.Reader.init(w2.finish());
    const back2 = read(Wrap, &r2).?;
    try testing.expectEqual(@as(u8, 7), back2.tag);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, back2.names.slice());
}

test "fuzz: decoding random bytes never crashes" {
    var prng = std.Random.DefaultPrng.init(0x5A5A5A);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var bytes: [48]u8 = undefined;
        rnd.bytes(&bytes);
        const len = rnd.uintLessThan(usize, bytes.len + 1);
        var r = bitpack.Reader.init(bytes[0..len]);
        _ = read(Msg, &r); // null or a value - must not crash
    }
}
