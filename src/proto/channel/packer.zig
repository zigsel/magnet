//! Bit/byte-budget packing primitives: measure-before-commit so a message is only
//! taken if it fits the remaining datagram budget (no half-written messages), plus
//! the resend-time gate. Multi-channel coalescing = run several channels' packing
//! against the *same* `Budget` so they share one datagram.

const std = @import("std");

pub const Budget = struct {
    limit: usize,
    used: usize = 0,

    pub fn init(limit: usize) Budget {
        return .{ .limit = limit };
    }
    pub fn remaining(self: *const Budget) usize {
        return self.limit - self.used;
    }
    /// Would `size` fit? (measure step - does not commit)
    pub fn fits(self: *const Budget, size: usize) bool {
        return self.used + size <= self.limit;
    }
    /// Commit `size` if it fits; returns whether it was taken.
    pub fn take(self: *Budget, size: usize) bool {
        if (!self.fits(size)) return false;
        self.used += size;
        return true;
    }
};

/// Resend-time gate: a message is due to (re)send if never sent, or its resend
/// timer elapsed.
pub fn due(ever_sent: bool, last_sent: i64, now: i64, resend_ms: i64) bool {
    return !ever_sent or (now - last_sent) >= resend_ms;
}

const testing = std.testing;

test "measure-before-commit: only whole messages that fit are taken" {
    var b = Budget.init(1000);
    try testing.expect(b.fits(600));
    try testing.expect(b.take(600));
    try testing.expect(!b.fits(600)); // 1000-600 < 600
    try testing.expect(!b.take(600)); // not committed
    try testing.expectEqual(@as(usize, 400), b.remaining());
    try testing.expect(b.take(400)); // exact fit
    try testing.expectEqual(@as(usize, 0), b.remaining());
}

test "multi-channel coalescing shares one budget" {
    var b = Budget.init(300);
    // channel A messages (100 each), channel B messages (100 each) into one datagram
    var taken: usize = 0;
    const sizes = [_]usize{ 100, 100, 100, 100 }; // 4 candidates, only 3 fit
    for (sizes) |s| {
        if (b.take(s)) taken += 1;
    }
    try testing.expectEqual(@as(usize, 3), taken);
}

test "resend gate" {
    try testing.expect(due(false, 0, 0, 100)); // never sent
    try testing.expect(!due(true, 50, 100, 100)); // sent 50ms ago, resend 100
    try testing.expect(due(true, 0, 100, 100)); // 100ms elapsed
}
