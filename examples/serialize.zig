//! serialize - the comptime, bit-level serializer. Plain data needs no hand-written
//! code: the field walk is derived from the type. Opt into quantization with one decl.

const std = @import("std");
const wire = @import("magnet").wire;

const Player = struct {
    id: u16,
    health: u8,
    weapon: enum(u2) { fist, pistol, rifle },
    alive: bool,
    pos: Vec2, // quantized - see the `magnetSerialize` override below
};

const Vec2 = struct {
    x: f32,
    y: f32,
    // pack each coordinate into 16 bits over [-100, 100] instead of a full f32.
    pub fn magnetSerialize(coder: anytype, self: *@This()) void {
        coder.floatQ(&self.x, -100, 100, 16);
        coder.floatQ(&self.y, -100, 100, 16);
    }
};

pub fn main() void {
    const p = Player{
        .id = 7,
        .health = 100,
        .weapon = .rifle,
        .alive = true,
        .pos = .{ .x = 12.5, .y = -3.25 },
    };

    var buf: [64]u8 = undefined;
    var w = wire.bitpack.Writer.init(&buf);
    wire.serde.write(&w, p);
    const bytes = w.finish();

    var r = wire.bitpack.Reader.init(bytes);
    const back = wire.serde.read(Player, &r).?;

    std.debug.print("serialize: {d} bytes on the wire vs {d} in memory\n", .{ bytes.len, @sizeOf(Player) });
    std.debug.print("  id={d} health={d} weapon={s} pos=({d:.2},{d:.2})\n", .{
        back.id, back.health, @tagName(back.weapon), back.pos.x, back.pos.y,
    });
}
