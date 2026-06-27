//! Replay protection: a sliding-window "accept each packet number at most once,
//! reject anything older than the window behind the highest seen." Thin comptime
//! wrapper over the shared `core.ReplayWindow` (the same stored-sequence
//! disambiguation as `SequenceBuffer`), sized from `Security.replay_window`.
//! Per-direction; the receiver runs one over the decrypted packet number.

const std = @import("std");
const ReplayWindow = @import("core").ReplayWindow;

pub fn Replay(comptime window: usize, comptime Seq: type) type {
    return ReplayWindow(window, Seq);
}

const testing = std.testing;

test "replay window accepts fresh once, rejects dup and too-old" {
    var rw = Replay(1024, u16).init();
    try testing.expect(rw.accept(1000));
    try testing.expect(!rw.accept(1000)); // replay
    try testing.expect(rw.accept(1001));
    try testing.expect(rw.accept(999)); // in-window, fresh
    try testing.expect(!rw.accept(999)); // now replayed
    try testing.expect(rw.accept(5000)); // jump forward
    try testing.expect(!rw.accept(1001)); // far behind window now
}
