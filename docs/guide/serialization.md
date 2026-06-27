# Serialization

magnet's serializer is *derived from your types*. Plain data needs no hand-written code -
the field walk comes from `@typeInfo`. It's bit-level, range-checked, and allocation-free.
You can use it entirely on its own, without any networking.

```zig
const wire = magnet.wire;

const Msg = struct { id: u16, hp: u8, kind: enum(u2) { a, b, c }, alive: bool };

var buf: [64]u8 = undefined;
var w = wire.bitpack.Writer.init(&buf);
wire.serde.write(&w, value);            // derived
const bytes = w.finish();

var r = wire.bitpack.Reader.init(bytes);
const back = wire.serde.read(Msg, &r);  // ?Msg - null on malformed/truncated input
```

It handles ints (minimal bits), bools, floats, enums (minimal tag bits), tagged unions,
optionals (a presence bit), arrays, and packed structs - recursively.

## Measure before commit

`wire.serde.measureBytes(value)` returns the exact serialized size without writing - the
packer uses it to never overflow a datagram or half-write a message.

## Quantization

Precision is opt-in metadata; gameplay types stay plain. A type overrides the derived walk
with `magnetSerialize`:

```zig
const Vec2 = struct {
    x: f32,
    y: f32,
    pub fn magnetSerialize(coder: anytype, self: *@This()) void {
        coder.floatQ(&self.x, -100, 100, 16); // 16 bits over [-100,100]
        coder.floatQ(&self.y, -100, 100, 16);
        // coder.intRanged(&self.n, min, max) for bounded integers
    }
};
```

`wire.quantize` also offers ranged ints, compressed floats, and the quaternion
"smallest-three" packing for rotations.

## Bounded slices

Raw slices aren't derivable (no length on the wire), so use `magnet.wire.Bounded(T, max)` -
a length-prefixed, range-checked, fixed-capacity sequence that serializes like any field:

```zig
const Name = struct { text: magnet.wire.Bounded(u8, 24) };
const n = Name{ .text = .fromSlice("hello") };
// n.text.slice() on the far side
```

Runnable: [`examples/serialize.zig`](../../examples/serialize.zig).
