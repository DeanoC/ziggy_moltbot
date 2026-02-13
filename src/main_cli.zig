const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const logger = ziggy.utils.logger;
const build_options = @import("build_options");
const cli_features = @import("cli/features.zig");
const markdown_help = @import("cli/markdown_help.zig");
const node_only_chunk = @import("cli/node_only_chunk.zig");
const operator_chunk = if (cli_features.supports_operator_client)
    @import("cli/operator_chunk.zig")
else
    struct {};
const main_operator = if (cli_features.supports_operator_client)
    @import("main_operator.zig")
else
    struct {
        pub const usage =
            "ZiggyStarClaw Operator Mode\n\n" ++
            "This CLI build was compiled without operator capabilities.\n" ++
            "Rebuild with -Dcli_operator=true to enable operator-mode.\n";

        pub const OperatorOptionsUnavailable = struct {};

        pub fn parseOperatorOptions(_: std.mem.Allocator, _: []const []const u8) !OperatorOptionsUnavailable {
            return error.Unsupported;
        }

        pub fn runOperatorMode(_: std.mem.Allocator, _: OperatorOptionsUnavailable) !void {
            return error.Unsupported;
        }
    };
// Node mode support is cross-platform (Windows included).
const main_node = @import("main_node.zig");
const win_service = @import("windows/service.zig");
const win_scm = if (builtin.os.tag == .windows) @import("windows/scm_service.zig") else struct {};
const win_scm_host = if (builtin.os.tag == .windows) @import("windows/scm_host.zig") else struct {};
const win_control_pipe = if (builtin.os.tag == .windows) @import("windows/control_pipe_client.zig") else struct {};
const win_console_window = if (builtin.os.tag == .windows) @import("windows/console_window.zig") else struct {};
const linux_service = @import("linux/systemd_service.zig");
const node_register = @import("node_register.zig");
const unified_config = @import("unified_config.zig");
const winamp_import = @import("ui/theme_engine/winamp_import.zig");

pub const std_options = std.Options{
    .logFn = cliLogFn,
    .log_level = .debug,
};

const supervisor_pipe = if (builtin.os.tag == .windows)
    @import("windows/supervisor_pipe.zig")
else
    struct {};

const win_single_instance = if (builtin.os.tag == .windows)
    @import("windows/single_instance.zig")
else
    struct {};

fn linuxHomeDirForUser(allocator: std.mem.Allocator, username: []const u8) ![]u8 {
    // Minimal /etc/passwd parser to find a user's home directory.
    // Format: name:passwd:uid:gid:gecos:home:shell
    const f = std.fs.cwd().openFile("/etc/passwd", .{}) catch |err| return err;
    defer f.close();

    const data = try f.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        // Fast check for "username:"
        if (line.len <= username.len or line[username.len] != ':' or !std.mem.startsWith(u8, line, username)) continue;

        var fields = std.mem.splitScalar(u8, line, ':');
        _ = fields.next(); // name
        _ = fields.next(); // passwd
        _ = fields.next(); // uid
        _ = fields.next(); // gid
        _ = fields.next(); // gecos
        const home = fields.next() orelse return error.InvalidArguments;
        if (home.len == 0) return error.InvalidArguments;
        return allocator.dupe(u8, home);
    }

    return error.FileNotFound;
}

fn resolveSiblingExecutablePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    const dir = std.fs.path.dirname(self_exe) orelse ".";
    const candidate = try std.fs.path.join(allocator, &.{ dir, name });

    std.fs.cwd().access(candidate, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(candidate);
            return allocator.dupe(u8, name);
        },
        else => {
            allocator.free(candidate);
            return err;
        },
    };

    return candidate;
}

fn runSelfCliCommand(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, self_exe);
    try argv.appendSlice(allocator, sub_args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }

    try child.spawn();
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    if (code != 0) return error.CommandFailed;
}

const SelfCliCommandResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *SelfCliCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runSelfCliCommandCapture(allocator: std.mem.Allocator, sub_args: []const []const u8) !SelfCliCommandResult {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, self_exe);
    try argv.appendSlice(allocator, sub_args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }

    try child.spawn();
    errdefer _ = child.kill() catch {};

    var stdout_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8).empty;
    defer stderr_buf.deinit(allocator);
    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 256 * 1024);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return .{
        .exit_code = code,
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
    };
}

