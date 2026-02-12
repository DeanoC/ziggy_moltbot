const std = @import("std");
const builtin = @import("builtin");
const client_state = @import("client/state.zig");
const config = @import("client/config.zig");
const event_handler = @import("client/event_handler.zig");
const update_checker = @import("client/update_checker.zig");
const websocket_client = @import("openclaw_transport.zig").websocket;
const logger = @import("utils/logger.zig");
const chat = @import("protocol/chat.zig");
const nodes_proto = @import("protocol/nodes.zig");
const approvals_proto = @import("protocol/approvals.zig");
const requests = @import("protocol/requests.zig");
const messages = @import("protocol/messages.zig");
const main_operator = @import("main_operator.zig");
const build_options = @import("build_options");
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

const usage =
    @embedFile("../docs/cli/01-overview.md") ++ "\n" ++
    @embedFile("../docs/cli/02-options.md") ++ "\n" ++
    @embedFile("../docs/cli/03-node-runner.md") ++ "\n" ++
    @embedFile("../docs/cli/04-tray-startup.md") ++ "\n" ++
    @embedFile("../docs/cli/05-node-service.md") ++ "\n" ++
    @embedFile("../docs/cli/06-global-flags.md");

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
    var operator_mode = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--node-mode")) node_mode = true;
        if (std.mem.eql(u8, a, "--operator-mode")) operator_mode = true;
        if (std.mem.eql(u8, a, "--node-register")) node_register_mode = true;
        if (std.mem.eql(u8, a, "--wait-for-approval")) node_register_wait = true;
        if (std.mem.eql(u8, a, "--windows-service")) windows_service_run = true;
    }
    var save_config = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.print("ziggystarclaw-cli {s}+{s}\n", .{ build_options.app_version, build_options.git_rev });
            return;
        } else if (i == 1 and std.mem.eql(u8, arg, "node")) {
            // Minimal verb-noun style convenience wrapper:
            //   ziggystarclaw-cli node service install|uninstall|start|stop|status
            //   ziggystarclaw-cli node supervise [--config <path>] [--log-level <level>]
            if (i + 1 >= args.len) return error.InvalidArguments;
            const noun = args[i + 1];

            if (std.mem.eql(u8, noun, "supervise")) {
                // Legacy headless supervisor (used by the older Task Scheduler runner MVP).
                // Usage:
                //   ziggystarclaw-cli node supervise --config <path> --as-node --no-operator --log-level debug
                try runNodeSupervisor(allocator, args[(i + 2)..]);
                return;
            }

            if (std.mem.eql(u8, noun, "session")) {
                if (i + 2 >= args.len) {
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
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
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
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
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
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
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
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
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
                    return;
                }
                const action = args[i + 2];
                if (std.mem.eql(u8, action, "apply")) {
                    node_profile_apply = true;
                } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                    var stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.writeAll(usage);
                    return;
                } else {
                    logger.err("Unknown node profile action: {s}", .{action});
                    return error.InvalidArguments;
                }

                // Skip "node profile <action>".
                i += 2;
                continue;
            }

            if (!std.mem.eql(u8, noun, "service")) {
                logger.err("Unknown subcommand: node {s}", .{noun});
                return error.InvalidArguments;
            }
            if (i + 2 >= args.len) {
                var stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.writeAll(usage);
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
                var stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.writeAll(usage);
                return;
            } else {
                logger.err("Unknown node service action: {s}", .{action});
                return error.InvalidArguments;
            }

            // Skip "node service <action>".
            i += 2;
        } else if (i == 1 and std.mem.eql(u8, arg, "tray")) {
            if (i + 1 >= args.len) {
                var stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.writeAll(usage);
                return;
            }
            const action = args[i + 1];
            if (std.mem.eql(u8, action, "install-startup")) {
                tray_install_startup = true;
            } else if (std.mem.eql(u8, action, "uninstall-startup")) {
                tray_uninstall_startup = true;
            } else if (std.mem.eql(u8, action, "start")) {
                tray_start_startup = true;
            } else if (std.mem.eql(u8, action, "stop")) {
                tray_stop_startup = true;
            } else if (std.mem.eql(u8, action, "status")) {
                tray_status_startup = true;
            } else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
                var stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.writeAll(usage);
                return;
            } else {
                logger.err("Unknown tray action: {s}", .{action});
                return error.InvalidArguments;
            }

            // Skip "tray <action>".
            i += 1;
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
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            send_message = args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            session_key = args[i];
        } else if (std.mem.eql(u8, arg, "--list-sessions")) {
            list_sessions = true;
        } else if (std.mem.eql(u8, arg, "--use-session")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_session = args[i];
        } else if (std.mem.eql(u8, arg, "--list-nodes")) {
            list_nodes = true;
        } else if (std.mem.eql(u8, arg, "--node")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_id = args[i];
        } else if (std.mem.eql(u8, arg, "--use-node")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            use_node = args[i];
        } else if (std.mem.eql(u8, arg, "--run")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            run_command = args[i];
        } else if (std.mem.eql(u8, arg, "--which")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            which_name = args[i];
        } else if (std.mem.eql(u8, arg, "--notify")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            notify_title = args[i];
        } else if (std.mem.eql(u8, arg, "--ps")) {
            ps_list = true;
        } else if (std.mem.eql(u8, arg, "--spawn")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            spawn_command = args[i];
        } else if (std.mem.eql(u8, arg, "--poll")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            poll_process_id = args[i];
        } else if (std.mem.eql(u8, arg, "--stop")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            stop_process_id = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-present")) {
            canvas_present = true;
        } else if (std.mem.eql(u8, arg, "--canvas-hide")) {
            canvas_hide = true;
        } else if (std.mem.eql(u8, arg, "--canvas-navigate")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_navigate = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-eval")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_eval = args[i];
        } else if (std.mem.eql(u8, arg, "--canvas-snapshot")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            canvas_snapshot = args[i];
        } else if (std.mem.eql(u8, arg, "--exec-approvals-get")) {
            exec_approvals_get = true;
        } else if (std.mem.eql(u8, arg, "--exec-allow")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            exec_allow_cmd = args[i];
        } else if (std.mem.eql(u8, arg, "--exec-allow-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            exec_allow_file = args[i];
        } else if (std.mem.eql(u8, arg, "--list-approvals")) {
            list_approvals = true;
        } else if (std.mem.eql(u8, arg, "--approve")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            approve_id = args[i];
        } else if (std.mem.eql(u8, arg, "--deny")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            deny_id = args[i];
        } else if (std.mem.eql(u8, arg, "--check-update-only")) {
            check_update_only = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--node-service-install")) {
            node_service_install = true;
        } else if (std.mem.eql(u8, arg, "--node-service-uninstall")) {
            node_service_uninstall = true;
        } else if (std.mem.eql(u8, arg, "--node-service-start")) {
            node_service_start = true;
        } else if (std.mem.eql(u8, arg, "--node-service-stop")) {
            node_service_stop = true;
        } else if (std.mem.eql(u8, arg, "--node-service-status")) {
            node_service_status = true;
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
        } else if (std.mem.eql(u8, arg, "--mode") or std.mem.eql(u8, arg, "--runner-mode")) {
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
            // handled by pre-scan
        } else if (std.mem.eql(u8, arg, "--save-config")) {
            save_config = true;
        } else if (std.mem.eql(u8, arg, "--node-mode-help")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(main_node.usage);
            return;
        } else if (std.mem.eql(u8, arg, "--operator-mode-help")) {
            var stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.writeAll(main_operator.usage);
            return;
        } else {
            // When running a specialized mode, allow that mode to parse its own flags.
            if (!(node_mode or operator_mode or node_register_mode or windows_service_run)) {
                logger.warn("Unknown argument: {s}", .{arg});
            }
        }
    }

    const has_action = list_sessions or list_nodes or list_approvals or send_message != null or
        run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
        poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or
        canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or exec_approvals_get or
        exec_allow_cmd != null or exec_allow_file != null or approve_id != null or deny_id != null or use_session != null or use_node != null or
        extract_wsz != null or check_update_only or print_update_url or interactive or node_mode or windows_service_run or node_register_mode or save_config or
        node_service_install or node_service_uninstall or node_service_start or node_service_stop or node_service_status or
        node_session_install or node_session_uninstall or node_session_start or node_session_stop or node_session_status or
        node_runner_install or node_runner_start or node_runner_stop or node_runner_status or
        node_profile_apply or tray_install_startup or tray_uninstall_startup or tray_start_startup or tray_stop_startup or tray_status_startup;
    if (!has_action) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(usage);
        return;
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

    // Handle operator mode
    if (operator_mode) {
        const op_opts = try main_operator.parseOperatorOptions(allocator, args[1..]);
        try main_operator.runOperatorMode(allocator, op_opts);
        return;
    }

    var cfg = try config.loadOrDefault(allocator, config_path);
    defer cfg.deinit(allocator);

    if (override_url) |url| {
        allocator.free(cfg.server_url);
        cfg.server_url = try allocator.dupe(u8, url);
    } else {
        const env_url = std.process.getEnvVarOwned(allocator, "MOLT_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_url) |url| {
            allocator.free(cfg.server_url);
            cfg.server_url = url;
        }
    }
    if (override_token_set) {
        const token = override_token orelse "";
        allocator.free(cfg.token);
        cfg.token = try allocator.dupe(u8, token);
    } else {
        const env_token = std.process.getEnvVarOwned(allocator, "MOLT_TOKEN") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_token) |token| {
            allocator.free(cfg.token);
            cfg.token = token;
        }
    }
    if (override_insecure) |value| {
        cfg.insecure_tls = value;
    } else {
        const env_insecure = std.process.getEnvVarOwned(allocator, "MOLT_INSECURE_TLS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_insecure) |value| {
            defer allocator.free(value);
            cfg.insecure_tls = parseBool(value);
        }
    }
    if (override_update_url) |url| {
        if (cfg.update_manifest_url) |old| {
            allocator.free(old);
        }
        cfg.update_manifest_url = try allocator.dupe(u8, url);
    }
    if (use_session) |key| {
        if (cfg.default_session) |old| {
            allocator.free(old);
        }
        cfg.default_session = try allocator.dupe(u8, key);
    }
    if (use_node) |id| {
        if (cfg.default_node) |old| {
            allocator.free(old);
        }
        cfg.default_node = try allocator.dupe(u8, id);
    }

    const env_timeout = std.process.getEnvVarOwned(allocator, "MOLT_READ_TIMEOUT_MS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_timeout) |value| {
        defer allocator.free(value);
        read_timeout_ms = try std.fmt.parseInt(u32, value, 10);
    }

    const requires_connection = list_sessions or list_nodes or list_approvals or send_message != null or
        run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
        poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or
        canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or exec_approvals_get or
        exec_allow_cmd != null or exec_allow_file != null or approve_id != null or deny_id != null or interactive;
    if (requires_connection and cfg.server_url.len == 0) {
        logger.err("Server URL is empty. Use --url or set it in {s}.", .{config_path});
        return error.InvalidArguments;
    }

    const needs_node = run_command != null or which_name != null or notify_title != null or ps_list or
        spawn_command != null or poll_process_id != null or stop_process_id != null or canvas_present or
        canvas_hide or canvas_navigate != null or canvas_eval != null or canvas_snapshot != null or
        exec_approvals_get or exec_allow_cmd != null or exec_allow_file != null;

    // Allow node commands with default node; only error if neither is provided.
    if (needs_node and node_id == null and cfg.default_node == null) {
        logger.err("No node specified. Use --node or --use-node to set a default.", .{});
        return error.InvalidArguments;
    }

    if (print_update_url) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{config_path});
            return error.InvalidArguments;
        }
        var normalized = try update_checker.sanitizeUrl(allocator, manifest_url);
        defer allocator.free(normalized);
        _ = try update_checker.normalizeUrlForParse(allocator, &normalized);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Normalized URL: {s}\n", .{normalized});
        if (!check_update_only and !requires_connection and !save_config) {
            return;
        }
    }

    // Handle --save-config without connecting
    if (save_config and !check_update_only and !list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and approve_id == null and deny_id == null and !interactive) {
        try config.save(allocator, config_path, cfg);
        logger.info("Config saved to {s}", .{config_path});
        return;
    }

    if (check_update_only) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{config_path});
            return error.InvalidArguments;
        }
        var info = try update_checker.checkOnce(allocator, manifest_url, build_options.app_version);
        defer info.deinit(allocator);

        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Current version: {s}\n", .{build_options.app_version});
        try stdout.print("Latest version: {s}\n", .{info.version});
        const newer = update_checker.isNewerVersion(info.version, build_options.app_version);
        try stdout.print("Status: {s}\n", .{if (newer) "update available" else "up to date"});
        try stdout.print("Release URL: {s}\n", .{info.release_url orelse "-"});
        try stdout.print("Download URL: {s}\n", .{info.download_url orelse "-"});
        try stdout.print("Download file: {s}\n", .{info.download_file orelse "-"});
        try stdout.print("SHA256: {s}\n", .{info.download_sha256 orelse "-"});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        cfg.server_url,
        cfg.token,
        cfg.insecure_tls,
        cfg.connect_host_override,
    );
    // Explicitly set CLI connect profile (operator)
    ws_client.setConnectProfile(.{
        .role = "operator",
        .scopes = &.{ "operator.admin", "operator.approvals", "operator.pairing" },
        .client_id = "cli",
        .client_mode = "cli",
    });
    ws_client.setReadTimeout(read_timeout_ms);
    defer ws_client.deinit();

    try ws_client.connect();
    logger.info("CLI connected. Server: {s} (read timeout {}ms)", .{ cfg.server_url, read_timeout_ms });

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();

    // Wait for connection and data
    var connected = false;
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!ws_client.is_connected) {
            logger.err("Disconnected.", .{});
            return error.NotConnected;
        }

        const payload = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            ws_client.disconnect();
            return err;
        };
        if (payload) |text| {
            defer allocator.free(text);
            const update = event_handler.handleRawMessage(&ctx, text) catch |err| blk: {
                logger.warn("Error handling message: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (update) |auth_update| {
                defer auth_update.deinit(allocator);
                ws_client.storeDeviceToken(
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {s}", .{@errorName(err)});
                };
            }
            if (ctx.state == .connected) {
                connected = true;
            }
            // Once we have data we need, proceed
            const have_sessions = ctx.sessions.items.len > 0;
            const have_nodes = ctx.nodes.items.len > 0;

            const needs_sessions = list_sessions or send_message != null or interactive;
            const needs_nodes = list_nodes or run_command != null or which_name != null or notify_title != null or ps_list or spawn_command != null or
                poll_process_id != null or stop_process_id != null or canvas_present or canvas_hide or canvas_navigate != null or canvas_eval != null or canvas_snapshot != null;

            if (connected) {
                // Actively request state instead of waiting for the gateway to push it.
                if (needs_sessions and !have_sessions and ctx.pending_sessions_request_id == null) {
                    requestSessionsList(allocator, &ws_client, &ctx) catch |err| {
                        logger.warn("sessions.list request failed: {s}", .{@errorName(err)});
                    };
                }
                if (needs_nodes and !have_nodes and ctx.pending_nodes_request_id == null) {
                    requestNodesList(allocator, &ws_client, &ctx) catch |err| {
                        logger.warn("node.list request failed: {s}", .{@errorName(err)});
                    };
                }

                if (list_sessions and have_sessions) break;
                if (list_nodes and have_nodes) break;
                if (list_approvals) break;
                if (send_message != null and have_sessions) break;
                if (needs_nodes and have_nodes) break;
                if (approve_id != null) break;
                if (deny_id != null) break;
                if (interactive) break;
                if (!list_sessions and !list_nodes and !list_approvals and send_message == null and run_command == null and which_name == null and notify_title == null and !ps_list and spawn_command == null and poll_process_id == null and stop_process_id == null and !canvas_present and !canvas_hide and canvas_navigate == null and canvas_eval == null and canvas_snapshot == null and approve_id == null and deny_id == null and !interactive) break;
            }
        } else {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    if (!connected) {
        logger.err("Failed to connect within timeout.", .{});
        return error.ConnectionTimeout;
    }

    // Handle --list-sessions
    if (list_sessions) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Available sessions:\n");
        if (ctx.sessions.items.len == 0) {
            try stdout.writeAll("  (no sessions available)\n");
        } else {
            for (ctx.sessions.items) |session| {
                const display = session.display_name orelse session.key;
                const label = session.label orelse "-";
                const kind = session.kind orelse "-";
                try stdout.print("  {s} | {s} | {s} | {s}\n", .{ session.key, display, label, kind });
            }
        }
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --list-nodes
    if (list_nodes) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Available nodes:\n");
        if (ctx.nodes.items.len == 0) {
            try stdout.writeAll("  (no nodes available)\n");
        } else {
            for (ctx.nodes.items) |node| {
                const display = node.display_name orelse node.id;
                const platform = node.platform orelse "-";
                const status = if (node.connected orelse false) "connected" else "disconnected";
                try stdout.print("  {s} | {s} | {s} | {s}\n", .{ node.id, display, platform, status });
            }
        }
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --list-approvals
    if (list_approvals) {
        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll("Pending approvals:\n");
        if (ctx.approvals.items.len == 0) {
            try stdout.writeAll("  (no pending approvals)\n");
        } else {
            for (ctx.approvals.items) |approval| {
                const summary = approval.summary orelse "(no summary)";
                const can_resolve = if (approval.can_resolve) "Y" else "N";
                try stdout.print("  {s} | {s} | resolve={s}\n", .{ approval.id, summary, can_resolve });
            }
        }
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --send
    if (send_message) |message| {
        const target_session = session_key orelse cfg.default_session orelse blk: {
            if (ctx.sessions.items.len == 0) {
                logger.err("No sessions available. Use --session to specify one.", .{});
                return error.NoSessionAvailable;
            }
            break :blk ctx.sessions.items[0].key;
        };

        try sendChatMessage(allocator, &ws_client, target_session, message);
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Message sent successfully.", .{});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    const target_node = node_id orelse cfg.default_node;

    if (needs_node and ctx.nodes.items.len == 0) {
        // Ensure we have a node list before validating ids.
        if (ctx.pending_nodes_request_id == null) {
            requestNodesList(allocator, &ws_client, &ctx) catch |err| {
                logger.warn("node.list request failed: {s}", .{@errorName(err)});
            };
        }
        var wait_attempts: u32 = 0;
        while (wait_attempts < 150 and ctx.nodes.items.len == 0) : (wait_attempts += 1) {
            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };
            if (payload) |text| {
                defer allocator.free(text);
                _ = event_handler.handleRawMessage(&ctx, text) catch {};
            } else {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    }

    if (target_node != null) {
        // Verify node exists for any node action.
        var node_exists = false;
        for (ctx.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, target_node.?)) {
                node_exists = true;
                break;
            }
        }
        if (!node_exists) {
            logger.err("Node '{s}' not found. Use --list-nodes to see available nodes.", .{target_node.?});
            return error.NodeNotFound;
        }
    }

    // Handle --run (system.run)
    if (run_command) |command| {
        try runNodeCommand(allocator, &ws_client, &ctx, target_node.?, command);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --which (system.which)
    if (which_name) |name| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("name", std.json.Value{ .string = name });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.which", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --notify (system.notify)
    if (notify_title) |title| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("title", std.json.Value{ .string = title });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.notify", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --ps (process.list)
    if (ps_list) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.list", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --spawn (process.spawn)
    if (spawn_command) |cmdline| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        var cmd_arr = try buildJsonCommandArray(allocator, cmdline);
        defer freeJsonStringArray(allocator, &cmd_arr);
        try params_obj.put("command", std.json.Value{ .array = cmd_arr });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.spawn", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --poll (process.poll)
    if (poll_process_id) |pid| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("processId", std.json.Value{ .string = pid });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.poll", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle --stop (process.stop)
    if (stop_process_id) |pid| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("processId", std.json.Value{ .string = pid });

        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "process.stop", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle canvas
    if (canvas_present) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.present", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_hide) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.hide", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_navigate) |url| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("url", std.json.Value{ .string = url });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.navigate", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_eval) |js| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("js", std.json.Value{ .string = js });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.eval", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }
    if (canvas_snapshot) |path| {
        var params_obj = std.json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("path", std.json.Value{ .string = path });
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "canvas.snapshot", std.json.Value{ .object = params_obj });
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    // Handle exec approvals
    if (exec_approvals_get) {
        try invokeNode(allocator, &ws_client, &ctx, target_node.?, "system.execApprovals.get", null);
        try awaitAndPrintNodeResult(allocator, &ws_client, &ctx);
        return;
    }

    if (exec_allow_cmd) |entry| {
        const added = try addExecAllowlistEntries(allocator, &ws_client, &ctx, target_node.?, &.{entry});
        var stdout = std.fs.File.stdout().deprecatedWriter();
        if (added == 1) {
            try stdout.writeAll("Added 1 allowlist entry.\n");
        } else {
            try stdout.print("Added {d} allowlist entries.\n", .{added});
        }
        return;
    }

    if (exec_allow_file) |path| {
        const entries = try readAllowlistFile(allocator, path);
        defer {
            for (entries) |s| allocator.free(s);
            allocator.free(entries);
        }

        const added = try addExecAllowlistEntries(allocator, &ws_client, &ctx, target_node.?, entries);
        var stdout = std.fs.File.stdout().deprecatedWriter();
        if (added == 1) {
            try stdout.print("Added 1 allowlist entry from {s}.\n", .{path});
        } else {
            try stdout.print("Added {d} allowlist entries from {s}.\n", .{ added, path });
        }
        return;
    }

    // Handle --approve
    if (approve_id) |id| {
        try resolveApproval(allocator, &ws_client, id, "approve");
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Approval {s} approved.", .{id});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --deny
    if (deny_id) |id| {
        try resolveApproval(allocator, &ws_client, id, "deny");
        std.Thread.sleep(500 * std.time.ns_per_ms);
        logger.info("Approval {s} denied.", .{id});

        if (save_config) {
            try config.save(allocator, config_path, cfg);
            logger.info("Config saved to {s}", .{config_path});
        }
        return;
    }

    // Handle --interactive
    if (interactive) {
        try runRepl(allocator, &ws_client, &ctx, &cfg, config_path);
        return;
    }

    // Save config if requested
    if (save_config) {
        try config.save(allocator, config_path, cfg);
        logger.info("Config saved to {s}", .{config_path});
    }

    // Normal receive loop
    while (true) {
        if (!ws_client.is_connected) {
            logger.warn("Disconnected.", .{});
            break;
        }

        const payload = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            ws_client.disconnect();
            break;
        };
        if (payload) |text| {
            defer allocator.free(text);
            logger.info("recv: {s}", .{text});
            const update = event_handler.handleRawMessage(&ctx, text) catch |err| blk: {
                logger.warn("Error handling message: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (update) |auth_update| {
                defer auth_update.deinit(allocator);
                ws_client.storeDeviceToken(
                    auth_update.device_token,
                    auth_update.role,
                    auth_update.scopes,
                    auth_update.issued_at_ms,
                ) catch |err| {
                    logger.warn("Failed to store device token: {s}", .{@errorName(err)});
                };
            }
        } else {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

fn runRepl(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    cfg: *config.Config,
    config_path: []const u8,
) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();
    var stdin = std.fs.File.stdin().deprecatedReader();

    try stdout.writeAll("\nZiggyStarClaw Interactive Mode\n");
    try stdout.writeAll("Type 'help' for commands, 'quit' to exit.\n\n");

    var current_session = cfg.default_session;
    var current_node = cfg.default_node;

    while (true) {
        const session_name = if (current_session) |s| s[0..@min(s.len, 8)] else "none";
        const node_name = if (current_node) |n| n[0..@min(n.len, 8)] else "none";
        try stdout.print("[session:{s} node:{s}]> ", .{ session_name, node_name });

        var input_buffer: [1024]u8 = undefined;
        const line_opt = try stdin.readUntilDelimiterOrEof(&input_buffer, '\n');
        if (line_opt == null) break;

        const input = std.mem.trim(u8, line_opt.?, " \t\r\n");
        if (input.len == 0) continue;

        var parts = std.mem.splitScalar(u8, input, ' ');
        const cmd_str = parts.next() orelse continue;
        const cmd = parseReplCommand(cmd_str);

        switch (cmd) {
            .help => {
                try stdout.writeAll("Commands:\n" ++
                    "  help                    Show this help\n" ++
                    "  send <message>          Send message to current session\n" ++
                    "  session [key]           Show or set current session\n" ++
                    "  sessions                List available sessions\n" ++
                    "  node [id]               Show or set current node\n" ++
                    "  nodes                   List available nodes\n" ++
                    "  run <command>           Run command on current node (system.run)\n" ++
                    "  which <name>            Locate executable on node PATH (system.which)\n" ++
                    "  notify <title>          Show node notification (system.notify)\n" ++
                    "  ps                      List node background processes (process.list)\n" ++
                    "  spawn <command>         Spawn background process (process.spawn)\n" ++
                    "  poll <processId>        Poll process status (process.poll)\n" ++
                    "  stop <processId>        Stop process (process.stop)\n" ++
                    "  canvas <op> [args...]   Canvas ops: present|hide|navigate <url>|eval <js>|snapshot <path>\n" ++
                    "  approvals               List pending approvals\n" ++
                    "  approve <id>            Approve request by ID\n" ++
                    "  deny <id>               Deny request by ID\n" ++
                    "  save                    Save current session/node to config\n" ++
                    "  quit/exit               Exit interactive mode\n");
            },
            .send => {
                const message = parts.rest();
                if (message.len == 0) {
                    try stdout.writeAll("Usage: send <message>\n");
                    continue;
                }
                const target_session = current_session orelse blk: {
                    if (ctx.sessions.items.len == 0) {
                        try stdout.writeAll("No sessions available. Use 'sessions' to list.\n");
                        continue;
                    }
                    break :blk ctx.sessions.items[0].key;
                };
                try sendChatMessage(allocator, ws_client, target_session, message);
                try stdout.writeAll("Message sent.\n");
            },
            .session => {
                const new_session = parts.rest();
                if (new_session.len == 0) {
                    if (current_session) |s| {
                        try stdout.print("Current session: {s}\n", .{s});
                    } else {
                        try stdout.writeAll("No current session. Use 'session <key>' to set.\n");
                    }
                } else {
                    current_session = try allocator.dupe(u8, new_session);
                    try stdout.print("Session set to: {s}\n", .{current_session.?});
                }
            },
            .sessions => {
                try stdout.writeAll("Available sessions:\n");
                if (ctx.sessions.items.len == 0) {
                    try stdout.writeAll("  (no sessions available)\n");
                } else {
                    for (ctx.sessions.items) |session| {
                        const display = session.display_name orelse session.key;
                        const label = session.label orelse "-";
                        try stdout.print("  {s} | {s} | {s}\n", .{ session.key, display, label });
                    }
                }
            },
            .node => {
                const new_node = parts.rest();
                if (new_node.len == 0) {
                    if (current_node) |n| {
                        try stdout.print("Current node: {s}\n", .{n});
                    } else {
                        try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    }
                } else {
                    current_node = try allocator.dupe(u8, new_node);
                    try stdout.print("Node set to: {s}\n", .{current_node.?});
                }
            },
            .nodes => {
                try stdout.writeAll("Available nodes:\n");
                if (ctx.nodes.items.len == 0) {
                    try stdout.writeAll("  (no nodes available)\n");
                } else {
                    for (ctx.nodes.items) |node| {
                        const display = node.display_name orelse node.id;
                        const platform = node.platform orelse "-";
                        const status = if (node.connected orelse false) "connected" else "disconnected";
                        try stdout.print("  {s} | {s} | {s} | {s}\n", .{ node.id, display, platform, status });
                    }
                }
            },
            .run => {
                const command = parts.rest();
                if (command.len == 0) {
                    try stdout.writeAll("Usage: run <command>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                try runNodeCommand(allocator, ws_client, ctx, target_node, command);
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .which => {
                const name = parts.rest();
                if (name.len == 0) {
                    try stdout.writeAll("Usage: which <name>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("name", std.json.Value{ .string = name });
                try invokeNode(allocator, ws_client, ctx, target_node, "system.which", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .notify => {
                const title = parts.rest();
                if (title.len == 0) {
                    try stdout.writeAll("Usage: notify <title>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("title", std.json.Value{ .string = title });
                try invokeNode(allocator, ws_client, ctx, target_node, "system.notify", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .ps => {
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                try invokeNode(allocator, ws_client, ctx, target_node, "process.list", null);
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .spawn => {
                const command = parts.rest();
                if (command.len == 0) {
                    try stdout.writeAll("Usage: spawn <command>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                var cmd_arr = try buildJsonCommandArray(allocator, command);
                defer freeJsonStringArray(allocator, &cmd_arr);
                try params_obj.put("command", std.json.Value{ .array = cmd_arr });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.spawn", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .poll => {
                const pid = parts.rest();
                if (pid.len == 0) {
                    try stdout.writeAll("Usage: poll <processId>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("processId", std.json.Value{ .string = pid });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.poll", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .stop => {
                const pid = parts.rest();
                if (pid.len == 0) {
                    try stdout.writeAll("Usage: stop <processId>\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var params_obj = std.json.ObjectMap.init(allocator);
                defer params_obj.deinit();
                try params_obj.put("processId", std.json.Value{ .string = pid });
                try invokeNode(allocator, ws_client, ctx, target_node, "process.stop", std.json.Value{ .object = params_obj });
                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .canvas => {
                const rest = parts.rest();
                if (rest.len == 0) {
                    try stdout.writeAll("Usage: canvas <present|hide|navigate|eval|snapshot> [args...]\n");
                    continue;
                }
                const target_node = current_node orelse {
                    try stdout.writeAll("No current node. Use 'node <id>' to set.\n");
                    continue;
                };
                var subparts = std.mem.splitScalar(u8, rest, ' ');
                const op = subparts.next() orelse continue;
                const arg = std.mem.trim(u8, subparts.rest(), " \t\r\n");

                if (std.mem.eql(u8, op, "present")) {
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.present", null);
                } else if (std.mem.eql(u8, op, "hide")) {
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.hide", null);
                } else if (std.mem.eql(u8, op, "navigate")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas navigate <url>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("url", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.navigate", std.json.Value{ .object = params_obj });
                } else if (std.mem.eql(u8, op, "eval")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas eval <js>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("js", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.eval", std.json.Value{ .object = params_obj });
                } else if (std.mem.eql(u8, op, "snapshot")) {
                    if (arg.len == 0) {
                        try stdout.writeAll("Usage: canvas snapshot <path>\n");
                        continue;
                    }
                    var params_obj = std.json.ObjectMap.init(allocator);
                    defer params_obj.deinit();
                    try params_obj.put("path", std.json.Value{ .string = arg });
                    try invokeNode(allocator, ws_client, ctx, target_node, "canvas.snapshot", std.json.Value{ .object = params_obj });
                } else {
                    try stdout.print("Unknown canvas op: {s}\n", .{op});
                    continue;
                }

                try awaitAndPrintNodeResult(allocator, ws_client, ctx);
            },
            .approvals => {
                try stdout.writeAll("Pending approvals:\n");
                if (ctx.approvals.items.len == 0) {
                    try stdout.writeAll("  (no pending approvals)\n");
                } else {
                    for (ctx.approvals.items) |approval| {
                        const summary = approval.summary orelse "(no summary)";
                        try stdout.print("  {s} | {s}\n", .{ approval.id, summary });
                    }
                }
            },
            .approve => {
                const id = parts.rest();
                if (id.len == 0) {
                    try stdout.writeAll("Usage: approve <id>\n");
                    continue;
                }
                try resolveApproval(allocator, ws_client, id, "approve");
                try stdout.writeAll("Approval sent.\n");
            },
            .deny => {
                const id = parts.rest();
                if (id.len == 0) {
                    try stdout.writeAll("Usage: deny <id>\n");
                    continue;
                }
                try resolveApproval(allocator, ws_client, id, "deny");
                try stdout.writeAll("Denial sent.\n");
            },
            .quit, .exit => {
                try stdout.writeAll("Goodbye!\n");
                break;
            },
            .save => {
                if (current_session) |s| {
                    if (cfg.default_session) |old| {
                        if (!(old.ptr == s.ptr and old.len == s.len)) {
                            allocator.free(old);
                            cfg.default_session = try allocator.dupe(u8, s);
                        }
                    } else {
                        cfg.default_session = try allocator.dupe(u8, s);
                    }
                }
                if (current_node) |n| {
                    if (cfg.default_node) |old| {
                        if (!(old.ptr == n.ptr and old.len == n.len)) {
                            allocator.free(old);
                            cfg.default_node = try allocator.dupe(u8, n);
                        }
                    } else {
                        cfg.default_node = try allocator.dupe(u8, n);
                    }
                }
                try config.save(allocator, config_path, cfg.*);
                try stdout.writeAll("Config saved.\n");
            },
            .unknown => {
                try stdout.print("Unknown command: {s}. Type 'help' for available commands.\n", .{cmd_str});
            },
        }

        var processed = false;
        while (!processed) {
            const payload = ws_client.receive() catch |err| {
                logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
                break;
            };
            if (payload) |text| {
                defer allocator.free(text);
                _ = event_handler.handleRawMessage(ctx, text) catch |err| blk: {
                    logger.warn("Error handling message: {s}", .{@errorName(err)});
                    break :blk null;
                };
            } else {
                processed = true;
            }
        }
    }
}

fn parseReplCommand(cmd: []const u8) ReplCommand {
    if (std.mem.eql(u8, cmd, "help")) return .help;
    if (std.mem.eql(u8, cmd, "send")) return .send;
    if (std.mem.eql(u8, cmd, "session")) return .session;
    if (std.mem.eql(u8, cmd, "sessions")) return .sessions;
    if (std.mem.eql(u8, cmd, "node")) return .node;
    if (std.mem.eql(u8, cmd, "nodes")) return .nodes;
    if (std.mem.eql(u8, cmd, "run")) return .run;
    if (std.mem.eql(u8, cmd, "which")) return .which;
    if (std.mem.eql(u8, cmd, "notify")) return .notify;
    if (std.mem.eql(u8, cmd, "ps")) return .ps;
    if (std.mem.eql(u8, cmd, "spawn")) return .spawn;
    if (std.mem.eql(u8, cmd, "poll")) return .poll;
    if (std.mem.eql(u8, cmd, "stop")) return .stop;
    if (std.mem.eql(u8, cmd, "canvas")) return .canvas;
    if (std.mem.eql(u8, cmd, "approvals")) return .approvals;
    if (std.mem.eql(u8, cmd, "approve")) return .approve;
    if (std.mem.eql(u8, cmd, "deny")) return .deny;
    if (std.mem.eql(u8, cmd, "quit")) return .quit;
    if (std.mem.eql(u8, cmd, "exit")) return .exit;
    if (std.mem.eql(u8, cmd, "save")) return .save;
    return .unknown;
}

fn requestSessionsList(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const sessions_proto = @import("protocol/sessions.zig");
    const params = sessions_proto.SessionsListParams{
        .includeGlobal = true,
        .includeUnknown = true,
    };
    const request = try requests.buildRequestPayload(allocator, "sessions.list", params);
    defer allocator.free(request.payload);

    // Only mark pending if send succeeds.
    logger.info("Requesting sessions.list", .{});
    try ws_client.send(request.payload);
    ctx.setPendingSessionsRequest(request.id);
}

fn requestNodesList(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const params = nodes_proto.NodeListParams{};
    const request = try requests.buildRequestPayload(allocator, "node.list", params);
    defer allocator.free(request.payload);

    // Only mark pending if send succeeds.
    logger.info("Requesting node.list", .{});
    try ws_client.send(request.payload);
    ctx.setPendingNodesRequest(request.id);
}

fn sendChatMessage(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    target_session: []const u8,
    message: []const u8,
) !void {
    const idempotency_key = try requests.makeRequestId(allocator);
    defer allocator.free(idempotency_key);

    const params = chat.ChatSendParams{
        .sessionKey = target_session,
        .message = message,
        .idempotencyKey = idempotency_key,
    };

    const request = try requests.buildRequestPayload(allocator, "chat.send", params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    logger.info("Sending message to session {s}: {s}", .{ target_session, message });
    try ws_client.send(request.payload);
}

fn parseCommandLineArgs(allocator: std.mem.Allocator, cmdline: []const u8) !std.ArrayList([]u8) {
    // Very small shell-ish tokenizer:
    // - splits on whitespace
    // - supports single and double quotes
    // - supports backslash escaping outside quotes and inside double quotes
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var cur = std.ArrayList(u8).empty;
    defer cur.deinit(allocator);

    const State = enum { none, single, double };
    var state: State = .none;

    var i: usize = 0;
    while (i < cmdline.len) : (i += 1) {
        const c = cmdline[i];

        // Whitespace ends token (only when not in quotes)
        if (state == .none and (c == ' ' or c == '\t' or c == '\n' or c == '\r')) {
            if (cur.items.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, cur.items));
                cur.clearRetainingCapacity();
            }
            continue;
        }

        // Quote handling
        if (state == .none and c == '\'') {
            state = .single;
            continue;
        }
        if (state == .none and c == '"') {
            state = .double;
            continue;
        }
        if (state == .single and c == '\'') {
            state = .none;
            continue;
        }
        if (state == .double and c == '"') {
            state = .none;
            continue;
        }

        // Backslash escaping
        if ((state == .none or state == .double) and c == '\\' and i + 1 < cmdline.len) {
            i += 1;
            try cur.append(allocator, cmdline[i]);
            continue;
        }

        try cur.append(allocator, c);
    }

    if (cur.items.len > 0) {
        try out.append(allocator, try allocator.dupe(u8, cur.items));
    }

    return out;
}

fn buildJsonCommandArray(allocator: std.mem.Allocator, cmdline: []const u8) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    errdefer arr.deinit();

    var argv = try parseCommandLineArgs(allocator, cmdline);
    defer {
        for (argv.items) |s| allocator.free(s);
        argv.deinit(allocator);
    }

    for (argv.items) |part| {
        if (part.len == 0) continue;
        try arr.append(std.json.Value{ .string = try allocator.dupe(u8, part) });
    }

    return arr;
}

fn freeJsonStringArray(allocator: std.mem.Allocator, arr: *std.json.Array) void {
    for (arr.items) |item| {
        if (item == .string) allocator.free(item.string);
    }
    arr.deinit();
}

fn invokeNode(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    command: []const u8,
    params_value: ?std.json.Value,
) !void {
    const idempotency_key = try requests.makeRequestId(allocator);
    defer allocator.free(idempotency_key);

    const params = nodes_proto.NodeInvokeParams{
        .nodeId = target_node,
        .command = command,
        .params = params_value,
        .idempotencyKey = idempotency_key,
    };

    const request = try requests.buildRequestPayload(allocator, "node.invoke", params);
    defer allocator.free(request.payload);

    // Mark as pending so response routing can populate ctx.node_result.
    ctx.setPendingNodeInvokeRequest(request.id);

    logger.info("Invoking node {s}: {s}", .{ target_node, command });
    try ws_client.send(request.payload);
}

fn awaitNodeResultOwned(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !?[]u8 {
    // Wait for result
    var wait_attempts: u32 = 0;
    while (wait_attempts < 150 and ctx.node_result == null) : (wait_attempts += 1) {
        const payload = ws_client.receive() catch |err| {
            logger.err("WebSocket receive failed: {s}", .{@errorName(err)});
            break;
        };
        if (payload) |text| {
            defer allocator.free(text);
            _ = event_handler.handleRawMessage(ctx, text) catch |err| blk: {
                logger.warn("Error handling message: {s}", .{@errorName(err)});
                break :blk null;
            };
        } else {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    if (ctx.node_result) |result| {
        const owned = try allocator.dupe(u8, result);
        ctx.clearNodeResult();
        return owned;
    }

    return null;
}

fn awaitAndPrintNodeResult(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
) !void {
    const res = try awaitNodeResultOwned(allocator, ws_client, ctx);
    if (res) |owned| {
        defer allocator.free(owned);
        try printNodeResult(allocator, owned);
    } else {
        logger.info("Command sent. Waiting for result timed out.", .{});
    }
}

fn readAllowlistFile(allocator: std.mem.Allocator, path: []const u8) ![]const []u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    // Supported formats:
    // 1) ["cmd1", "cmd2"]
    // 2) {"allowlist": ["cmd1", ...]}
    var arr_val: ?std.json.Value = null;
    if (parsed.value == .array) {
        arr_val = parsed.value;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("allowlist")) |v| {
            if (v == .array) arr_val = v;
        }
    }

    const arr = arr_val orelse return error.InvalidArguments;

    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    for (arr.array.items) |it| {
        if (it == .string and it.string.len > 0) {
            try out.append(allocator, try allocator.dupe(u8, it.string));
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn parseAllowlistFromInvokeResult(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList([]u8) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var allow = std.ArrayList([]u8).empty;
    errdefer {
        for (allow.items) |s| allocator.free(s);
        allow.deinit(allocator);
    }

    if (parsed.value == .object) {
        const obj = parsed.value.object;

        // Accept both shapes:
        // 1) node.invoke response: { ok, nodeId, command, payload: { allowlist: [...] } }
        // 2) raw handler payload (future-proof): { allowlist: [...] }
        var alist_opt: ?std.json.Value = null;

        if (obj.get("payload")) |payload| {
            if (payload == .object) {
                if (payload.object.get("allowlist")) |alist| alist_opt = alist;
            }
        }
        if (alist_opt == null) {
            if (obj.get("allowlist")) |alist| alist_opt = alist;
        }

        if (alist_opt) |alist| {
            if (alist == .array) {
                for (alist.array.items) |it| {
                    if (it == .string) try allow.append(allocator, try allocator.dupe(u8, it.string));
                }
            }
        }
    }

    return allow;
}

fn addExecAllowlistEntries(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    new_entries: []const []const u8,
) !u32 {
    // 1) Get current approvals
    try invokeNode(allocator, ws_client, ctx, target_node, "system.execApprovals.get", null);
    const raw_owned = (try awaitNodeResultOwned(allocator, ws_client, ctx)) orelse {
        return error.Unexpected;
    };
    defer allocator.free(raw_owned);

    var allow = try parseAllowlistFromInvokeResult(allocator, raw_owned);
    defer {
        for (allow.items) |s| allocator.free(s);
        allow.deinit(allocator);
    }

    var added: u32 = 0;
    for (new_entries) |entry| {
        if (entry.len == 0) continue;
        var exists = false;
        for (allow.items) |s| {
            if (std.mem.eql(u8, s, entry)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try allow.append(allocator, try allocator.dupe(u8, entry));
            added += 1;
        }
    }

    if (added == 0) return 0;

    // 2) Set approvals (mode=allowlist)
    var params_obj = std.json.ObjectMap.init(allocator);
    defer params_obj.deinit();
    try params_obj.put("mode", std.json.Value{ .string = "allowlist" });

    var allow_arr = std.json.Array.init(allocator);
    defer {
        for (allow_arr.items) |it| if (it == .string) allocator.free(it.string);
        allow_arr.deinit();
    }

    for (allow.items) |s| {
        try allow_arr.append(std.json.Value{ .string = try allocator.dupe(u8, s) });
    }
    try params_obj.put("allowlist", std.json.Value{ .array = allow_arr });

    try invokeNode(allocator, ws_client, ctx, target_node, "system.execApprovals.set", std.json.Value{ .object = params_obj });
    _ = try awaitNodeResultOwned(allocator, ws_client, ctx);

    return added;
}

fn printNodeResult(allocator: std.mem.Allocator, result: []const u8) !void {
    var stdout = std.fs.File.stdout().deprecatedWriter();

    // Try parse JSON for nicer output.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch null;
    if (parsed) |tree| {
        defer tree.deinit();

        if (tree.value == .object) {
            const obj = tree.value.object;
            // Common shape for system.run in this repo: { stdout, stderr, exitCode }
            if (obj.get("stdout") != null or obj.get("stderr") != null or obj.get("exitCode") != null) {
                const exit_code = obj.get("exitCode");
                if (exit_code) |ec| {
                    switch (ec) {
                        .integer => try stdout.print("exitCode: {d}\n", .{ec.integer}),
                        .float => try stdout.print("exitCode: {d}\n", .{@as(i64, @intFromFloat(ec.float))}),
                        else => {},
                    }
                }

                if (obj.get("stdout")) |outv| {
                    if (outv == .string and outv.string.len > 0) {
                        try stdout.writeAll("stdout:\n");
                        try stdout.writeAll(outv.string);
                        if (!std.mem.endsWith(u8, outv.string, "\n")) try stdout.writeByte('\n');
                    }
                }
                if (obj.get("stderr")) |errv| {
                    if (errv == .string and errv.string.len > 0) {
                        try stdout.writeAll("stderr:\n");
                        try stdout.writeAll(errv.string);
                        if (!std.mem.endsWith(u8, errv.string, "\n")) try stdout.writeByte('\n');
                    }
                }
                return;
            }
        }

        // Generic JSON pretty print.
        try stdout.print("{f}\n", .{std.json.fmt(tree.value, .{ .whitespace = .indent_2 })});
        return;
    }

    try stdout.print("Result: {s}\n", .{result});
}

fn runNodeCommand(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    ctx: *client_state.ClientContext,
    target_node: []const u8,
    command: []const u8,
) !void {
    var params_json = std.json.ObjectMap.init(allocator);
    defer params_json.deinit();

    var command_arr = try buildJsonCommandArray(allocator, command);
    defer freeJsonStringArray(allocator, &command_arr);

    try params_json.put("command", std.json.Value{ .array = command_arr });

    try invokeNode(allocator, ws_client, ctx, target_node, "system.run", std.json.Value{ .object = params_json });
}

fn resolveApproval(
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    approval_id: []const u8,
    decision: []const u8,
) !void {
    const params = approvals_proto.ExecApprovalResolveParams{
        .id = approval_id,
        .decision = decision,
    };

    const request = try requests.buildRequestPayload(allocator, "exec.approval.resolve", params);
    defer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    logger.info("Resolving approval {s} with decision: {s}", .{ approval_id, decision });
    try ws_client.send(request.payload);
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

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}
