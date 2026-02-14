const std = @import("std");

const Src = std.builtin.SourceLocation;

pub const Zone = struct {
    pub inline fn end(_: Zone) void {}
};

pub inline fn zone(comptime _: Src, comptime _: [:0]const u8) Zone {
    return .{};
}

pub inline fn frameMark() void {}
pub inline fn setThreadName(comptime _: [:0]const u8) void {}
pub inline fn plotF(comptime _: [:0]const u8, _: f64) void {}
pub inline fn plotU(comptime _: [:0]const u8, _: u64) void {}
pub inline fn plotI(comptime _: [:0]const u8, _: i64) void {}