fn writeCapturedOutput(result: *const SelfCliCommandResult) void {
    if (result.stdout.len > 0) {
        _ = std.fs.File.stdout().write(result.stdout) catch {};
    }
    if (result.stderr.len > 0) {
        _ = std.fs.File.stderr().write(result.stderr) catch {};
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn outputSuggestsAccessDenied(buf: []const u8) bool {
    return containsIgnoreCase(buf, "access denied") or
        containsIgnoreCase(buf, "requires elevation") or
        containsIgnoreCase(buf, "elevation required") or
        containsIgnoreCase(buf, "error_access_denied");
}

fn appendPowershellSingleQuoted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

fn runSelfCliCommandElevatedWindows(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    var quoted_exe = std.ArrayList(u8).empty;
    defer quoted_exe.deinit(allocator);
    try appendPowershellSingleQuoted(allocator, &quoted_exe, self_exe);

    var quoted_args = std.ArrayList(u8).empty;
    defer quoted_args.deinit(allocator);
    var first_arg = true;
    for (sub_args) |arg| {
        // PowerShell Start-Process rejects null/empty elements in -ArgumentList.
        // Skip empty entries when elevating; profile apply already persists config before this path.
        if (arg.len == 0) continue;
        if (!first_arg) try quoted_args.append(allocator, ',');
        try appendPowershellSingleQuoted(allocator, &quoted_args, arg);
        first_arg = false;
    }

    const script = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; $p = Start-Process -FilePath {s} -ArgumentList @({s}) -Verb RunAs -Wait -PassThru; exit $p.ExitCode",
        .{ quoted_exe.items, quoted_args.items },
    );
    defer allocator.free(script);

    const argv = &[_][]const u8{
        "powershell",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.create_no_window = true;
    try child.spawn();

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    if (code != 0) return error.CommandFailed;
}

fn runSelfCliCommandWithWindowsElevationFallback(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var result = try runSelfCliCommandCapture(allocator, sub_args);
    defer result.deinit(allocator);

    writeCapturedOutput(&result);
    if (result.exit_code == 0) return;

    if (builtin.os.tag == .windows and
        (outputSuggestsAccessDenied(result.stderr) or outputSuggestsAccessDenied(result.stdout)))
    {
        logger.warn("Command needs elevation; re-running with UAC prompt.", .{});
        try runSelfCliCommandElevatedWindows(allocator, sub_args);
        return;
    }

    return error.CommandFailed;
}

fn appendProfileCommonArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    config_path_set: bool,
    config_path: []const u8,
    override_url: ?[]const u8,
    override_token: ?[]const u8,
    override_insecure: ?bool,
    node_service_name: ?[]const u8,
) !void {
    if (config_path_set) {
        try argv.append(allocator, "--config");
        try argv.append(allocator, config_path);
    }
    if (override_url) |url| {
        if (url.len > 0) {
            try argv.append(allocator, "--url");
            try argv.append(allocator, url);
        }
    }
    if (override_token) |tok| {
        if (tok.len > 0) {
            try argv.append(allocator, "--gateway-token");
            try argv.append(allocator, tok);
        }
    }
    if (override_insecure orelse false) {
        try argv.append(allocator, "--insecure-tls");
    }
    if (node_service_name) |name| {
        try argv.append(allocator, "--node-service-name");
        try argv.append(allocator, name);
    }
}

const tray_startup_task_name = "ZiggyStarClaw Tray";

fn installTrayStartup(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    const tray_exe = try resolveSiblingExecutablePath(allocator, "ziggystarclaw-tray.exe");
    defer allocator.free(tray_exe);

    const task_run = try std.fmt.allocPrint(allocator, "\"{s}\"", .{tray_exe});
    defer allocator.free(task_run);

    win_service.installTaskCommand(allocator, task_run, .onlogon, tray_startup_task_name) catch |err| switch (err) {
        win_service.ServiceError.AccessDenied => return error.AccessDenied,
        else => return err,
    };
}

fn uninstallTrayStartup(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = win_service.stopTask(allocator, tray_startup_task_name) catch {};
    win_service.uninstallTask(allocator, tray_startup_task_name) catch |err| switch (err) {
        win_service.ServiceError.AccessDenied => return error.AccessDenied,
        else => return err,
    };
}

fn startTrayStartupTask(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    win_service.startTask(allocator, tray_startup_task_name) catch |err| switch (err) {
        win_service.ServiceError.AccessDenied => return error.AccessDenied,
        win_service.ServiceError.NotInstalled => return error.NotInstalled,
        else => return err,
    };
}

fn stopTrayStartupTask(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    win_service.stopTask(allocator, tray_startup_task_name) catch |err| switch (err) {
        win_service.ServiceError.AccessDenied => return error.AccessDenied,
        win_service.ServiceError.NotInstalled => return error.NotInstalled,
        else => return err,
    };
}

fn trayStartupInstalled(allocator: std.mem.Allocator) !bool {
    if (builtin.os.tag != .windows) return false;
    return win_service.taskInstalled(allocator, tray_startup_task_name) catch |err| switch (err) {
        win_service.ServiceError.AccessDenied => return error.AccessDenied,
        else => false,
    };
}

fn runNodeSupervisor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Windows-only: legacy headless supervisor (used by the older Task Scheduler service MVP).
    // Keeps a named-pipe control channel so the tray app can query status and request
    // start/stop/restart even when running headless.
    if (builtin.os.tag != .windows) return error.Unsupported;

    const hide_console = blk: {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--hide-console")) break :blk true;
        }
        break :blk false;
    };
    if (hide_console) {
        win_console_window.hideIfPresent();
    }

    var shared = supervisor_pipe.Shared{};
    supervisor_pipe.spawnServerThread(allocator, &shared) catch {};

    // Parse node options for the child process.
    var opts = try main_node.parseNodeOptions(allocator, args);
    if (opts.as_node == null) opts.as_node = true;
    if (opts.as_operator == null) opts.as_operator = false;

    // Determine config path so we can place logs next to it.
    var cfg_path_owned: ?[]u8 = null;
    const cfg_path: []const u8 = if (opts.config_path) |p| p else blk: {
        const p = try unified_config.defaultConfigPath(allocator);
        cfg_path_owned = @constCast(p);
        break :blk p;
    };
    defer if (cfg_path_owned) |p| allocator.free(p);

    const cfg_dir = std.fs.path.dirname(cfg_path) orelse ".";
    const logs_dir = try std.fs.path.join(allocator, &.{ cfg_dir, "logs" });
    defer allocator.free(logs_dir);
    std.fs.cwd().makePath(logs_dir) catch {};

    const node_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "node.log" });
    defer allocator.free(node_log_path);
    const wrapper_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "wrapper.log" });
    defer allocator.free(wrapper_log_path);

    _ = std.fs.cwd().createFile(node_log_path, .{ .truncate = false }) catch {};
    var wrapper_file = try std.fs.cwd().createFile(wrapper_log_path, .{ .truncate = false });
    defer wrapper_file.close();
    try wrapper_file.seekFromEnd(0);
    var wrap = wrapper_file.deprecatedWriter();

    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    const owner_pid: u32 = std.os.windows.GetCurrentProcessId();

    // Guard against duplicate runner/service owners at startup.
    const mutex = win_single_instance.acquireNodeOwnerMutex(allocator) catch |err| {
        wrap.print(
            "{d} [wrapper] single_instance_error mode=runner pid={d} err={s}\n",
            .{ std.time.timestamp(), owner_pid, @errorName(err) },
        ) catch {};
        return err;
    };
    const owns_single_instance = !mutex.already_running;

    // Keep handle open for the lifetime of this process.
    defer {
        if (owns_single_instance) {
            wrap.print(
                "{d} [wrapper] single_instance_owner_released mode=runner pid={d} lock={s}\n",
                .{ std.time.timestamp(), owner_pid, mutex.name_used_utf8 },
            ) catch {};
        }
        std.os.windows.CloseHandle(mutex.handle);
    }

    if (mutex.already_running) {
        wrap.print(
            "{d} [wrapper] single_instance_denied_existing_owner mode=runner pid={d} lock={s}\n",
            .{ std.time.timestamp(), owner_pid, mutex.name_used_utf8 },
        ) catch {};

        var stderr_buf: [256]u8 = undefined;
        const stderr_line = std.fmt.bufPrint(
            &stderr_buf,
            "node supervise blocked: another node owner already holds {s}\n",
            .{mutex.name_used_utf8},
        ) catch "node supervise blocked: another node owner already running\n";
        std.fs.File.stderr().writeAll(stderr_line) catch {};
        return;
    }

    wrap.print(
        "{d} [wrapper] single_instance_acquired mode=runner pid={d} lock={s}\n",
        .{ std.time.timestamp(), owner_pid, mutex.name_used_utf8 },
    ) catch {};

    if (std.mem.startsWith(u8, mutex.name_used_utf8, "Local\\")) {
        wrap.print(
            "{d} [wrapper] single_instance_scope_local mode=runner pid={d} lock={s}\n",
            .{ std.time.timestamp(), owner_pid, mutex.name_used_utf8 },
        ) catch {};
    }

    wrap.print(
        "{d} [wrapper] supervisor starting; config={s}; node_log={s}; pipe={s}\n",
        .{ std.time.timestamp(), cfg_path, node_log_path, supervisor_pipe.pipe_name_utf8 },
    ) catch {};

    const diag_enabled = (opts.log_level == .debug);

    // Periodically report pipe diagnostics (debug only).
    var last_diag_ms: i64 = 0;

    var child: ?std.process.Child = null;
    defer if (child) |*c| {
        if (c.kill()) |_| {} else |_| {}
        _ = c.wait() catch {};
    };

    while (true) {
        // Snapshot desired state.
        shared.mutex.lock();
        const want = shared.desired_running;
        const do_restart = shared.restart_requested;
        shared.restart_requested = false;
        shared.mutex.unlock();

        if (do_restart and child != null) {
            wrap.print("{d} [wrapper] restart requested\n", .{std.time.timestamp()}) catch {};
            if (child.?.kill()) |_| {} else |_| {}
            _ = child.?.wait() catch {};
            child = null;
        }

        if (!want and child != null) {
            wrap.print("{d} [wrapper] stop requested\n", .{std.time.timestamp()}) catch {};
            if (child.?.kill()) |_| {} else |_| {}
            _ = child.?.wait() catch {};
            child = null;
        }

        if (want and child == null) {
            // Spawn node-mode as a child process so the supervisor can remain responsive.
            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);
            try argv.append(allocator, self_exe);
            try argv.append(allocator, "--node-mode");
            try argv.append(allocator, "--config");
            try argv.append(allocator, cfg_path);
            try argv.append(allocator, "--as-node");
            try argv.append(allocator, "--no-operator");
            try argv.append(allocator, "--log-level");
            try argv.append(allocator, @tagName(opts.log_level));

            var c = std.process.Child.init(argv.items, allocator);
            c.stdin_behavior = .Ignore;
            c.stdout_behavior = .Ignore;
            c.stderr_behavior = .Ignore;
            c.create_no_window = true;

            var env = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
            defer env.deinit();
            env.put("MOLT_LOG_FILE", node_log_path) catch {};
            env.put("MOLT_LOG_LEVEL", @tagName(opts.log_level)) catch {};
            c.env_map = &env;

            wrap.print("{d} [wrapper] launching node-mode child\n", .{std.time.timestamp()}) catch {};
            c.spawn() catch |err| {
                wrap.print("{d} [wrapper] spawn failed: {s}\n", .{ std.time.timestamp(), @errorName(err) }) catch {};
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            child = c;
        }

        // Update running state.
        if (child) |*c| {
            const code_opt = supervisor_pipe.getExitCode(c.id);
            if (code_opt) |code| {
                if (supervisor_pipe.isStillActive(code)) {
                    const pid = supervisor_pipe.getPid(c.id);
                    shared.mutex.lock();
                    shared.is_running = true;
                    shared.pid = pid;
                    shared.mutex.unlock();
                } else {
                    shared.mutex.lock();
                    shared.is_running = false;
                    shared.pid = 0;
                    shared.mutex.unlock();
                    wrap.print("{d} [wrapper] child exited code={d}\n", .{ std.time.timestamp(), code }) catch {};
                    _ = c.wait() catch {};
                    child = null;
                }
            }
        } else {
            shared.mutex.lock();
            shared.is_running = false;
            shared.pid = 0;
            shared.mutex.unlock();
        }

        const now_ms = std.time.milliTimestamp();
        if (diag_enabled and now_ms - last_diag_ms > 10_000) {
            shared.mutex.lock();
            const creates = shared.pipe_creates;
            const create_fails = shared.pipe_create_fails;
            const last_create_err = shared.pipe_last_create_err;
            const last_connect_err = shared.pipe_last_connect_err;
            const accepts = shared.pipe_accepts;
            const timeouts = shared.pipe_timeouts;
            const reqs = shared.pipe_requests;
            shared.mutex.unlock();
            wrap.print(
                "{d} [wrapper] pipe stats: creates={d} create_fails={d} last_create_err={d} last_connect_err={d} accepts={d} reqs={d} timeouts={d}\n",
                .{ std.time.timestamp(), creates, create_fails, last_create_err, last_connect_err, accepts, reqs, timeouts },
            ) catch {};
            last_diag_ms = now_ms;
        }

        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
}

var cli_log_level: std.log.Level = .warn;

const usage_overview = if (cli_features.supports_operator_client)
    @embedFile("cli/docs/01-overview.md")
else
    @embedFile("cli/docs/01-overview-node-only.md");

const usage_options = if (cli_features.supports_operator_client)
    @embedFile("cli/docs/02-options.md")
else
    @embedFile("cli/docs/02-options-node-only.md");

const usage_global_flags = if (cli_features.supports_operator_client)
    @embedFile("cli/docs/06-global-flags.md")
else
    @embedFile("cli/docs/06-global-flags-node-only.md");

const usage_tail =
    @embedFile("cli/docs/03-node-runner.md") ++ "\n" ++
    @embedFile("cli/docs/04-tray-startup.md") ++ "\n" ++
    @embedFile("cli/docs/05-node-service.md") ++ "\n" ++
    usage_global_flags;

const usage = usage_overview ++ "\n" ++ usage_options ++ "\n" ++ usage_tail;

fn writeHelpText(allocator: std.mem.Allocator, text: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try markdown_help.writeMarkdownForStdout(stdout, allocator, text);
}

fn failRemovedLegacyFlag(flag: []const u8, replacement: []const u8) error{InvalidArguments}!void {
    logger.err("Flag {s} was removed. Use `{s}`.", .{ flag, replacement });
    return error.InvalidArguments;
}

