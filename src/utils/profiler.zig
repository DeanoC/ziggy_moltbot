const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Src = std.builtin.SourceLocation;

const is_android = builtin.os.tag == .linux and builtin.abi == .android;

const tracy_enabled = build_options.enable_ztracy and
    builtin.os.tag != .emscripten and
    (!is_android or build_options.enable_ztracy_android);

const wasm_perf_enabled = builtin.os.tag == .emscripten and build_options.enable_wasm_perf_markers;

const wasm_perf = if (wasm_perf_enabled) struct {
    extern fn zsc_perf_zone_begin(name: [*:0]const u8) u32;
    extern fn zsc_perf_zone_end(id: u32) void;
    extern fn zsc_perf_frame_mark() void;
} else struct {
    pub inline fn zsc_perf_zone_begin(_: [*:0]const u8) u32 {
        return 0;
    }
    pub inline fn zsc_perf_zone_end(_: u32) void {}
    pub inline fn zsc_perf_frame_mark() void {}
};

const ztracy = if (tracy_enabled) @import("ztracy") else struct {
    pub const ZoneCtx = struct {
        pub inline fn End(_: ZoneCtx) void {}
    };

    pub inline fn ZoneN(comptime _: anytype, _: [*:0]const u8) ZoneCtx {
        return .{};
    }

    pub inline fn FrameMark() void {}

    pub inline fn PlotF(_: [*:0]const u8, _: f64) void {}
    pub inline fn PlotU(_: [*:0]const u8, _: u64) void {}
    pub inline fn PlotI(_: [*:0]const u8, _: i64) void {}
};

pub const Zone = if (tracy_enabled) struct {
    ctx: ztracy.ZoneCtx,

    pub inline fn end(self: Zone) void {
        self.ctx.End();
    }
} else if (wasm_perf_enabled) struct {
    id: u32,

    pub inline fn end(self: Zone) void {
        wasm_perf.zsc_perf_zone_end(self.id);
    }
} else struct {
    pub inline fn end(_: Zone) void {}
};

// `@src()` must be evaluated at the call site (not inside this wrapper),
// otherwise every Tracy zone appears to come from this file.
pub inline fn zone(comptime src: Src, comptime name: [:0]const u8) Zone {
    if (tracy_enabled) {
        return .{ .ctx = ztracy.ZoneN(src, name) };
    }
    if (wasm_perf_enabled) {
        return .{ .id = wasm_perf.zsc_perf_zone_begin(name.ptr) };
    }
    return .{};
}

pub inline fn frameMark() void {
    if (tracy_enabled) {
        ztracy.FrameMark();
    } else if (wasm_perf_enabled) {
        wasm_perf.zsc_perf_frame_mark();
    }
}

pub inline fn setThreadName(comptime name: [:0]const u8) void {
    if (tracy_enabled) {
        ztracy.SetThreadName(name.ptr);
    }
}

pub inline fn plotF(comptime name: [:0]const u8, value: f64) void {
    if (tracy_enabled) {
        ztracy.PlotF(name.ptr, value);
    }
}

pub inline fn plotU(comptime name: [:0]const u8, value: u64) void {
    if (tracy_enabled) {
        ztracy.PlotU(name.ptr, value);
    }
}

pub inline fn plotI(comptime name: [:0]const u8, value: i64) void {
    if (tracy_enabled) {
        ztracy.PlotI(name.ptr, value);
    }
}
