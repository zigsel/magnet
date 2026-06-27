//! Golden wire-format corpus. Byte-exact vectors for the core encodings,
//! each value hand-computed from the spec (not captured from the code), so any
//! accidental change to bit order, frame layout, field order, or endianness across a
//! refactor breaks a test. This is the wire-compat tripwire for `protocol_id` v1.

const std = @import("std");
const testing = std.testing;
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;
const quantize = @import("wire").quantize;
const delta = @import("wire").delta;
const handshake = @import("proto").conn.handshake;
const ack = @import("proto").delivery.ack;
const SequenceBuffer = @import("core").SequenceBuffer;

test "golden: bitpacker is LSB-first within a byte" {
    // two u4 fields {a=0x5, b=0xA} pack into one byte: a in the low nibble, b in the high.
    const BP = struct { a: u4, b: u4 };
    var buf: [4]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    serde.write(&w, BP{ .a = 0x5, .b = 0xA });
    try testing.expectEqualSlices(u8, &.{0xA5}, w.finish());
    try testing.expectEqual(@as(usize, 8), serde.measureBits(BP{ .a = 0, .b = 0 }));
}

test "golden: derived struct serde - byte-aligned little-endian field order" {
    const Msg = struct { a: u8, b: u16 }; // a, then b (LE)
    var buf: [8]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    serde.write(&w, Msg{ .a = 0x12, .b = 0xBEEF });
    try testing.expectEqualSlices(u8, &.{ 0x12, 0xEF, 0xBE }, w.finish());
}

test "golden: enum tag uses minimal bits (enum(u2))" {
    const Color = enum(u2) { red, green, blue };
    var buf: [4]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    serde.write(&w, Color.blue); // tag 2 → 2 bits → 0b10 in a single byte
    try testing.expectEqualSlices(u8, &.{0x02}, w.finish());
    try testing.expectEqual(@as(usize, 2), serde.measureBits(Color.red));
}

test "golden: ranged-int quantization is value-minus-min in minimal bits" {
    var buf: [4]u8 = undefined;
    var w = bitpack.Writer.init(&buf);
    quantize.writeRangedInt(&w, -100, -128, 127); // 8-bit range; offset = -100 - (-128) = 28
    try testing.expectEqualSlices(u8, &.{28}, w.finish());
    try testing.expectEqual(@as(u7, 8), quantize.bitsForRange(-128, 127));
}

test "golden: truncated packet number is little-endian, minimal length" {
    var buf: [8]u8 = undefined;
    var bw = delta.ByteWriter.init(&buf);
    delta.writePn(&bw, 0x1234, 2); // 2 bytes, LE
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, bw.finish());
}

test "golden: handshake hello layout [0x80][protocol_id:8 LE][app_version:4 LE]" {
    var buf: [16]u8 = undefined;
    const n = handshake.writeHello(&buf, 0x0A17_4747, 2);
    try testing.expectEqual(@as(usize, 13), n);
    try testing.expectEqualSlices(u8, &.{
        0x80, // bit7 = handshake, type 0 = hello
        0x47, 0x47, 0x17, 0x0A, 0x00, 0x00, 0x00, 0x00, // protocol_id LE
        0x02, 0x00, 0x00, 0x00, // app_version LE
    }, buf[0..n]);
}

test "golden: ACK frame layout [largest:Seq][nblocks][ack_delay:2][first_size:2]…" {
    var recv = SequenceBuffer(void, 256, u16).init();
    for ([_]u16{ 0, 1, 2 }) |pn| recv.insert(pn, {}); // a 3-long contiguous run
    const A16 = ack.Ack(u16, 16);
    const f = A16.generate(&recv, 2, 128); // largest=2, first_size=3, nblocks=0, delay=0
    var buf: [32]u8 = undefined;
    const n = A16.encode(f, &buf).?;
    try testing.expectEqualSlices(u8, &.{
        0x02, 0x00, // largest = 2 (u16 LE)
        0x00, // nblocks = 0
        0x00, 0x00, // ack_delay = 0
        0x03, 0x00, // first_size = 3
    }, buf[0..n]);
}
