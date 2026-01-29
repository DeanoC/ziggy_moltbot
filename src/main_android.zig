const std = @import("std");

const c = @cImport({
    @cInclude("android_native_app_glue.h");
    @cInclude("android/log.h");
});

const log_tag: [:0]const u8 = "MoltBot";

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    _ = c.__android_log_print(c.ANDROID_LOG_INFO, log_tag, "%s", msg.ptr);
}

fn handleAppCmd(app: ?*c.android_app, cmd: c_int) callconv(.C) void {
    _ = app;
    logInfo("app cmd {d}", .{cmd});
}

pub export fn android_main(app: *c.android_app) void {
    c.app_dummy();
    app.*.onAppCmd = handleAppCmd;
    logInfo("android_main started", .{});

    while (true) {
        var events: c_int = 0;
        var source: ?*c.android_poll_source = null;
        _ = c.ALooper_pollAll(-1, null, &events, @ptrCast(&source));
        if (source) |src| {
            src.process(app, src);
        }
        if (app.destroyRequested != 0) {
            break;
        }
    }

    logInfo("android_main exiting", .{});
}
