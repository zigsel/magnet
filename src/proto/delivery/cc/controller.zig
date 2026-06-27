//! The congestion-control interface (duck-typed, selected at comptime). A
//! controller exposes:
//!   window(self) usize                  - cwnd in bytes
//!   onAck(self, acked_bytes: usize)     - bytes newly acknowledged
//!   onLoss(self, now: i64, srtt_ms: i64)- a congestion event
//! Optional: snapshot()/restore() for spurious-loss recovery.
//!
//! v1 set: NewReno (default), Fixed. Cubic/BBR (fixed-point) are a follow-up
//! hardening pass; `bandwidth.zig`'s estimator is the BBR groundwork.

const std = @import("std");

pub fn validate(comptime T: type) void {
    if (!@hasDecl(T, "window")) @compileError(@typeName(T) ++ ": congestion controller missing window()");
    if (!@hasDecl(T, "onAck")) @compileError(@typeName(T) ++ ": congestion controller missing onAck()");
    if (!@hasDecl(T, "onLoss")) @compileError(@typeName(T) ++ ": congestion controller missing onLoss()");
}

test "ship controllers satisfy the interface" {
    validate(@import("reno.zig").Reno);
    validate(@import("fixed.zig").Fixed);
    validate(@import("cubic.zig").Cubic);
    validate(@import("bbr.zig").Bbr);
}
