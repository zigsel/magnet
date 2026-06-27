//! Handle-based object pool: fixed `[capacity]T` backing + a free-list of small
//! integer handles. No pointers escape (handles are stable across the pool's
//! lifetime). Used for messages, fragments, sent-packet metadata, reliable
//! segments. Exhaustion returns null (callers map to `error.Backpressure`).

const std = @import("std");

pub fn Pool(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Pool capacity must be > 0");
    const Handle = if (capacity <= std.math.maxInt(u16)) u16 else u32;
    return struct {
        const Self = @This();
        pub const Index = Handle;
        pub const cap = capacity;

        items: [capacity]T = undefined,
        free: [capacity]Handle = undefined,
        free_len: usize = 0,
        live: usize = 0,
        initialized: bool = false,

        pub fn init() Self {
            var self: Self = .{};
            self.reset();
            return self;
        }

        pub fn reset(self: *Self) void {
            // free-list holds all handles, highest first so alloc() hands out 0,1,2…
            var i: usize = 0;
            while (i < capacity) : (i += 1) {
                self.free[i] = @intCast(capacity - 1 - i);
            }
            self.free_len = capacity;
            self.live = 0;
            self.initialized = true;
        }

        /// Allocate a slot. Returns its handle, or null if exhausted.
        pub fn alloc(self: *Self) ?Handle {
            if (self.free_len == 0) return null;
            self.free_len -= 1;
            self.live += 1;
            return self.free[self.free_len];
        }

        pub fn release(self: *Self, h: Handle) void {
            std.debug.assert(self.free_len < capacity);
            self.free[self.free_len] = h;
            self.free_len += 1;
            self.live -= 1;
        }

        pub fn get(self: *Self, h: Handle) *T {
            return &self.items[h];
        }

        pub fn getConst(self: *const Self, h: Handle) *const T {
            return &self.items[h];
        }

        pub fn available(self: *const Self) usize {
            return self.free_len;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.live;
        }
    };
}

/// Intrusive doubly-linked list over fixed index slots (GNS `CUtlLinkedList`
/// style). Indices are managed externally (typically handed out by a `Pool`);
/// this only stores the `prev`/`next` links so messages/segments can be kept in
/// an O(1)-insert/remove order without per-node allocation.
pub fn IntrusiveList(comptime capacity: usize) type {
    const Idx = if (capacity < std.math.maxInt(u16)) u16 else u32;
    const nil: Idx = std.math.maxInt(Idx);
    return struct {
        const Self = @This();
        pub const Index = Idx;
        pub const none = nil;

        next: [capacity]Idx = [_]Idx{nil} ** capacity,
        prev: [capacity]Idx = [_]Idx{nil} ** capacity,
        head: Idx = nil,
        tail: Idx = nil,
        count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn pushBack(self: *Self, i: Idx) void {
            self.next[i] = nil;
            self.prev[i] = self.tail;
            if (self.tail != nil) self.next[self.tail] = i else self.head = i;
            self.tail = i;
            self.count += 1;
        }

        pub fn remove(self: *Self, i: Idx) void {
            const p = self.prev[i];
            const n = self.next[i];
            if (p != nil) self.next[p] = n else self.head = n;
            if (n != nil) self.prev[n] = p else self.tail = p;
            self.count -= 1;
        }

        pub fn popFront(self: *Self) ?Idx {
            const h = self.head;
            if (h == nil) return null;
            self.remove(h);
            return h;
        }

        pub fn first(self: *const Self) ?Idx {
            return if (self.head == nil) null else self.head;
        }

        pub fn nextOf(self: *const Self, i: Idx) ?Idx {
            return if (self.next[i] == nil) null else self.next[i];
        }
    };
}

test "intrusive list order, remove middle, iterate" {
    var list = IntrusiveList(8).init();
    list.pushBack(0);
    list.pushBack(1);
    list.pushBack(2);
    list.remove(1);
    // expect 0 -> 2
    var out: [4]u16 = undefined;
    var k: usize = 0;
    var cur = list.first();
    while (cur) |i| : (cur = list.nextOf(i)) {
        out[k] = i;
        k += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), k);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
    try std.testing.expectEqual(@as(u16, 2), out[1]);
    try std.testing.expectEqual(@as(usize, 2), list.count);
    try std.testing.expectEqual(@as(u16, 0), list.popFront().?);
    try std.testing.expectEqual(@as(u16, 2), list.popFront().?);
    try std.testing.expect(list.popFront() == null);
}

const testing = std.testing;

test "pool alloc/release/exhaust" {
    var p = Pool(u32, 3).init();
    try testing.expectEqual(@as(usize, 3), p.available());
    const a = p.alloc().?;
    const b = p.alloc().?;
    const c = p.alloc().?;
    try testing.expect(p.alloc() == null); // exhausted
    try testing.expectEqual(@as(usize, 3), p.liveCount());
    p.get(a).* = 111;
    p.get(b).* = 222;
    p.get(c).* = 333;
    try testing.expectEqual(@as(u32, 222), p.getConst(b).*);
    p.release(b);
    try testing.expectEqual(@as(usize, 1), p.available());
    const d = p.alloc().?; // reuses b's slot
    try testing.expectEqual(b, d);
    try testing.expect(p.alloc() == null);
}
