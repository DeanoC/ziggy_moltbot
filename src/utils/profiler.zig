const builtin = @import("builtin");
const build_options = @import("build_options");

const tracy_enabled = build_options.enable_ztracy and
    builtin.os.tag != .emscripten and
    !(builtin.os.tag == .linux and builtin.abi == .android);

const ztracy = if (tracy_enabled) @import("ztracy") else struct {
    pub const ZoneCtx = struct {
        pub inline fn End(_: ZoneCtx) void {}
    };

    pub inline fn ZoneN(comptime _: anytype, _: [*:0]const u8) ZoneCtx {
        return .{};
    }

    pub inline fn FrameMark() void {}
};

pub const Zone = if (tracy_enabled) struct {
    ctx: ztracy.ZoneCtx,

    pub inline fn end(self: Zone) void {
        self.ctx.End();
    }
} else struct {
    pub inline fn end(_: Zone) void {}
};

pub inline fn zone(comptime name: [:0]const u8) Zone {
    if (tracy_enabled) {
        return .{ .ctx = ztracy.ZoneN(@src(), name) };
    }
    return .{};
}

pub inline fn frameMark() void {
    if (tracy_enabled) {
        ztracy.FrameMark();
    }
}