fn failRemovedLegacyCommand(command: []const u8, replacement: []const u8) error{InvalidArguments}!void {
    logger.err("Command `{s}` was removed. Use `{s}`.", .{ command, replacement });
    return error.InvalidArguments;
}
const ReplCommand = enum {
    help,
    send,
    session,
    sessions,
    node,
    nodes,
    run,
    which,
    notify,
    ps,
    spawn,
    poll,
    stop,
    canvas,
    approvals,
    approve,
    deny,
    quit,
    exit,
    save,
    unknown,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try initLogging(allocator);
    defer logger.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: []const u8 = "ziggystarclaw_config.json";
    var config_path_set = false;
    var override_url: ?[]const u8 = null;
    var override_token: ?[]const u8 = null;
    var override_token_set = false;
    var override_update_url: ?[]const u8 = null;
    var override_insecure: ?bool = null;
    var read_timeout_ms: u32 = 15_000;
    var send_message: ?[]const u8 = null;
    var session_key: ?[]const u8 = null;
    var list_sessions = false;
    var use_session: ?[]const u8 = null;
    var list_nodes = false;
    var node_id: ?[]const u8 = null;
    var use_node: ?[]const u8 = null;
    var run_command: ?[]const u8 = null;
    var which_name: ?[]const u8 = null;
    var notify_title: ?[]const u8 = null;
    var ps_list = false;
    var spawn_command: ?[]const u8 = null;
    var poll_process_id: ?[]const u8 = null;
    var stop_process_id: ?[]const u8 = null;
    var canvas_present = false;
    var canvas_hide = false;
    var canvas_navigate: ?[]const u8 = null;
    var canvas_eval: ?[]const u8 = null;
    var canvas_snapshot: ?[]const u8 = null;
    var exec_approvals_get = false;
    var exec_allow_cmd: ?[]const u8 = null;
    var exec_allow_file: ?[]const u8 = null;
    var list_approvals = false;
    var approve_id: ?[]const u8 = null;
    var deny_id: ?[]const u8 = null;
    var device_pair_list = false;
    var device_pair_approve_id: ?[]const u8 = null;
    var device_pair_reject_id: ?[]const u8 = null;
    var device_pair_watch = false;
    var check_update_only = false;
    var print_update_url = false;
    var interactive = false;
    var node_register_mode = false;
    var node_register_wait = false;
    var extract_wsz: ?[]const u8 = null;
    var extract_dest: ?[]const u8 = null;

    // Node service helpers
    var node_service_install = false;
    var node_service_uninstall = false;
    var node_service_start = false;
    var node_service_stop = false;
    var node_service_status = false;
    var node_service_mode: win_service.InstallMode = if (builtin.os.tag == .windows) .onstart else .onlogon;
    var node_service_name: ?[]const u8 = null;

    // Windows-only: user-session runner (Scheduled Task / wrapper)
    var node_session_install = false;
    var node_session_uninstall = false;
    var node_session_start = false;
    var node_session_stop = false;
    var node_session_status = false;

    const RunnerInstallMode = enum { service, session };
    var node_runner_install = false;
    var node_runner_start = false;
    var node_runner_stop = false;
    var node_runner_status = false;
    var node_runner_mode: ?RunnerInstallMode = null;

    const ProfileInstallMode = enum { client, service, session };
    var node_profile_apply = false;
    var node_profile_mode: ?ProfileInstallMode = null;

    var tray_install_startup = false;
    var tray_uninstall_startup = false;
    var tray_start_startup = false;
    var tray_stop_startup = false;
    var tray_status_startup = false;

    // Internal: when invoked by Windows Service Control Manager (SCM).
    var windows_service_run = false;
    // Pre-scan for mode flags so we can delegate argument parsing cleanly.
    var node_mode = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--node-mode")) node_mode = true;
        if (std.mem.eql(u8, a, "--node-register")) node_register_mode = true;
        if (std.mem.eql(u8, a, "--wait-for-approval")) node_register_wait = true;
        if (std.mem.eql(u8, a, "--windows-service")) windows_service_run = true;
    }
    var save_config = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help-legacy")) {
            try failRemovedLegacyFlag("--help-legacy", "--help");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeHelpText(allocator, usage);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.print("ziggystarclaw-cli {s}+{s}\n", .{ build_options.app_version, build_options.git_rev });
            return;
        } else if (std.mem.eql(u8, arg, "node") or std.mem.eql(u8, arg, "nodes")) {
            // Modern noun-verb command surface (OpenClaw-style where possible):
            //   ziggystarclaw node list
            //   ziggystarclaw node run "uname -a"
            //   ziggystarclaw node process spawn "sleep 10"
            //   ziggystarclaw node canvas navigate "https://example.com"
            //   ziggystarclaw node service install
            if (i + 1 >= args.len) return error.InvalidArguments;
            const noun = args[i + 1];

            if (std.mem.eql(u8, noun, "list")) {
                list_nodes = true;
                i += 1;
                continue;
            }

            if (std.mem.eql(u8, noun, "use")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                use_node = args[i + 2];
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "run")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                run_command = args[i + 2];
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "which")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                which_name = args[i + 2];
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "notify")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                notify_title = args[i + 2];
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "ps")) {
                ps_list = true;
                i += 1;
                continue;
            }

            if (std.mem.eql(u8, noun, "process")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "list")) {
                    ps_list = true;
                    i += 2;
                    continue;
                } else if (std.mem.eql(u8, action, "spawn")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    spawn_command = args[i + 3];
                    i += 3;
                    continue;
                } else if (std.mem.eql(u8, action, "poll")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    poll_process_id = args[i + 3];
                    i += 3;
                    continue;
                } else if (std.mem.eql(u8, action, "stop")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    stop_process_id = args[i + 3];
                    i += 3;
                    continue;
                }

                logger.err("Unknown node process action: {s}", .{action});
                return error.InvalidArguments;
            }

            if (std.mem.eql(u8, noun, "canvas")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "present")) {
                    canvas_present = true;
                    i += 2;
                    continue;
                } else if (std.mem.eql(u8, action, "hide")) {
                    canvas_hide = true;
                    i += 2;
                    continue;
                } else if (std.mem.eql(u8, action, "navigate")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    canvas_navigate = args[i + 3];
                    i += 3;
                    continue;
                } else if (std.mem.eql(u8, action, "eval")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    canvas_eval = args[i + 3];
                    i += 3;
                    continue;
                } else if (std.mem.eql(u8, action, "snapshot")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    canvas_snapshot = args[i + 3];
                    i += 3;
                    continue;
                }

                logger.err("Unknown node canvas action: {s}", .{action});
                return error.InvalidArguments;
            }

            if (std.mem.eql(u8, noun, "approvals")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "get")) {
                    exec_approvals_get = true;
                    i += 2;
                    continue;
                } else if (std.mem.eql(u8, action, "allow")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    exec_allow_cmd = args[i + 3];
                    i += 3;
                    continue;
                } else if (std.mem.eql(u8, action, "allow-file")) {
                    if (i + 3 >= args.len) return error.InvalidArguments;
                    exec_allow_file = args[i + 3];
                    i += 3;
                    continue;
                }

                logger.err("Unknown node approvals action: {s}", .{action});
                return error.InvalidArguments;
            }

            if (std.mem.eql(u8, noun, "supervise")) {
                // Legacy headless supervisor (used by the older Task Scheduler runner MVP).
                try runNodeSupervisor(allocator, args[(i + 2)..]);
                return;
            }

            if (std.mem.eql(u8, noun, "session")) {
                if (i + 2 >= args.len) {
                    try writeHelpText(allocator, usage);
                    return;
                }
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "install")) {
                    node_session_install = true;
                } else if (std.mem.eql(u8, action, "uninstall")) {
                    node_session_uninstall = true;
                } else if (std.mem.eql(u8, action, "start")) {
                    node_session_start = true;
                } else if (std.mem.eql(u8, action, "stop")) {
                    node_session_stop = true;
                } else if (std.mem.eql(u8, action, "status")) {
                    node_session_status = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    try writeHelpText(allocator, usage);
                    return;
                } else {
                    logger.err("Unknown node session action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "node session <action>".
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "runner")) {
                if (i + 2 >= args.len) {
                    try writeHelpText(allocator, usage);
                    return;
                }
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "install")) {
                    node_runner_install = true;
                } else if (std.mem.eql(u8, action, "start")) {
                    node_runner_start = true;
                } else if (std.mem.eql(u8, action, "stop")) {
                    node_runner_stop = true;
                } else if (std.mem.eql(u8, action, "status")) {
                    node_runner_status = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    try writeHelpText(allocator, usage);
                    return;
                } else {
                    logger.err("Unknown node runner action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "node runner <action>".
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "profile")) {
                if (i + 2 >= args.len) {
                    try writeHelpText(allocator, usage);
                    return;
                }
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "apply")) {
                    node_profile_apply = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    try writeHelpText(allocator, usage);
                    return;
                } else {
                    logger.err("Unknown node profile action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "node profile <action>".
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun, "service")) {
                if (i + 2 >= args.len) {
                    try writeHelpText(allocator, usage);
                    return;
                }
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "install")) {
                    node_service_install = true;
                } else if (std.mem.eql(u8, action, "uninstall")) {
                    node_service_uninstall = true;
                } else if (std.mem.eql(u8, action, "start")) {
                    node_service_start = true;
                } else if (std.mem.eql(u8, action, "stop")) {
                    node_service_stop = true;
                } else if (std.mem.eql(u8, action, "status")) {
                    node_service_status = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    try writeHelpText(allocator, usage);
                    return;
                } else {
                    logger.err("Unknown node service action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "node service <action>".
                i += 2;
                continue;
            }

            logger.err("Unknown subcommand: {s} {s}", .{ arg, noun });
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "session") or std.mem.eql(u8, arg, "sessions")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            const action = args[i + 1];
            if (std.mem.eql(u8, action, "list")) {
                list_sessions = true;
                i += 1;
                continue;
            } else if (std.mem.eql(u8, action, "use")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                use_session = args[i + 2];
                i += 2;
                continue;
            }

            logger.err("Unknown session action: {s}", .{action});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "chat") or std.mem.eql(u8, arg, "message") or std.mem.eql(u8, arg, "messages")) {
            if (i + 2 >= args.len) return error.InvalidArguments;
            const action = args[i + 1];
            if (!std.mem.eql(u8, action, "send")) {
                logger.err("Unknown message action: {s}", .{action});
                return error.InvalidArguments;
            }
            send_message = args[i + 2];
            i += 2;
            continue;
        } else if (std.mem.eql(u8, arg, "approvals") or std.mem.eql(u8, arg, "approval")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            const action = args[i + 1];
            if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "pending")) {
                list_approvals = true;
                i += 1;
                continue;
            } else if (std.mem.eql(u8, action, "approve")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                approve_id = args[i + 2];
                i += 2;
                continue;
            } else if (std.mem.eql(u8, action, "deny") or std.mem.eql(u8, action, "reject")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                deny_id = args[i + 2];
                i += 2;
                continue;
            }

            logger.err("Unknown approvals action: {s}", .{action});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "device") or std.mem.eql(u8, arg, "devices")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            const action = args[i + 1];
            if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "pending")) {
                device_pair_list = true;
                i += 1;
                continue;
            } else if (std.mem.eql(u8, action, "watch")) {
                device_pair_watch = true;
                i += 1;
                continue;
            } else if (std.mem.eql(u8, action, "approve")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                device_pair_approve_id = args[i + 2];
                i += 2;
                continue;
            } else if (std.mem.eql(u8, action, "deny") or std.mem.eql(u8, action, "reject")) {
                if (i + 2 >= args.len) return error.InvalidArguments;
                device_pair_reject_id = args[i + 2];
                i += 2;
                continue;
            }

            logger.err("Unknown device action: {s}", .{action});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "tray")) {
            if (i + 1 >= args.len) {
                try writeHelpText(allocator, usage);
                return;
            }

            const noun_or_action = args[i + 1];
            if (std.mem.eql(u8, noun_or_action, "startup")) {
                if (i + 2 >= args.len) {
                    try writeHelpText(allocator, usage);
                    return;
                }

                const action = args[i + 2];
                if (std.mem.eql(u8, action, "install")) {
                    tray_install_startup = true;
                } else if (std.mem.eql(u8, action, "uninstall")) {
                    tray_uninstall_startup = true;
                } else if (std.mem.eql(u8, action, "start")) {
                    tray_start_startup = true;
                } else if (std.mem.eql(u8, action, "stop")) {
                    tray_stop_startup = true;
                } else if (std.mem.eql(u8, action, "status")) {
                    tray_status_startup = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    try writeHelpText(allocator, usage);
                    return;
                } else {
                    logger.err("Unknown tray startup action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "tray startup <action>".
                i += 2;
                continue;
            }

            if (std.mem.eql(u8, noun_or_action, "help") or std.mem.eql(u8, noun_or_action, "--help") or std.mem.eql(u8, noun_or_action, "-h")) {
                try writeHelpText(allocator, usage);
                return;
            }

            if (std.mem.eql(u8, noun_or_action, "install-startup")) {
                try failRemovedLegacyCommand("tray install-startup", "tray startup install");
            } else if (std.mem.eql(u8, noun_or_action, "uninstall-startup")) {
                try failRemovedLegacyCommand("tray uninstall-startup", "tray startup uninstall");
            } else if (std.mem.eql(u8, noun_or_action, "start")) {
                try failRemovedLegacyCommand("tray start", "tray startup start");
            } else if (std.mem.eql(u8, noun_or_action, "stop")) {
                try failRemovedLegacyCommand("tray stop", "tray startup stop");
            } else if (std.mem.eql(u8, noun_or_action, "status")) {
                try failRemovedLegacyCommand("tray status", "tray startup status");
            }

            logger.err("Unknown tray subcommand: {s}", .{noun_or_action});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config_path = args[i];
            config_path_set = true;
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_url = if (args[i].len > 0) args[i] else null;
        } else if (std.mem.eql(u8, arg, "--token") or std.mem.eql(u8, arg, "--auth-token") or std.mem.eql(u8, arg, "--auth_token") or std.mem.eql(u8, arg, "--gateway-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_token = args[i];
            override_token_set = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            if (parseLogLevel(args[i])) |level| {
                logger.setLevel(level);
                cli_log_level = toStdLogLevel(level);
            } else {
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--update-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            override_update_url = args[i];
        } else if (std.mem.eql(u8, arg, "--print-update-url")) {
            print_update_url = true;
        } else if (std.mem.eql(u8, arg, "--insecure-tls") or std.mem.eql(u8, arg, "--insecure")) {
            override_insecure = true;
        } else if (std.mem.eql(u8, arg, "--read-timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            read_timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--send")) {
            try failRemovedLegacyFlag("--send", "message send <message>");
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            session_key = args[i];
        } else if (std.mem.eql(u8, arg, "--list-sessions")) {
            try failRemovedLegacyFlag("--list-sessions", "sessions list");
            list_sessions = true;
        } else if (std.mem.eql(u8, arg, "--use-session")) {
            try failRemovedLegacyFlag("--use-session", "sessions use <key>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_session = args[i];
        } else if (std.mem.eql(u8, arg, "--list-nodes")) {
            try failRemovedLegacyFlag("--list-nodes", "nodes list");
            list_nodes = true;
        } else if (std.mem.eql(u8, arg, "--nodes")) {
            try failRemovedLegacyFlag("--nodes", "nodes list");
            list_nodes = true;
        } else if (std.mem.eql(u8, arg, "--pair-list")) {
            try failRemovedLegacyFlag("--pair-list", "devices list");
            device_pair_list = true;
        } else if (std.mem.eql(u8, arg, "--pair-approve")) {
            try failRemovedLegacyFlag("--pair-approve", "devices approve <requestId>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            device_pair_approve_id = args[i];
        } else if (std.mem.eql(u8, arg, "--pair-reject")) {
            try failRemovedLegacyFlag("--pair-reject", "devices reject <requestId>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            device_pair_reject_id = args[i];
        } else if (std.mem.eql(u8, arg, "--watch-pairing")) {
            try failRemovedLegacyFlag("--watch-pairing", "devices watch");
            device_pair_watch = true;
        } else if (std.mem.eql(u8, arg, "--node")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_id = args[i];
        } else if (std.mem.eql(u8, arg, "--use-node")) {
            try failRemovedLegacyFlag("--use-node", "nodes use <id>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_node = args[i];
        } else if (std.mem.eql(u8, arg, "--run")) {
            try failRemovedLegacyFlag("--run", "nodes run <command>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            run_command = args[i];
        } else if (std.mem.eql(u8, arg, "--which")) {
            try failRemovedLegacyFlag("--which", "nodes which <name>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            which_name = args[i];
        } else if (std.mem.eql(u8, arg, "--notify")) {
            try failRemovedLegacyFlag("--notify", "nodes notify <title>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            notify_title = args[i];
        } else if (std.mem.eql(u8, arg, "--ps")) {
            try failRemovedLegacyFlag("--ps", "nodes process list");
            ps_list = true;
        } else if (std.mem.eql(u8, arg, "--spawn")) {
            try failRemovedLegacyFlag("--spawn", "nodes process spawn <command>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            spawn_command = args[i];
        } else if (std.mem.eql(u8, arg, "--poll")) {
            try failRemovedLegacyFlag("--poll", "nodes process poll <processId>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            poll_process_id = args[i];
        } else if (std.mem.eql(u8, arg, "--stop")) {
            try failRemovedLegacyFlag("--stop", "nodes process stop <processId>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            stop_process_id = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-present")) {
            try failRemovedLegacyFlag("--canvas-present", "nodes canvas present");
            canvas_present = true;
        } else if (std.mem.eql(u8, arg, "--canvas-hide")) {
            try failRemovedLegacyFlag("--canvas-hide", "nodes canvas hide");
            canvas_hide = true;
        } else if (std.mem.eql(u8, arg, "--canvas-navigate")) {
            try failRemovedLegacyFlag("--canvas-navigate", "nodes canvas navigate <url>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_navigate = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-eval")) {
            try failRemovedLegacyFlag("--canvas-eval", "nodes canvas eval <js>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_eval = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-snapshot")) {
            try failRemovedLegacyFlag("--canvas-snapshot", "nodes canvas snapshot <path>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_snapshot = args[i];
        } else if (std.mem.eql(u8, arg, "--exec-approvals-get")) {
            try failRemovedLegacyFlag("--exec-approvals-get", "nodes approvals get");
            exec_approvals_get = true;
        } else if (std.mem.eql(u8, arg, "--exec-allow")) {
            try failRemovedLegacyFlag("--exec-allow", "nodes approvals allow <command>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            exec_allow_cmd = args[i];
        } else if (std.mem.eql(u8, arg, "--exec-allow-file")) {
            try failRemovedLegacyFlag("--exec-allow-file", "nodes approvals allow-file <path>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            exec_allow_file = args[i];
        } else if (std.mem.eql(u8, arg, "--list-approvals")) {
            try failRemovedLegacyFlag("--list-approvals", "approvals list");
            list_approvals = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            try failRemovedLegacyFlag("--approve", "approvals approve <id>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            approve_id = args[i];
        } else if (std.mem.eql(u8, arg, "--deny")) {
            try failRemovedLegacyFlag("--deny", "approvals deny <id>");
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            deny_id = args[i];
        } else if (std.mem.eql(u8, arg, "--check-update-only")) {
            check_update_only = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--node-service-install")) {
            logger.err("Flag --node-service-install was removed. Use `node service install`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-uninstall")) {
            logger.err("Flag --node-service-uninstall was removed. Use `node service uninstall`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-start")) {
            logger.err("Flag --node-service-start was removed. Use `node service start`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-stop")) {
            logger.err("Flag --node-service-stop was removed. Use `node service stop`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-start")) {
            logger.err("Flag --node-service-start was removed. Use `node service start`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-stop")) {
            logger.err("Flag --node-service-stop was removed. Use `node service stop`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-status")) {
            logger.err("Flag --node-service-status was removed. Use `node service status`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--node-service-mode")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const v = args[i];
            if (std.mem.eql(u8, v, "onlogon")) {
                node_service_mode = .onlogon;
            } else if (std.mem.eql(u8, v, "onstart")) {
                node_service_mode = .onstart;
            } else {
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--node-service-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_service_name = args[i];
        } else if (std.mem.eql(u8, arg, "--extract-wsz")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            extract_wsz = args[i];
        } else if (std.mem.eql(u8, arg, "--extract-dest")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            extract_dest = args[i];
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const v = args[i];
            if (std.mem.eql(u8, v, "service")) {
                node_runner_mode = .service;
            } else if (std.mem.eql(u8, v, "session")) {
                node_runner_mode = .session;
            } else {
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--runner-mode")) {
            logger.err("Flag --runner-mode was removed. Use `--mode service|session`.", .{});
            return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const v = args[i];
            if (std.mem.eql(u8, v, "client")) {
                node_profile_mode = .client;
            } else if (std.mem.eql(u8, v, "service")) {
                node_profile_mode = .service;
            } else if (std.mem.eql(u8, v, "session")) {
                node_profile_mode = .session;
            } else {
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--windows-service")) {
            // handled by pre-scan; keep parsing so we accept --config/--log-level/etc.
        } else if (std.mem.eql(u8, arg, "--node-mode")) {
            // handled by pre-scan
        } else if (std.mem.eql(u8, arg, "--operator-mode")) {
            if (comptime !cli_features.supports_operator_client) {
                logger.err("This CLI build is node-only and cannot act as operator. Rebuild with -Dcli_operator=true.", .{});
                return error.Unsupported;
            }
            logger.warn("Flag --operator-mode is deprecated; operator actions are available without it.", .{});
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            save_config = true;
        } else if (std.mem.eql(u8, arg, "--node-mode-help")) {
            try writeHelpText(allocator, main_node.usage);
            return;
        } else if (std.mem.eql(u8, arg, "--operator-mode-help")) {
            try writeHelpText(allocator, main_operator.usage);
            return;
        } else {
            // When running a specialized mode, allow that mode to parse its own flags.
            if (!(node_mode or node_register_mode or windows_service_run)) {
                logger.warn("Unknown argument: {s}", .{arg});
            }
        }
    }

    const has_action = list_sessions or list_nodes or list_approvals or send_message != null or
        run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
        poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or
        canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or exec_approvals_get or
        exec_allow_cmd != null or exec_allow_file != null or approve_id != null or deny_id != null or
        device_pair_list or device_pair_approve_id != null or device_pair_reject_id != null or device_pair_watch or use_session != null or use_node != null or
        extract_wsz != null or check_update_only or print_update_url or interactive or node_mode or windows_service_run or node_register_mode or save_config or
        node_service_install or node_service_uninstall or node_service_start or node_service_stop or node_service_status or
        node_session_install or node_session_uninstall or node_session_start or node_session_stop or node_session_status or
        node_runner_install or node_runner_start or node_runner_stop or node_runner_status or
        node_profile_apply or tray_install_startup or tray_uninstall_startup or tray_start_startup or tray_stop_startup or tray_status_startup;
    if (!has_action) {
        try writeHelpText(allocator, usage);
        return;
    }

    const operator_action_requested = list_sessions or list_nodes or list_approvals or
        send_message != null or session_key != null or use_session != null or node_id != null or use_node != null or
        run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
        poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or
        canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or exec_approvals_get or
        exec_allow_cmd != null or exec_allow_file != null or approve_id != null or deny_id != null or
        device_pair_list or device_pair_approve_id != null or device_pair_reject_id != null or device_pair_watch or interactive;

    if (!cli_features.supports_operator_client and operator_action_requested) {
        logger.err("{s}", .{cli_features.operator_disabled_hint});
        return error.Unsupported;
    }

    if (extract_wsz) |path| {
        const dest = extract_dest orelse return error.InvalidArguments;
        winamp_import.extractWszToDirectory(allocator, path, dest) catch |err| {
            logger.err("Failed to extract wsz: {}", .{err});
            return err;
        };
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Extracted .wsz to: {s}\n", .{dest});
        return;
    }

    // Internal: Windows SCM invokes the service executable with --windows-service.
    if (windows_service_run) {
        if (builtin.os.tag != .windows) {
            logger.err("--windows-service is only supported on Windows", .{});
            return error.InvalidArguments;
        }
        const svc_name = node_service_name orelse win_scm.defaultServiceName();
        // Note: this call blocks until the service stops.
        win_scm_host.runWindowsService(allocator, svc_name, args[1..]) catch |err| {
            logger.err("Failed to start Windows service dispatcher: {s}", .{@errorName(err)});
            return;
        };
        return;
    }

    if (tray_install_startup or tray_uninstall_startup or tray_start_startup or tray_stop_startup or tray_status_startup) {
        if (builtin.os.tag != .windows) {
            logger.err("tray startup helpers are only supported on Windows", .{});
            return error.InvalidArguments;
        }

        if (tray_install_startup) {
            installTrayStartup(allocator) catch |err| {
                if (err == error.AccessDenied) {
                    logger.err("Tray startup install failed: access denied (try elevated PowerShell).", .{});
                    return error.AccessDenied;
                }
                return err;
            };
            _ = startTrayStartupTask(allocator) catch {};
            _ = std.fs.File.stdout().write("Tray startup installed.\n") catch {};
            return;
        }
        if (tray_uninstall_startup) {
            uninstallTrayStartup(allocator) catch |err| {
                if (err == error.AccessDenied) {
                    logger.err("Tray startup uninstall failed: access denied (try elevated PowerShell).", .{});
                    return error.AccessDenied;
                }
                return err;
            };
            _ = std.fs.File.stdout().write("Tray startup uninstalled.\n") catch {};
            return;
        }
        if (tray_start_startup) {
            startTrayStartupTask(allocator) catch |err| {
                if (err == error.AccessDenied) {
                    logger.err("Tray startup task start failed: access denied.", .{});
                    return error.AccessDenied;
                }
                if (err == error.NotInstalled) {
                    logger.err("Tray startup task is not installed.", .{});
                    return error.InvalidArguments;
                }
                return err;
            };
            _ = std.fs.File.stdout().write("Started tray startup task.\n") catch {};
            return;
        }
        if (tray_stop_startup) {
            _ = stopTrayStartupTask(allocator) catch {};
            _ = std.fs.File.stdout().write("Stopped tray startup task.\n") catch {};
            return;
        }
        if (tray_status_startup) {
            const installed = trayStartupInstalled(allocator) catch |err| {
                if (err == error.AccessDenied) {
                    logger.err("Tray startup task query failed: access denied.", .{});
                    return error.AccessDenied;
                }
                return err;
            };
            _ = std.fs.File.stdout().write(if (installed) "Tray startup: installed\n" else "Tray startup: not installed\n") catch {};
            return;
        }
    }

    if (node_profile_apply) {
        if (builtin.os.tag != .windows) {
            logger.err("node profile apply is only supported on Windows", .{});
            return error.InvalidArguments;
        }
        if (node_profile_mode == null) {
            logger.err("node profile apply requires --profile client|service|session", .{});
            return error.InvalidArguments;
        }

        switch (node_profile_mode.?) {
            .client => {
                const runner_name = node_service_name orelse win_scm.defaultServiceName();
                _ = win_control_pipe.requestOk(allocator, "stop") catch null;

                _ = win_service.stopTask(allocator, runner_name) catch {};
                win_service.uninstallTask(allocator, runner_name) catch |err| switch (err) {
                    win_service.ServiceError.AccessDenied => {
                        logger.err("Cannot remove user-session runner: access denied.", .{});
                        return error.AccessDenied;
                    },
                    else => {},
                };

                _ = win_scm.stopService(allocator, runner_name) catch {};
                win_scm.uninstallService(allocator, runner_name) catch |err| switch (err) {
                    win_scm.ServiceError.AccessDenied => {
                        logger.err("Cannot remove Windows service runner: access denied.", .{});
                        logger.err("Fix: run in elevated PowerShell: ziggystarclaw-cli node service uninstall", .{});
                        return error.AccessDenied;
                    },
                    else => {},
                };

                _ = stopTrayStartupTask(allocator) catch {};
                uninstallTrayStartup(allocator) catch |err| {
                    if (err == error.AccessDenied) {
                        logger.err("Cannot remove tray startup task: access denied.", .{});
                        return error.AccessDenied;
                    }
                    return err;
                };

                _ = std.fs.File.stdout().write("Applied profile: client (no node runner, no tray startup)\n") catch {};
                return;
            },
            .service => {
                var install_cmd = std.ArrayList([]const u8).empty;
                defer install_cmd.deinit(allocator);
                try install_cmd.appendSlice(allocator, &.{ "node", "runner", "install", "--mode", "service" });
                try appendProfileCommonArgs(
                    allocator,
                    &install_cmd,
                    config_path_set,
                    config_path,
                    override_url,
                    override_token,
                    override_insecure,
                    node_service_name,
                );
                try runSelfCliCommandWithWindowsElevationFallback(allocator, install_cmd.items);

                var start_cmd = std.ArrayList([]const u8).empty;
                defer start_cmd.deinit(allocator);
                try start_cmd.appendSlice(allocator, &.{ "node", "runner", "start" });
                if (node_service_name) |name| {
                    try start_cmd.appendSlice(allocator, &.{ "--node-service-name", name });
                }
                try runSelfCliCommand(allocator, start_cmd.items);

                installTrayStartup(allocator) catch |err| {
                    if (err == error.AccessDenied) {
                        logger.warn("Tray startup install skipped: access denied. You can still launch tray manually or install startup later.", .{});
                    } else {
                        logger.warn("Tray startup install skipped: {}", .{err});
                    }
                };
                _ = startTrayStartupTask(allocator) catch |err| {
                    logger.warn("Tray startup start skipped: {}", .{err});
                };

                var out = std.fs.File.stdout().deprecatedWriter();
                try out.print(
                    "Applied profile: {s} (runner active; tray startup configured when permitted)\n",
                    .{"service"},
                );
                return;
            },
            .session => {
                var install_cmd = std.ArrayList([]const u8).empty;
                defer install_cmd.deinit(allocator);
                try install_cmd.appendSlice(allocator, &.{ "node", "runner", "install", "--mode", "session" });
                try appendProfileCommonArgs(
                    allocator,
                    &install_cmd,
                    config_path_set,
                    config_path,
                    override_url,
                    override_token,
                    override_insecure,
                    node_service_name,
                );
                try runSelfCliCommand(allocator, install_cmd.items);

                var start_cmd = std.ArrayList([]const u8).empty;
                defer start_cmd.deinit(allocator);
                try start_cmd.appendSlice(allocator, &.{ "node", "runner", "start" });
                if (node_service_name) |name| {
                    try start_cmd.appendSlice(allocator, &.{ "--node-service-name", name });
                }
                try runSelfCliCommand(allocator, start_cmd.items);

                installTrayStartup(allocator) catch |err| {
                    if (err == error.AccessDenied) {
                        logger.warn("Tray startup install skipped: access denied. You can still launch tray manually or install startup later.", .{});
                    } else {
                        logger.warn("Tray startup install skipped: {}", .{err});
                    }
                };
                _ = startTrayStartupTask(allocator) catch |err| {
                    logger.warn("Tray startup start skipped: {}", .{err});
                };

                var out = std.fs.File.stdout().deprecatedWriter();
                try out.print(
                    "Applied profile: {s} (runner active; tray startup configured when permitted)\n",
                    .{"session"},
                );
                return;
            },
        }
    }

    // Node runner helpers (Windows): select between SCM service mode and user-session runner mode.
    if (node_runner_status or node_runner_start or node_runner_stop) {
        if (builtin.os.tag != .windows) {
            logger.err("node runner helpers are only supported on Windows", .{});
            return error.InvalidArguments;
        }

        const name = node_service_name orelse win_scm.defaultServiceName();

        const svc_q = win_scm.queryService(allocator, name) catch null;
        const has_svc = if (svc_q) |q| q.state != .not_installed else false;

        const has_task = win_service.taskInstalled(allocator, name) catch |err| switch (err) {
            win_service.ServiceError.AccessDenied => {
                logger.err("Scheduled Task query failed: access denied", .{});
                return error.AccessDenied;
            },
            else => false,
        };

        if (has_svc and has_task) {
            _ = std.fs.File.stdout().write("Runner: configuration error (both service and session runner are installed)\n") catch {};
            _ = std.fs.File.stdout().write("Fix: ziggystarclaw-cli node runner install --mode service\n") catch {};
            _ = std.fs.File.stdout().write("  or: ziggystarclaw-cli node runner install --mode session\n") catch {};
            return error.InvalidArguments;
        }

        if (node_runner_status) {
            if (has_svc) {
                const q = svc_q.?;
                var out = std.fs.File.stdout().deprecatedWriter();
                try out.print("Runner: service ({s})\n", .{win_scm.stateLabel(q.state)});
                return;
            }
            if (has_task) {
                _ = std.fs.File.stdout().write("Runner: user session runner (Scheduled Task)\n") catch {};
                return;
            }
            _ = std.fs.File.stdout().write("Runner: not installed\n") catch {};
            return;
        }

        if (node_runner_start) {
            if (has_svc) {
                win_scm.startService(allocator, name) catch |err| switch (err) {
                    win_scm.ServiceError.AccessDenied => {
                        logger.err("Start failed: access denied", .{});
                        return error.AccessDenied;
                    },
                    else => return err,
                };
                _ = std.fs.File.stdout().write("Started node runner (service).\n") catch {};
                return;
            }
            if (has_task) {
                win_service.startTask(allocator, name) catch |err| switch (err) {
                    win_service.ServiceError.AccessDenied => {
                        logger.err("Start failed: access denied", .{});
                        return error.AccessDenied;
                    },
                    win_service.ServiceError.NotInstalled => {
                        logger.err("Start failed: not installed", .{});
                        return error.InvalidArguments;
                    },
                    else => return err,
                };
                _ = std.fs.File.stdout().write("Started node runner (user session).\n") catch {};
                return;
            }
            logger.err("Runner is not installed", .{});
            return error.InvalidArguments;
        }

        if (node_runner_stop) {
            if (has_svc) {
                win_scm.stopService(allocator, name) catch |err| switch (err) {
                    win_scm.ServiceError.AccessDenied => {
                        logger.err("Stop failed: access denied", .{});
                        return error.AccessDenied;
                    },
                    else => return err,
                };
                _ = std.fs.File.stdout().write("Stopped node runner (service).\n") catch {};
                return;
            }
            if (has_task) {
                // Stop the running task instance (best-effort).
                _ = win_service.stopTask(allocator, name) catch {};
                _ = std.fs.File.stdout().write("Stopped node runner (user session).\n") catch {};
                return;
            }
            logger.err("Runner is not installed", .{});
            return error.InvalidArguments;
        }
    }

    if (node_runner_install) {
        if (node_runner_mode == null) {
            logger.err("node runner install requires --mode service|session", .{});
            return error.InvalidArguments;
        }
        switch (node_runner_mode.?) {
            .service => node_service_install = true,
            .session => node_session_install = true,
        }
    }

    // User-session runner helpers (Windows Scheduled Task wrapper)
    if (node_session_install or node_session_uninstall or node_session_start or node_session_stop or node_session_status) {
        if (builtin.os.tag != .windows) {
            logger.err("node session helpers are only supported on Windows", .{});
            return error.InvalidArguments;
        }

        const runner_name = node_service_name orelse win_scm.defaultServiceName();

        const node_cfg_path = if (config_path_set) blk: {
            break :blk try allocator.dupe(u8, config_path);
        } else blk: {
            break :blk try unified_config.defaultConfigPath(allocator);
        };
        defer allocator.free(node_cfg_path);

        const cfg_exists = blk: {
            std.fs.cwd().access(node_cfg_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        var cfg_invalid = false;
        if (cfg_exists) {
            var parsed = unified_config.load(allocator, node_cfg_path) catch |err| switch (err) {
                error.ConfigNotFound => null,
                error.SyntaxError, error.UnknownField => blk: {
                    cfg_invalid = true;
                    break :blk null;
                },
                else => return err,
            };
            if (parsed) |*loaded| loaded.deinit(allocator);
        }
        const storage_scope: node_register.StorageScope = .user;

        if (!cfg_exists or cfg_invalid) {
            if (override_url != null and override_token_set) {
                try node_register.writeDefaultConfig(allocator, node_cfg_path, override_url.?, override_token orelse "", storage_scope);
            } else if (override_url != null and !override_token_set) {
                // Non-interactive-friendly behavior: allow empty token when URL is provided.
                // Gateway deployments that require auth token will reject at connect/register time.
                try node_register.writeDefaultConfig(allocator, node_cfg_path, override_url.?, "", storage_scope);
            } else if (override_url == null and override_token_set) {
                logger.err("--gateway-token was provided without --url; please pass --url too (e.g. wss://wizball.tail*.ts.net)", .{});
                return error.InvalidArguments;
            } else if (cfg_invalid) {
                logger.err("Config is invalid at {s}; pass --url (and optional --gateway-token) to repair non-interactively.", .{node_cfg_path});
                return error.InvalidArguments;
            }
        }

        if (node_session_install) {
            // Migrate away from SCM service mode first; otherwise we'd start two runners.
            const q = win_scm.queryService(allocator, runner_name) catch null;
            if (q) |qq| {
                if (qq.state != .not_installed) {
                    // Try to stop + uninstall the service.
                    win_scm.stopService(allocator, runner_name) catch |err| switch (err) {
                        win_scm.ServiceError.AccessDenied => {
                            logger.err("Cannot switch to user session runner: Windows service is installed and requires elevation to remove.", .{});
                            logger.err("Fix: run in an elevated PowerShell: ziggystarclaw-cli node service uninstall", .{});
                            return error.AccessDenied;
                        },
                        else => {},
                    };

                    win_scm.uninstallService(allocator, runner_name) catch |err| switch (err) {
                        win_scm.ServiceError.AccessDenied => {
                            logger.err("Cannot switch to user session runner: Windows service uninstall requires elevation.", .{});
                            logger.err("Fix: run in an elevated PowerShell: ziggystarclaw-cli node service uninstall", .{});
                            return error.AccessDenied;
                        },
                        else => return err,
                    };
                }
            }

            // Ensure config has a valid node token/id before installing the runner.
            try node_register.run(allocator, node_cfg_path, override_insecure orelse false, true, null, storage_scope);

            // Ensure any existing task instance is stopped before overwriting.
            _ = win_service.stopTask(allocator, runner_name) catch {};

            win_service.installTask(allocator, node_cfg_path, .onlogon, runner_name) catch |err| {
                if (err == win_service.ServiceError.AccessDenied) {
                    logger.err("Scheduled Task install failed: access denied. Try re-running from an elevated (Administrator) PowerShell.", .{});
                    return error.AccessDenied;
                }
                return err;
            };

            // Best-effort: start immediately (otherwise it starts on next logon).
            _ = win_service.startTask(allocator, runner_name) catch {};

            _ = std.fs.File.stdout().write("Installed user session runner (Scheduled Task).\n") catch {};
            _ = std.fs.File.stdout().write("Mode: User session runner (interactive desktop access)\n") catch {};
            return;
        }

        if (node_session_uninstall) {
            _ = win_service.stopTask(allocator, runner_name) catch {};
            win_service.uninstallTask(allocator, runner_name) catch |err| {
                if (err == win_service.ServiceError.AccessDenied) {
                    logger.err("Scheduled Task uninstall failed: access denied", .{});
                    return error.AccessDenied;
                }
                return err;
            };
            _ = std.fs.File.stdout().write("Uninstalled user session runner (Scheduled Task).\n") catch {};
            return;
        }

        if (node_session_start) {
            win_service.startTask(allocator, runner_name) catch |err| {
                if (err == win_service.ServiceError.AccessDenied) {
                    logger.err("Start failed: access denied", .{});
                    return error.AccessDenied;
                }
                if (err == win_service.ServiceError.NotInstalled) {
                    logger.err("Start failed: not installed", .{});
                    return error.InvalidArguments;
                }
                return err;
            };
            _ = std.fs.File.stdout().write("Started user session runner.\n") catch {};
            return;
        }

        if (node_session_stop) {
            // Stop the task instance (kills the wrapper).
            _ = win_service.stopTask(allocator, runner_name) catch {};
            _ = std.fs.File.stdout().write("Stopped user session runner.\n") catch {};
            return;
        }

        if (node_session_status) {
            const has_task = win_service.taskInstalled(allocator, runner_name) catch false;
            if (!has_task) {
                _ = std.fs.File.stdout().write("User session runner: not installed\n") catch {};
                return;
            }

            const svc_q = win_scm.queryService(allocator, runner_name) catch null;
            if (svc_q) |qq| {
                if (qq.state != .not_installed) {
                    _ = std.fs.File.stdout().write("WARNING: Windows service is also installed (modes should be mutually exclusive).\n") catch {};
                    _ = std.fs.File.stdout().write("Fix: ziggystarclaw-cli node runner install --mode service\n") catch {};
                    _ = std.fs.File.stdout().write("  or: ziggystarclaw-cli node runner install --mode session\n") catch {};
                }
            }

            _ = std.fs.File.stdout().write("User session runner: installed (Scheduled Task)\n") catch {};
            return;
        }
    }

    // Node service helpers (Windows SCM service, Linux systemd)
    if (node_service_install or node_service_uninstall or node_service_start or node_service_stop or node_service_status) {
        // For node services, prefer the explicit --config path if provided; otherwise
        // use the unified node config default path.
        //
        // IMPORTANT (Linux/system scope): when invoked via sudo with --node-service-mode onstart,
        // HOME typically points at /root. But the generated systemd unit runs as SUDO_USER.
        // In that case we must derive the default config path from the target user's home,
        // not root's, otherwise the service will fail to read its config.
        const node_cfg_path = if (config_path_set) blk: {
            break :blk try allocator.dupe(u8, config_path);
        } else if (builtin.os.tag == .windows and node_service_mode == .onstart) blk: {
            // System-scope default (boot-start on Windows).
            const programdata = std.process.getEnvVarOwned(allocator, "ProgramData") catch (std.process.getEnvVarOwned(allocator, "PROGRAMDATA") catch null);
            if (programdata) |pd| {
                defer allocator.free(pd);
                break :blk try std.fs.path.join(allocator, &.{ pd, "ZiggyStarClaw", "config.json" });
            }
            break :blk try allocator.dupe(u8, "C:\\ProgramData\\ZiggyStarClaw\\config.json");
        } else if (builtin.os.tag == .linux and node_service_mode == .onstart and std.posix.geteuid() == 0) blk: {
            const sudo_user = std.process.getEnvVarOwned(allocator, "SUDO_USER") catch null;
            if (sudo_user) |u| {
                defer allocator.free(u);
                if (linuxHomeDirForUser(allocator, u)) |home| {
                    defer allocator.free(home);
                    break :blk try std.fs.path.join(allocator, &.{ home, ".config", "ziggystarclaw", "config.json" });
                } else |_| {}
            }
            break :blk try unified_config.defaultConfigPath(allocator);
        } else blk: {
            break :blk try unified_config.defaultConfigPath(allocator);
        };
        defer allocator.free(node_cfg_path);

        // If the config doesn't exist yet and the user provided --url/--token, bootstrap it
        // non-interactively so service install can be scripted.
        const cfg_exists = blk: {
            std.fs.cwd().access(node_cfg_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        var cfg_invalid = false;
        if (cfg_exists) {
            var parsed = unified_config.load(allocator, node_cfg_path) catch |err| switch (err) {
                error.ConfigNotFound => null,
                error.SyntaxError, error.UnknownField => blk: {
                    cfg_invalid = true;
                    break :blk null;
                },
                else => return err,
            };
            if (parsed) |*loaded| loaded.deinit(allocator);
        }
        const storage_scope: node_register.StorageScope = if (builtin.os.tag == .windows and node_service_mode == .onstart)
            .system
        else
            .user;

        if (!cfg_exists or cfg_invalid) {
            // Bootstrap config non-interactively when possible.
            //
            // If only --url is provided, prompt only for the auth token (so users don't get stuck
            // at a URL prompt even though they already passed one).
            if (override_url != null and override_token_set) {
                try node_register.writeDefaultConfig(allocator, node_cfg_path, override_url.?, override_token orelse "", storage_scope);
            } else if (override_url != null and !override_token_set) {
                // Non-interactive-friendly behavior: allow empty token when URL is provided.
                // Gateway deployments that require auth token will reject at connect/register time.
                try node_register.writeDefaultConfig(allocator, node_cfg_path, override_url.?, "", storage_scope);
            } else if (override_url == null and override_token_set) {
                logger.err("--gateway-token was provided without --url; please pass --url too (e.g. wss://wizball.tail*.ts.net)", .{});
                return error.InvalidArguments;
            } else if (cfg_invalid) {
                logger.err("Config is invalid at {s}; pass --url (and optional --gateway-token) to repair non-interactively.", .{node_cfg_path});
                return error.InvalidArguments;
            }
        }

        if (builtin.os.tag == .linux) {
            if (node_service_install) {
                // Ensure config has a valid node token/id before enabling the service.
                try node_register.run(allocator, node_cfg_path, override_insecure orelse false, true, null, storage_scope);

                const unit = linux_service.installService(allocator, node_cfg_path, node_service_mode, node_service_name) catch |err| {
                    if (err == linux_service.ServiceError.AccessDenied) {
                        logger.err("systemd install failed: access denied. If using --node-service-mode onstart, re-run with sudo.", .{});
                        return;
                    }
                    return err;
                };
                defer allocator.free(unit);

                _ = std.fs.File.stdout().write("Installed systemd service for node-mode.\n") catch {};
                if (node_service_mode == .onlogon) {
                    _ = std.fs.File.stdout().write("Logs: journalctl --user -u ") catch {};
                } else {
                    _ = std.fs.File.stdout().write("Logs: sudo journalctl -u ") catch {};
                }
                _ = std.fs.File.stdout().write(unit) catch {};
                _ = std.fs.File.stdout().write("\n") catch {};
                return;
            }
            if (node_service_uninstall) {
                const unit = linux_service.uninstallService(allocator, node_service_mode, node_service_name) catch |err| {
                    if (err == linux_service.ServiceError.AccessDenied) {
                        logger.err("systemd uninstall failed: access denied. If using --node-service-mode onstart, re-run with sudo.", .{});
                        return;
                    }
                    return err;
                };
                defer allocator.free(unit);
                _ = std.fs.File.stdout().write("Uninstalled systemd service for node-mode.\n") catch {};
                return;
            }
            if (node_service_start) {
                try linux_service.startService(allocator, node_service_mode, node_service_name);
                _ = std.fs.File.stdout().write("Started systemd service.\n") catch {};
                return;
            }
            if (node_service_stop) {
                try linux_service.stopService(allocator, node_service_mode, node_service_name);
                _ = std.fs.File.stdout().write("Stopped systemd service.\n") catch {};
                return;
            }
            if (node_service_status) {
                try linux_service.statusService(allocator, node_service_mode, node_service_name);
                return;
            }
        }

        if (builtin.os.tag == .windows) {
            if (node_service_install) {
                // Enforce mutual exclusivity: disable/remove any user-session runner artifacts first.
                const runner_name = node_service_name orelse win_scm.defaultServiceName();
                _ = win_service.stopTask(allocator, runner_name) catch {};
                win_service.uninstallTask(allocator, runner_name) catch |err| switch (err) {
                    win_service.ServiceError.AccessDenied => logger.warn("Scheduled Task cleanup failed (access denied); continuing", .{}),
                    else => {},
                };

                // Best-effort: if a user-session supervisor is still running, ask it to stop its child node.
                _ = win_control_pipe.requestOk(allocator, "stop") catch null;

                // Ensure the node is registered/persisted in the SAME config.json the service will use.
                // This keeps manual runs and the installed service deterministic.
                //
                // NOTE: this may require a one-time approval in Control UI; we wait/retry so the user
                // can approve without re-running commands.
                try node_register.run(allocator, node_cfg_path, override_insecure orelse false, true, null, storage_scope);

                // Put logs next to the config (system-scope config => ProgramData; user-scope config => AppData).
                const cfg_dir = std.fs.path.dirname(node_cfg_path) orelse ".";
                const logs_dir = try std.fs.path.join(allocator, &.{ cfg_dir, "logs" });
                defer allocator.free(logs_dir);
                std.fs.cwd().makePath(logs_dir) catch {};

                const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "node.log" });
                defer allocator.free(log_path);

                // Create log file up-front so users have a concrete place to look even if
                // the node fails early.
                _ = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch |err| {
                    logger.warn("Failed to create log file {s}: {}", .{ log_path, err });
                };

                win_scm.installService(allocator, node_cfg_path, node_service_mode, node_service_name) catch |err| {
                    if (err == win_scm.ServiceError.AccessDenied) {
                        logger.err("Windows service install failed: access denied. Re-run this command from an elevated (Administrator) PowerShell.", .{});
                        return error.AccessDenied;
                    }
                    return err;
                };

                const svc_name = node_service_name orelse win_scm.defaultServiceName();

                // UX: when installing boot mode, start it immediately so users can verify
                // success without waiting for a reboot.
                if (node_service_mode == .onstart) {
                    win_scm.startService(allocator, svc_name) catch |err| switch (err) {
                        win_scm.ServiceError.AccessDenied => {
                            logger.warn("Installed service, but immediate start was denied (service will still start at boot).", .{});
                        },
                        else => {
                            logger.warn("Installed service, but immediate start failed: {s}", .{@errorName(err)});
                        },
                    };
                }

                logger.info("Installed Windows SCM service for node-mode.", .{});
                _ = std.fs.File.stdout().write("Installed Windows service for node-mode.\n") catch {};
                _ = std.fs.File.stdout().write("Service name: ") catch {};
                _ = std.fs.File.stdout().write(svc_name) catch {};
                _ = std.fs.File.stdout().write("\n") catch {};
                if (node_service_mode == .onstart) {
                    _ = std.fs.File.stdout().write("Start: attempted immediate service start (in addition to Auto start at boot).\n") catch {};
                }
                _ = std.fs.File.stdout().write("Node logs: ") catch {};
                _ = std.fs.File.stdout().write(log_path) catch {};
                _ = std.fs.File.stdout().write("\n") catch {};
                _ = std.fs.File.stdout().write("Recovery: configured to restart automatically on failure (via SCM).\n") catch {};
                return;
            }
            if (node_service_uninstall) {
                win_scm.uninstallService(allocator, node_service_name) catch |err| {
                    if (err == win_scm.ServiceError.AccessDenied) {
                        logger.err("Windows service uninstall failed: access denied. Re-run from an elevated (Administrator) PowerShell.", .{});
                        return error.AccessDenied;
                    }
                    return err;
                };
                logger.info("Uninstalled Windows service.", .{});
                _ = std.fs.File.stdout().write("Uninstalled Windows service.\n") catch {};
                return;
            }
            if (node_service_start) {
                win_scm.startService(allocator, node_service_name) catch |err| {
                    if (err == win_scm.ServiceError.AccessDenied) {
                        logger.err("Windows service start failed: access denied. If you installed the service without the tray-control permissions, re-install it from an elevated shell.", .{});
                        return error.AccessDenied;
                    }
                    return err;
                };
                logger.info("Started Windows service.", .{});
                _ = std.fs.File.stdout().write("Started Windows service.\n") catch {};
                return;
            }
            if (node_service_stop) {
                win_scm.stopService(allocator, node_service_name) catch |err| {
                    if (err == win_scm.ServiceError.AccessDenied) {
                        logger.err("Windows service stop failed: access denied.\n", .{});
                        return error.AccessDenied;
                    }
                    return err;
                };
                logger.info("Stopped Windows service.", .{});
                _ = std.fs.File.stdout().write("Stopped Windows service.\n") catch {};
                return;
            }
            if (node_service_status) {
                const q = try win_scm.queryService(allocator, node_service_name);
                var out = std.fs.File.stdout().deprecatedWriter();
                try out.print("Service: {s}", .{win_scm.stateLabel(q.state)});
                if (q.pid != 0) try out.print(" pid={d}", .{q.pid});
                if (q.win32_exit_code != 0) try out.print(" win32Exit={d}", .{q.win32_exit_code});
                try out.writeByte('\n');
                return;
            }
        }

        logger.err("node service helpers are only supported on Windows and Linux", .{});
        return error.InvalidArguments;
    }

    // Handle node register (interactive helper)
    if (node_register_mode) {
        const node_opts = try main_node.parseNodeOptions(allocator, args[1..]);
        // TODO(openclaw): in the future, OpenClaw gateway should expose a first-class
        // RPC/UI flow to grant role=node tokens during pairing. Until then we prompt the
        // user to paste the node token explicitly.
        try node_register.run(allocator, node_opts.config_path, node_opts.insecure_tls, node_register_wait, node_opts.display_name, .user);
        return;
    }

    // Handle node mode
    if (node_mode) {
        const node_opts = try main_node.parseNodeOptions(allocator, args[1..]);
        try main_node.runNodeMode(allocator, node_opts);
        return;
    }

    // Deprecated: `--operator-mode` used to enable a legacy operator CLI. Operator actions
    // are now available via the default noun-verb command surface.

    if (comptime cli_features.supports_operator_client) {
        try operator_chunk.run(allocator, .{
            .config_path = config_path,
            .override_url = override_url,
            .override_token = override_token,
            .override_token_set = override_token_set,
            .override_update_url = override_update_url,
            .override_insecure = override_insecure,
            .read_timeout_ms = read_timeout_ms,
            .send_message = send_message,
            .session_key = session_key,
            .list_sessions = list_sessions,
            .use_session = use_session,
            .list_nodes = list_nodes,
            .node_id = node_id,
            .use_node = use_node,
            .run_command = run_command,
            .which_name = which_name,
            .notify_title = notify_title,
            .ps_list = ps_list,
            .spawn_command = spawn_command,
            .poll_process_id = poll_process_id,
            .stop_process_id = stop_process_id,
            .canvas_present = canvas_present,
            .canvas_hide = canvas_hide,
            .canvas_navigate = canvas_navigate,
            .canvas_eval = canvas_eval,
            .canvas_snapshot = canvas_snapshot,
            .exec_approvals_get = exec_approvals_get,
            .exec_allow_cmd = exec_allow_cmd,
            .exec_allow_file = exec_allow_file,
            .list_approvals = list_approvals,
            .approve_id = approve_id,
            .deny_id = deny_id,
            .device_pair_list = device_pair_list,
            .device_pair_approve_id = device_pair_approve_id,
            .device_pair_reject_id = device_pair_reject_id,
            .device_pair_watch = device_pair_watch,
            .check_update_only = check_update_only,
            .print_update_url = print_update_url,
            .interactive = interactive,
            .save_config = save_config,
        });
    } else {
        try node_only_chunk.run(allocator, .{
            .config_path = config_path,
            .override_url = override_url,
            .override_token = override_token,
            .override_token_set = override_token_set,
            .override_update_url = override_update_url,
            .override_insecure = override_insecure,
            .check_update_only = check_update_only,
            .print_update_url = print_update_url,
            .save_config = save_config,
        });
    }
}

fn cliLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Effective log level is the stricter of:
    // - cli_log_level (set via env MOLT_LOG_LEVEL today)
    // - logger.getLevel() (set by node-mode/operator-mode flags)
    const logger_level = toStdLogLevel(logger.getLevel());
    // Choose the more verbose (lower rank) of the two thresholds.
    const effective = if (stdLogRank(cli_log_level) < stdLogRank(logger_level)) cli_log_level else logger_level;
    if (stdLogRank(level) < stdLogRank(effective)) return;

    var stderr = std.fs.File.stderr().deprecatedWriter();
    if (scope == .default) {
        stderr.print("{s}: ", .{@tagName(level)}) catch return;
    } else {
        stderr.print("{s}({s}): ", .{ @tagName(level), @tagName(scope) }) catch return;
    }
    stderr.print(format, args) catch return;
    stderr.writeByte('\n') catch return;
}

fn initLogging(allocator: std.mem.Allocator) !void {
    const env_level = std.process.getEnvVarOwned(allocator, "MOLT_LOG_LEVEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_level) |value| {
        defer allocator.free(value);
        if (parseLogLevel(value)) |level| {
            logger.setLevel(level);
            cli_log_level = toStdLogLevel(level);
        }
    }

    const env_file = std.process.getEnvVarOwned(allocator, "MOLT_LOG_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_file) |path| {
        defer allocator.free(path);
        logger.initFile(path) catch |err| {
            logger.warn("Failed to open log file: {}", .{err});
        };
    }
    logger.initAsync(allocator) catch |err| {
        logger.warn("Failed to start async logger: {}", .{err});
    };
}

fn parseLogLevel(value: []const u8) ?logger.Level {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn") or std.ascii.eqlIgnoreCase(value, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error") or std.ascii.eqlIgnoreCase(value, "err")) return .err;
    return null;
}

fn toStdLogLevel(level: logger.Level) std.log.Level {
    return switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

fn stdLogRank(level: std.log.Level) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}
