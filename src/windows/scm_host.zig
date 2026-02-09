const std = @import("std");
const builtin = @import("builtin");

const logger = @import("../utils/logger.zig");
const unified_config = @import("../unified_config.zig");
const main_node = @import("../main_node.zig");
const node_platform = @import("../node/node_platform.zig");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("winsvc.h");
});

pub const ServiceHostError = error{
    Unsupported,
    StartDispatcherFailed,
};

const Context = struct {
    allocator: std.mem.Allocator,
    service_name_utf8: []const u8,
    node_args: []const []const u8,
    service_name_w: []u16,
    stop_event: ?win.HANDLE = null,
    status_handle: ?win.SERVICE_STATUS_HANDLE = null,
    status: win.SERVICE_STATUS = std.mem.zeroes(win.SERVICE_STATUS),
};

var g_ctx: ?*Context = null;

fn utf16Z(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    const tmp = try std.unicode.utf8ToUtf16LeAlloc(allocator, s);
    defer allocator.free(tmp);
    var out = try allocator.alloc(u16, tmp.len + 1);
    @memcpy(out[0..tmp.len], tmp);
    out[tmp.len] = 0;
    return out;
}

fn setState(ctx: *Context, state: u32, win32_exit_code: u32) void {
    ctx.status.dwServiceType = win.SERVICE_WIN32_OWN_PROCESS;
    ctx.status.dwCurrentState = state;
    ctx.status.dwControlsAccepted = if (state == win.SERVICE_RUNNING)
        (win.SERVICE_ACCEPT_STOP | win.SERVICE_ACCEPT_SHUTDOWN)
    else
        0;
    ctx.status.dwWin32ExitCode = win32_exit_code;
    ctx.status.dwServiceSpecificExitCode = 0;
    ctx.status.dwCheckPoint = 0;
    ctx.status.dwWaitHint = 0;

    if (ctx.status_handle) |h| {
        _ = win.SetServiceStatus(h, &ctx.status);
    }
}

fn serviceCtrlHandler(
    control: u32,
    _event_type: u32,
    _event_data: ?*anyopaque,
    _context: ?*anyopaque,
) callconv(.c) u32 {
    _ = _event_type;
    _ = _event_data;
    _ = _context;

    const ctx = g_ctx orelse return 0;

    switch (control) {
        win.SERVICE_CONTROL_STOP, win.SERVICE_CONTROL_SHUTDOWN => {
            logger.info("Windows service stop requested", .{});
            setState(ctx, win.SERVICE_STOP_PENDING, 0);
            node_platform.requestStop();
            if (ctx.stop_event) |ev| _ = win.SetEvent(ev);
            return 0;
        },
        else => return 0,
    }
}

fn serviceMain(_argc: u32, _argv: [*c][*c]u16) callconv(.c) void {
    _ = _argc;
    _ = _argv;

    const ctx = g_ctx orelse return;

    ctx.status_handle = win.RegisterServiceCtrlHandlerExW(ctx.service_name_w.ptr, serviceCtrlHandler, null);
    if (ctx.status_handle == null) return;

    setState(ctx, win.SERVICE_START_PENDING, 0);

    ctx.stop_event = win.CreateEventW(null, win.TRUE, win.FALSE, null);
    if (ctx.stop_event == null) {
        setState(ctx, win.SERVICE_STOPPED, 1);
        return;
    }

    // Initialize log file to a deterministic location (next to the unified config).
    // This is best-effort; service can still run without it.
    const node_opts = main_node.parseNodeOptions(ctx.allocator, ctx.node_args) catch |err| {
        logger.err("Service: failed to parse node args: {s}", .{@errorName(err)});
        setState(ctx, win.SERVICE_STOPPED, 2);
        return;
    };

    const config_path = node_opts.config_path orelse unified_config.defaultConfigPath(ctx.allocator) catch null;
    if (config_path) |cp| {
        defer if (node_opts.config_path == null) ctx.allocator.free(cp);

        const cfg_dir = std.fs.path.dirname(cp) orelse ".";
        const logs_dir = std.fs.path.join(ctx.allocator, &.{ cfg_dir, "logs" }) catch null;
        if (logs_dir) |ld| {
            defer ctx.allocator.free(ld);
            std.fs.cwd().makePath(ld) catch {};
            const log_path = std.fs.path.join(ctx.allocator, &.{ ld, "node.log" }) catch null;
            if (log_path) |lp| {
                defer ctx.allocator.free(lp);
                logger.initFile(lp) catch {};
            }
        }
    }

    logger.info("Windows SCM service starting node-mode", .{});
    setState(ctx, win.SERVICE_RUNNING, 0);

    // Run node-mode synchronously; it will exit when stopRequested becomes true.
    main_node.runNodeMode(ctx.allocator, node_opts) catch |err| {
        logger.err("node-mode exited with error: {s}", .{@errorName(err)});
        // Mark stopped with a generic non-zero exit code.
        setState(ctx, win.SERVICE_STOPPED, 1);
        return;
    };

    setState(ctx, win.SERVICE_STOPPED, 0);
}

pub fn runWindowsService(
    allocator: std.mem.Allocator,
    service_name_utf8: []const u8,
    node_args: []const []const u8,
) ServiceHostError!void {
    if (builtin.os.tag != .windows) return ServiceHostError.Unsupported;

    var ctx = try allocator.create(Context);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .allocator = allocator,
        .service_name_utf8 = service_name_utf8,
        .node_args = node_args,
        .service_name_w = try utf16Z(allocator, service_name_utf8),
    };
    errdefer allocator.free(ctx.service_name_w);

    g_ctx = ctx;
    defer g_ctx = null;

    var table: [2]win.SERVICE_TABLE_ENTRYW = .{
        .{ .lpServiceName = ctx.service_name_w.ptr, .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (win.StartServiceCtrlDispatcherW(&table) == 0) {
        // Common failure when invoked from an interactive console:
        // ERROR_FAILED_SERVICE_CONTROLLER_CONNECT (1063)
        return ServiceHostError.StartDispatcherFailed;
    }

    if (ctx.stop_event) |ev| _ = win.CloseHandle(ev);
    allocator.free(ctx.service_name_w);
    allocator.destroy(ctx);
}
