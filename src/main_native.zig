const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui/main_window.zig");
const input_router = @import("ui/input/input_router.zig");
const operator_view = @import("ui/operator_view.zig");
const theme = @import("ui/theme.zig");
const theme_engine = @import("ui/theme_engine/theme_engine.zig");
const profile = @import("ui/theme_engine/profile.zig");
const panel_manager = @import("ui/panel_manager.zig");
const workspace_store = @import("ui/workspace_store.zig");
const workspace = @import("ui/workspace.zig");
const ui_command_inbox = @import("ui/ui_command_inbox.zig");
const image_cache = @import("ui/image_cache.zig");
const attachment_cache = @import("ui/attachment_cache.zig");
const client_state = @import("client/state.zig");
const agent_registry = @import("client/agent_registry.zig");
const session_keys = @import("client/session_keys.zig");
const config = @import("client/config.zig");
const unified_config = @import("unified_config.zig");
const app_state = @import("client/app_state.zig");
const event_handler = @import("client/event_handler.zig");
const websocket_client = @import("openclaw_transport.zig").websocket;
const update_checker = @import("client/update_checker.zig");
const build_options = @import("build_options");
const logger = @import("utils/logger.zig");
const profiler = @import("utils/profiler.zig");
const requests = @import("protocol/requests.zig");
const sessions_proto = @import("protocol/sessions.zig");
const chat_proto = @import("protocol/chat.zig");
const nodes_proto = @import("protocol/nodes.zig");
const approvals_proto = @import("protocol/approvals.zig");
const types = @import("protocol/types.zig");
const sdl = @import("platform/sdl3.zig").c;
const input_backend = @import("ui/input/input_backend.zig");
const sdl_input_backend = @import("ui/input/sdl_input_backend.zig");
const text_input_backend = @import("ui/input/text_input_backend.zig");
const command_queue = @import("ui/render/command_queue.zig");
const input_state = @import("ui/input/input_state.zig");
const ui_commands = @import("ui/render/command_list.zig");

const multi_renderer = @import("client/multi_window_renderer.zig");
const font_system = @import("ui/font_system.zig");

const icon = @cImport({
    @cInclude("icon_loader.h");
});

const startup_log_path = "ziggystarclaw_startup.log";

const UiWindow = struct {
    window: *sdl.SDL_Window,
    id: u32,
    queue: input_state.InputQueue,
    swapchain: multi_renderer.WindowSwapchain,
    manager: panel_manager.PanelManager,
    ui_state: ui.WindowUiState = .{},
    title: []u8,
    persist_in_workspace: bool = false,
    profile_override: ?theme_engine.ProfileId = null,
    theme_mode_override: ?theme.Mode = null,
    image_sampling_override: ?ui_commands.ImageSampling = null,
    pixel_snap_textured_override: ?bool = null,
};

const ThemePackBrowse = struct {
    mutex: std.Thread.Mutex = .{},
    in_flight: bool = false,
    target: enum { config, window_override } = .config,
    target_window_id: u32 = 0,
    // Allocated with std.heap.c_allocator by the SDL callback, then consumed on the main thread.
    pending_path: ?[]u8 = null,
    pending_error: bool = false,
};

var theme_pack_browse: ThemePackBrowse = .{};

const ThemePackWatch = struct {
    last_root_hash: u64 = 0,
    last_sig: u64 = 0,
    pending_sig: u64 = 0,
    pending_at_ms: i64 = 0,
    next_poll_ms: i64 = 0,
};

fn hashStat(hasher: *std.hash.Wyhash, st: std.fs.File.Stat) void {
    hasher.update(std.mem.asBytes(&st.size));
    hasher.update(std.mem.asBytes(&st.mtime));
}

fn hashFileMaybe(hasher: *std.hash.Wyhash, dir: *std.fs.Dir, rel: []const u8) void {
    hasher.update(rel);
    const st = dir.statFile(rel) catch {
        hasher.update("!missing");
        return;
    };
    hashStat(hasher, st);
}

fn hashSubdirJsonFiles(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, dir: *std.fs.Dir, subdir: []const u8) void {
    hasher.update(subdir);
    var d = dir.openDir(subdir, .{ .iterate = true }) catch {
        hasher.update("!no_dir");
        return;
    };
    defer d.close();

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = d.iterate();

    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name_copy = allocator.dupe(u8, entry.name) catch {
            hasher.update("!oom");
            return;
        };
        names.append(allocator, name_copy) catch {
            allocator.free(name_copy);
            hasher.update("!oom");
            return;
        };
    }

    std.mem.sortUnstable([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        hasher.update(name);
        const st = d.statFile(name) catch {
            hasher.update("!stat_err");
            continue;
        };
        hashStat(hasher, st);
    }
}

fn computeThemePackJsonSignature(allocator: std.mem.Allocator, root_path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("zsc.theme_pack.sig.v1");

    var dir = if (std.fs.path.isAbsolute(root_path))
        std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch return 0
    else
        std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    hashFileMaybe(&hasher, &dir, "manifest.json");
    hashFileMaybe(&hasher, &dir, "windows.json");
    hashSubdirJsonFiles(allocator, &hasher, &dir, "tokens");
    hashSubdirJsonFiles(allocator, &hasher, &dir, "profiles");
    hashSubdirJsonFiles(allocator, &hasher, &dir, "styles");
    hashSubdirJsonFiles(allocator, &hasher, &dir, "layouts");
    return hasher.final();
}

fn computeFileSignature(path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("zsc.file.sig.v1");
    hasher.update(path);
    const st = std.fs.cwd().statFile(path) catch return 0;
    hashStat(&hasher, st);
    return hasher.final();
}

fn resolveThemePackWatchTargetAlloc(allocator: std.mem.Allocator, raw_path: []const u8) ?[]u8 {
    if (raw_path.len == 0) return null;

    // Absolute paths: just resolve and use directly.
    if (std.fs.path.isAbsolute(raw_path)) {
        return std.fs.cwd().realpathAlloc(allocator, raw_path) catch null;
    }

    // First try relative to current working directory.
    if (std.fs.cwd().access(raw_path, .{})) |_| {
        return std.fs.cwd().realpathAlloc(allocator, raw_path) catch null;
    } else |_| {}

    // Then try relative to the executable directory (production builds).
    const exe = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe);
    const exe_dir = std.fs.path.dirname(exe) orelse return null;
    const joined = std.fs.path.join(allocator, &.{ exe_dir, raw_path }) catch return null;
    defer allocator.free(joined);
    return std.fs.cwd().realpathAlloc(allocator, joined) catch null;
}

fn updateThemePackWatch(
    allocator: std.mem.Allocator,
    watch: *ThemePackWatch,
    theme_eng: *theme_engine.ThemeEngine,
    cfg: *const config.Config,
    pack_applied_this_frame: bool,
) void {
    if (!cfg.ui_watch_theme_pack) {
        watch.* = .{};
        return;
    }

    const raw = cfg.ui_theme_pack orelse "";
    if (raw.len == 0) return;

    const resolved = resolveThemePackWatchTargetAlloc(allocator, raw) orelse return;
    defer allocator.free(resolved);

    const is_zip = resolved.len >= 4 and std.ascii.eqlIgnoreCase(resolved[resolved.len - 4 ..], ".zip");
    const root = if (is_zip) resolved else themePackRootFromSelection(resolved);

    const root_hash = std.hash.Wyhash.hash(0, root);
    if (root_hash != watch.last_root_hash or watch.last_sig == 0 or pack_applied_this_frame) {
        watch.last_root_hash = root_hash;
        watch.last_sig = if (is_zip) computeFileSignature(root) else computeThemePackJsonSignature(allocator, root);
        watch.pending_sig = 0;
        watch.pending_at_ms = 0;
        watch.next_poll_ms = 0;
        return;
    }

    const now_ms: i64 = std.time.milliTimestamp();
    if (watch.next_poll_ms != 0 and now_ms < watch.next_poll_ms) return;
    watch.next_poll_ms = now_ms + 500;

    const sig = if (is_zip) computeFileSignature(root) else computeThemePackJsonSignature(allocator, root);
    if (sig == 0 or sig == watch.last_sig) {
        watch.pending_sig = 0;
        watch.pending_at_ms = 0;
        return;
    }

    // Debounce: require the signature to remain stable for >=250ms before reloading.
    if (watch.pending_sig != sig) {
        watch.pending_sig = sig;
        watch.pending_at_ms = now_ms;
        return;
    }
    if (now_ms - watch.pending_at_ms < 250) return;

    theme_eng.activateThemePackForRender(cfg.ui_theme_pack, true) catch {};
    watch.last_sig = sig;
    watch.pending_sig = 0;
    watch.pending_at_ms = 0;
}

fn dirHasManifest(path: []const u8) bool {
    if (path.len == 0) return false;
    var dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{}) catch return false
    else
        std.fs.cwd().openDir(path, .{}) catch return false;
    defer dir.close();
    const f = dir.openFile("manifest.json", .{}) catch return false;
    f.close();
    return true;
}

fn themePackRootFromSelection(selection: []const u8) []const u8 {
    // If the user selects a subdirectory inside a pack, walk upward until we find `manifest.json`.
    var cur = selection;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (dirHasManifest(cur)) return cur;
        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len == 0 or parent.len == cur.len) break;
        cur = parent;
    }
    return selection;
}

fn sdlDialogPickThemePack(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = userdata;
    _ = filter;

    // NOTE: callback may run on another thread.
    theme_pack_browse.mutex.lock();
    defer theme_pack_browse.mutex.unlock();
    theme_pack_browse.in_flight = false;

    if (theme_pack_browse.pending_path) |buf| {
        std.heap.c_allocator.free(buf);
        theme_pack_browse.pending_path = null;
    }
    theme_pack_browse.pending_error = false;

    if (filelist == null) {
        theme_pack_browse.pending_error = true;
        return;
    }
    const first = filelist[0];
    if (first == null) {
        // canceled
        return;
    }
    const picked = std.mem.span(@as([*:0]const u8, @ptrCast(first)));
    if (picked.len == 0) return;

    const copy = std.heap.c_allocator.dupe(u8, picked) catch return;
    theme_pack_browse.pending_path = copy;
}

fn destroyUiWindow(allocator: std.mem.Allocator, w: *UiWindow) void {
    w.queue.deinit(allocator);
    w.ui_state.deinit(allocator);
    w.swapchain.deinit();
    w.manager.deinit();
    allocator.free(w.title);
    sdl.SDL_DestroyWindow(w.window);
    allocator.destroy(w);
}

fn cloneWorkspace(allocator: std.mem.Allocator, src: *const workspace.Workspace) !workspace.Workspace {
    var snap = try src.toSnapshot(allocator);
    defer snap.deinit(allocator);
    return try workspace.Workspace.fromSnapshot(allocator, snap);
}

fn remapWorkspacePanelIds(
    allocator: std.mem.Allocator,
    ws: *workspace.Workspace,
    next_panel_id: *workspace.PanelId,
) !void {
    var map = std.AutoHashMap(workspace.PanelId, workspace.PanelId).init(allocator);
    defer map.deinit();

    for (ws.panels.items) |*panel| {
        const old = panel.id;
        const new_id = next_panel_id.*;
        next_panel_id.* += 1;
        panel.id = new_id;
        try map.put(old, new_id);
    }

    if (ws.focused_panel_id) |old_focus| {
        ws.focused_panel_id = map.get(old_focus);
    }
}

fn cloneWorkspaceRemap(
    allocator: std.mem.Allocator,
    src: *const workspace.Workspace,
    next_panel_id: *workspace.PanelId,
) !workspace.Workspace {
    var ws = try cloneWorkspace(allocator, src);
    errdefer ws.deinit(allocator);
    try remapWorkspacePanelIds(allocator, &ws, next_panel_id);
    return ws;
}

fn parsePanelKindLabel(label: []const u8) ?workspace.PanelKind {
    if (std.ascii.eqlIgnoreCase(label, "workspace") or std.ascii.eqlIgnoreCase(label, "control")) return .Control;
    if (std.ascii.eqlIgnoreCase(label, "chat")) return .Chat;
    if (std.ascii.eqlIgnoreCase(label, "showcase")) return .Showcase;
    if (std.ascii.eqlIgnoreCase(label, "code_editor") or std.ascii.eqlIgnoreCase(label, "codeeditor")) return .CodeEditor;
    if (std.ascii.eqlIgnoreCase(label, "tool_output") or std.ascii.eqlIgnoreCase(label, "tooloutput")) return .ToolOutput;
    return null;
}

fn parseImageSamplingLabel(label: ?[]const u8) ui_commands.ImageSampling {
    const v = label orelse return .linear;
    if (std.ascii.eqlIgnoreCase(v, "nearest")) return .nearest;
    return .linear;
}

fn labelForImageSampling(s: ui_commands.ImageSampling) []const u8 {
    return switch (s) {
        .linear => "linear",
        .nearest => "nearest",
    };
}

fn defaultWindowSizeForPanelKind(kind: workspace.PanelKind) struct { w: c_int, h: c_int } {
    return switch (kind) {
        .Chat => .{ .w = 560, .h = 720 },
        .Control => .{ .w = 960, .h = 720 },
        .Showcase => .{ .w = 900, .h = 720 },
        .CodeEditor => .{ .w = 960, .h = 720 },
        .ToolOutput => .{ .w = 720, .h = 520 },
    };
}

fn takeWorkspaceFromManager(allocator: std.mem.Allocator, manager: *panel_manager.PanelManager) workspace.Workspace {
    const ws = manager.workspace;
    manager.workspace = workspace.Workspace.initEmpty(allocator);
    return ws;
}

fn buildWorkspaceFromTemplate(
    allocator: std.mem.Allocator,
    tpl: theme_engine.runtime.WindowTemplate,
    next_panel_id: *workspace.PanelId,
) !workspace.Workspace {
    var manager = panel_manager.PanelManager.init(allocator, workspace.Workspace.initEmpty(allocator), next_panel_id);
    errdefer manager.deinit();

    var opened_any = false;
    if (tpl.panels) |labels| {
        for (labels) |label| {
            const kind = parsePanelKindLabel(label) orelse continue;
            manager.ensurePanel(kind);
            opened_any = true;
        }
    }

    if (!opened_any) {
        manager.ensurePanel(.Control);
    }

    if (tpl.focused_panel) |label| {
        if (parsePanelKindLabel(label)) |focus_kind| {
            for (manager.workspace.panels.items) |panel| {
                if (panel.kind == focus_kind) {
                    manager.focusPanel(panel.id);
                    break;
                }
            }
        }
    }

    defer manager.deinit();
    return takeWorkspaceFromManager(allocator, &manager);
}

fn createUiWindow(
    allocator: std.mem.Allocator,
    shared: *multi_renderer.Shared,
    title: [:0]const u8,
    width: c_int,
    height: c_int,
    flags: sdl.SDL_WindowFlags,
    initial_workspace: workspace.Workspace,
    next_panel_id: *workspace.PanelId,
    persist_in_workspace: bool,
    apply_theme_layout_preset: bool,
    profile_override: ?theme_engine.ProfileId,
    theme_mode_override: ?theme.Mode,
    image_sampling_override: ?ui_commands.ImageSampling,
    pixel_snap_textured_override: ?bool,
) !*UiWindow {
    var ws = initial_workspace;
    errdefer ws.deinit(allocator);

    const win = sdl.SDL_CreateWindow(title, width, height, flags) orelse {
        logger.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlWindowCreateFailed;
    };
    errdefer sdl.SDL_DestroyWindow(win);
    setWindowIcon(win);
    multi_renderer.cachePlatformHandlesFromWindow(win);
    logSurfaceBackend(win);

    var swapchain = try multi_renderer.WindowSwapchain.initOwned(shared, win);
    errdefer swapchain.deinit();

    const title_copy = try allocator.dupe(u8, std.mem.sliceTo(title, 0));
    errdefer allocator.free(title_copy);

    const out = try allocator.create(UiWindow);
    errdefer allocator.destroy(out);
    out.* = .{
        .window = win,
        .id = sdl.SDL_GetWindowID(win),
        .queue = input_state.InputQueue.init(allocator),
        .swapchain = swapchain,
        .manager = panel_manager.PanelManager.init(allocator, ws, next_panel_id),
        .ui_state = .{ .theme_layout_presets_enabled = apply_theme_layout_preset },
        .title = title_copy,
        .persist_in_workspace = persist_in_workspace,
        .profile_override = profile_override,
        .theme_mode_override = theme_mode_override,
        .image_sampling_override = image_sampling_override,
        .pixel_snap_textured_override = pixel_snap_textured_override,
    };
    errdefer out.queue.deinit(allocator);
    return out;
}

fn setWindowIcon(window: *sdl.SDL_Window) void {
    const icon_png = @embedFile("icons/ZiggyStarClaw_Icon.png");
    var width: c_int = 0;
    var height: c_int = 0;
    const pixels = icon.zsc_load_icon_rgba_from_memory(icon_png.ptr, @intCast(icon_png.len), &width, &height);
    if (pixels == null or width <= 0 or height <= 0) return;
    defer icon.zsc_free_icon(pixels);
    const pitch: c_int = width * 4;
    const surface = sdl.SDL_CreateSurfaceFrom(width, height, sdl.SDL_PIXELFORMAT_RGBA32, pixels, pitch);
    if (surface == null) return;
    defer sdl.SDL_DestroySurface(surface);
    _ = sdl.SDL_SetWindowIcon(window, surface);
}

fn logSurfaceBackend(window: *sdl.SDL_Window) void {
    const props = sdl.SDL_GetWindowProperties(window);
    const win32 = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
    const cocoa = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
    const wayland_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    const wayland_surface = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    const x11_display = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
    const x11_window = sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);

    var backend: []const u8 = "unknown";
    if (win32 != null) {
        backend = "win32";
    } else if (cocoa != null) {
        backend = "cocoa";
    } else if (wayland_display != null or wayland_surface != null) {
        backend = "wayland";
    } else if (x11_display != null or x11_window != 0) {
        backend = "x11";
    }
    logger.info("WebGPU surface backend: {s}", .{backend});
}

fn openUrl(allocator: std.mem.Allocator, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }
    child.spawn() catch |err| {
        logger.warn("Failed to open URL: {}", .{err});
    };
}

fn openPath(allocator: std.mem.Allocator, path: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", path },
        .macos => &.{ "open", path },
        else => &.{ "xdg-open", path },
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }
    child.spawn() catch |err| {
        logger.warn("Failed to open path: {}", .{err});
    };
}

const WinNodeServiceJobKind = enum {
    install_onlogon,
    uninstall,
    start,
    stop,
    status,
};

const WinNodeServiceJob = struct {
    kind: WinNodeServiceJobKind,
    url: []u8,
    token: []u8,
    insecure_tls: bool,

    fn deinit(self: *WinNodeServiceJob) void {
        std.heap.page_allocator.free(self.url);
        std.heap.page_allocator.free(self.token);
    }
};

fn spawnWinNodeServiceJob(kind: WinNodeServiceJobKind, url: []const u8, token: []const u8, insecure_tls: bool) void {
    // Copy inputs so the UI config can change/free independently.
    const job = std.heap.page_allocator.create(WinNodeServiceJob) catch return;
    job.* = .{
        .kind = kind,
        .url = std.heap.page_allocator.dupe(u8, url) catch {
            std.heap.page_allocator.destroy(job);
            return;
        },
        .token = std.heap.page_allocator.dupe(u8, token) catch {
            std.heap.page_allocator.free(job.url);
            std.heap.page_allocator.destroy(job);
            return;
        },
        .insecure_tls = insecure_tls,
    };

    _ = std.Thread.spawn(.{}, runWinNodeServiceJob, .{job}) catch {
        job.deinit();
        std.heap.page_allocator.destroy(job);
        return;
    };
}

fn runWinNodeServiceJob(job: *WinNodeServiceJob) void {
    defer {
        job.deinit();
        std.heap.page_allocator.destroy(job);
    }

    const allocator = std.heap.page_allocator;

    const cli = findSiblingExecutable(allocator, if (builtin.os.tag == .windows) "ziggystarclaw-cli.exe" else "ziggystarclaw-cli") catch |err| {
        logger.err("node service: failed to resolve cli path: {}", .{err});
        return;
    };
    defer allocator.free(cli);

    const action_args: []const []const u8 = switch (job.kind) {
        .install_onlogon => &.{ "node", "service", "install", "--node-service-mode", "onlogon" },
        .uninstall => &.{ "node", "service", "uninstall", "--node-service-mode", "onlogon" },
        .start => &.{ "node", "service", "start", "--node-service-mode", "onlogon" },
        .stop => &.{ "node", "service", "stop", "--node-service-mode", "onlogon" },
        .status => &.{ "node", "service", "status", "--node-service-mode", "onlogon" },
    };

    // Build argv = [cli] + action_args + common bootstrap args
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    argv.append(allocator, cli) catch return;
    argv.appendSlice(allocator, action_args) catch return;

    // Pass --url and --gateway-token even when token is empty to avoid interactive prompts.
    argv.append(allocator, "--url") catch return;
    argv.append(allocator, job.url) catch return;
    argv.append(allocator, "--gateway-token") catch return;
    argv.append(allocator, job.token) catch return;

    if (job.insecure_tls) {
        argv.append(allocator, "--insecure-tls") catch {};
    }

    // Be verbose in logs.
    argv.append(allocator, "--log-level") catch {};
    argv.append(allocator, "debug") catch {};

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }

    child.spawn() catch |err| {
        logger.err("node service: spawn failed: {}", .{err});
        return;
    };

    const term = child.wait() catch |err| {
        logger.err("node service: wait failed: {}", .{err});
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                logger.info("node service: {s} ok", .{@tagName(job.kind)});
            } else {
                logger.err("node service: {s} exited code={d}", .{ @tagName(job.kind), code });
            }
        },
        else => {
            logger.err("node service: {s} terminated unexpectedly", .{@tagName(job.kind)});
        },
    }
}

fn findSiblingExecutable(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse ".";
    const candidate = try std.fs.path.join(allocator, &.{ dir, name });

    std.fs.cwd().access(candidate, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Fall back to PATH.
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

fn installUpdate(allocator: std.mem.Allocator, archive_path: []const u8) bool {
    if (!(builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos)) {
        return false;
    }

    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        logger.warn("Failed to resolve self path: {}", .{err});
        return false;
    };
    defer allocator.free(exe_path);

    const pid: u32 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
    const pid_buf = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return false;
    defer allocator.free(pid_buf);

    std.fs.cwd().makePath("updates") catch {};

    const script_path = if (builtin.os.tag == .windows)
        "updates/install_update.ps1"
    else
        "updates/install_update.sh";

    const script_contents = if (builtin.os.tag == .windows)
        \\param([string]$Archive,[string]$Exe,[int]$Pid)
        \\$dir = Split-Path -Parent $Archive
        \\$stage = Join-Path $dir "staged"
        \\if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
        \\New-Item -ItemType Directory -Path $stage | Out-Null
        \\Expand-Archive -Force -Path $Archive -DestinationPath $stage
        \\$newExe = Join-Path $stage "windows\\ziggystarclaw-client.exe"
        \\if (-not (Test-Path $newExe)) { Write-Host "Missing updated binary"; exit 1 }
        \\if ($Pid -gt 0) { try { Wait-Process -Id $Pid -Timeout 30 } catch {} }
        \\Copy-Item -Force $newExe $Exe
        \\Start-Process -FilePath $Exe
    else
        \\#!/bin/sh
        \\set -e
        \\ARCHIVE=\"$1\"
        \\EXE=\"$2\"
        \\PID=\"$3\"
        \\DIR=$(dirname \"$ARCHIVE\")
        \\STAGE=\"$DIR/staged\"
        \\rm -rf \"$STAGE\"
        \\mkdir -p \"$STAGE\"
        \\case \"$ARCHIVE\" in
        \\  *.tar.gz|*.tgz) tar -xzf \"$ARCHIVE\" -C \"$STAGE\" ;;
        \\  *.zip) unzip -o \"$ARCHIVE\" -d \"$STAGE\" ;;
        \\  *) echo \"Unknown archive\"; exit 1 ;;
        \\esac
        \\NEW_BIN=\"$STAGE/linux/ziggystarclaw-client\"
        \\if [ -f \"$STAGE/macos/ziggystarclaw-client\" ]; then NEW_BIN=\"$STAGE/macos/ziggystarclaw-client\"; fi
        \\if [ ! -f \"$NEW_BIN\" ]; then echo \"Missing updated binary\"; exit 1; fi
        \\if [ -n \"$PID\" ]; then
        \\  while kill -0 \"$PID\" 2>/dev/null; do sleep 0.2; done
        \\fi
        \\cp -f \"$NEW_BIN\" \"$EXE\"
        \\chmod +x \"$EXE\"
        \\\"$EXE\" >/dev/null 2>&1 &
    ;

    {
        var file = std.fs.cwd().createFile(script_path, .{ .truncate = true }) catch |err| {
            logger.warn("Failed to write update script: {}", .{err});
            return false;
        };
        defer file.close();
        file.writeAll(script_contents) catch |err| {
            logger.warn("Failed to write update script: {}", .{err});
            return false;
        };
    }

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "-Archive", archive_path, "-Exe", exe_path, "-Pid", pid_buf },
        else => &.{ "sh", script_path, archive_path, exe_path, pid_buf },
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag == .windows) {
        child.create_no_window = true;
    }
    child.spawn() catch |err| {
        logger.warn("Failed to launch update installer: {}", .{err});
        return false;
    };
    return true;
}

const MessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList([]u8) = .empty,

    pub fn push(self: *MessageQueue, allocator: std.mem.Allocator, message: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, message);
    }

    pub fn drain(self: *MessageQueue) std.ArrayList([]u8) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = self.items;
        self.items = .empty;
        return out;
    }

    pub fn deinit(self: *MessageQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |message| {
            allocator.free(message);
        }
        self.items.deinit(allocator);
        self.items = .empty;
    }
};

const ReadLoop = struct {
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    queue: *MessageQueue,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_receive_ms: i64 = 0,
    last_payload_len: usize = 0,
};

const ConnectJob = struct {
    allocator: std.mem.Allocator,
    ws_client: *websocket_client.WebSocketClient,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_msg: ?[]u8 = null,

    const Status = enum(u8) { idle = 0, running = 1, success = 2, failed = 3 };

    fn start(self: *ConnectJob) !bool {
        if (self.status.load(.monotonic) == @intFromEnum(Status.running)) return false;
        if (self.thread != null) return false;
        self.cancel_requested.store(false, .monotonic);
        self.clearError();
        self.status.store(@intFromEnum(Status.running), .monotonic);
        self.thread = try std.Thread.spawn(.{}, connectThreadMain, .{self});
        return true;
    }

    fn requestCancel(self: *ConnectJob) void {
        self.cancel_requested.store(true, .monotonic);
    }

    fn isRunning(self: *ConnectJob) bool {
        return self.status.load(.monotonic) == @intFromEnum(Status.running);
    }

    fn takeResult(self: *ConnectJob) ?struct { ok: bool, err: ?[]u8, canceled: bool } {
        const status = self.status.load(.monotonic);
        if (status == @intFromEnum(Status.idle) or status == @intFromEnum(Status.running)) return null;
        if (self.thread) |handle| {
            handle.join();
            self.thread = null;
        }
        const ok = status == @intFromEnum(Status.success);
        self.status.store(@intFromEnum(Status.idle), .monotonic);
        const canceled = self.cancel_requested.load(.monotonic);
        self.cancel_requested.store(false, .monotonic);
        self.mutex.lock();
        const err_msg = self.error_msg;
        self.error_msg = null;
        self.mutex.unlock();
        return .{ .ok = ok, .err = err_msg, .canceled = canceled };
    }

    fn setError(self: *ConnectJob, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
        self.error_msg = self.allocator.dupe(u8, message) catch null;
    }

    fn clearError(self: *ConnectJob) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
            self.error_msg = null;
        }
    }
};

fn connectThreadMain(job: *ConnectJob) void {
    profiler.setThreadName("ws.connect");
    const zone = profiler.zone(@src(), "ws.connect");
    defer zone.end();
    const result = job.ws_client.connect();
    if (result) |_| {
        job.status.store(@intFromEnum(ConnectJob.Status.success), .monotonic);
    } else |err| {
        job.setError(@errorName(err));
        job.status.store(@intFromEnum(ConnectJob.Status.failed), .monotonic);
    }
}

fn readLoopMain(loop: *ReadLoop) void {
    profiler.setThreadName("ws.read");
    loop.running.store(true, .monotonic);
    defer loop.running.store(false, .monotonic);
    loop.ws_client.setReadTimeout(250);
    while (!loop.stop.load(.monotonic)) {
        const payload = blk: {
            const zone = profiler.zone(@src(), "ws.receive");
            defer zone.end();
            break :blk loop.ws_client.receive() catch |err| {
                if (err == error.NotConnected or err == error.Closed) {
                    return;
                }
                if (err == error.ReadFailed) {
                    const now_ms = std.time.milliTimestamp();
                    const last_ms = loop.last_receive_ms;
                    const delta = if (last_ms > 0) now_ms - last_ms else -1;
                    logger.warn(
                        "WebSocket receive failed (thread) connected={} last_payload_len={} last_payload_age_ms={d}",
                        .{ loop.ws_client.is_connected, loop.last_payload_len, delta },
                    );
                    loop.ws_client.disconnect();
                    return;
                }
                logger.err("WebSocket receive failed (thread): {}", .{err});
                loop.ws_client.disconnect();
                return;
            };
        } orelse continue;

        loop.last_receive_ms = std.time.milliTimestamp();
        loop.last_payload_len = payload.len;
        if (loop.stop.load(.monotonic)) {
            loop.allocator.free(payload);
            return;
        }
        {
            const zone = profiler.zone(@src(), "ws.enqueue");
            defer zone.end();
            loop.queue.push(loop.allocator, payload) catch {
                loop.allocator.free(payload);
                return;
            };
        }
    }
}

fn startReadThread(loop: *ReadLoop, thread: *?std.Thread) !void {
    if (thread.* != null) return;
    loop.stop.store(false, .monotonic);
    thread.* = try std.Thread.spawn(.{}, readLoopMain, .{loop});
}

fn stopReadThread(loop: *ReadLoop, thread: *?std.Thread) void {
    if (thread.*) |handle| {
        loop.stop.store(true, .monotonic);
        handle.join();
        thread.* = null;
        loop.ws_client.disconnect();
    }
}

fn makeNewSessionKey(allocator: std.mem.Allocator, agent_id: []const u8) ![]u8 {
    return try session_keys.buildChatSessionKey(allocator, agent_id);
}

fn sendSessionsResetRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;

    const params = sessions_proto.SessionsResetParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.reset", params) catch |err| {
        logger.warn("Failed to build sessions.reset request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.reset: {}", .{err});
        return;
    };
}

fn sendSessionsDeleteRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;

    const params = sessions_proto.SessionsDeleteParams{ .key = session_key };
    const request = requests.buildRequestPayload(allocator, "sessions.delete", params) catch |err| {
        logger.warn("Failed to build sessions.delete request: {}", .{err});
        return;
    };
    defer allocator.free(request.payload);
    defer allocator.free(request.id);

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.delete: {}", .{err});
        return;
    };
}

fn sendSessionsListRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_sessions_request_id != null) return;

    const params = sessions_proto.SessionsListParams{
        .includeGlobal = true,
        .includeUnknown = true,
    };

    const request = requests.buildRequestPayload(allocator, "sessions.list", params) catch |err| {
        logger.warn("Failed to build sessions.list request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send sessions.list: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingSessionsRequest(request.id);
}

fn sendNodesListRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_nodes_request_id != null) return;

    const params = nodes_proto.NodeListParams{};
    const request = requests.buildRequestPayload(allocator, "node.list", params) catch |err| {
        logger.warn("Failed to build node.list request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.list: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodesRequest(request.id);
}

fn sendChatHistoryRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.findSessionState(session_key)) |state_ptr| {
        if (state_ptr.pending_history_request_id != null) return;
    }

    const params = chat_proto.ChatHistoryParams{
        .sessionKey = session_key,
        .limit = 200,
    };

    const request = requests.buildRequestPayload(allocator, "chat.history", params) catch |err| {
        logger.warn("Failed to build chat.history request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.history: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingHistoryRequestForSession(session_key, request.id) catch {
        allocator.free(request.id);
    };
}

fn sendNodeInvokeRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    node_id: []const u8,
    command: []const u8,
    params_json: ?[]const u8,
    timeout_ms: ?u32,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_node_invoke_request_id != null) {
        ctx.setOperatorNotice("Another node invoke is already in progress.") catch {};
        return;
    }

    var parsed_params: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_params) |*parsed| parsed.deinit();
    var params_value: ?std.json.Value = null;

    if (params_json) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            parsed_params = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| {
                logger.warn("Invalid node params JSON: {}", .{err});
                ctx.setOperatorNotice("Invalid JSON for node params.") catch {};
                return;
            };
            params_value = parsed_params.?.value;
        }
    }

    const idempotency = requests.makeRequestId(allocator) catch |err| {
        logger.warn("Failed to generate idempotency key: {}", .{err});
        return;
    };
    defer allocator.free(idempotency);

    const params = nodes_proto.NodeInvokeParams{
        .nodeId = node_id,
        .command = command,
        .params = params_value,
        .timeoutMs = timeout_ms,
        .idempotencyKey = idempotency,
    };

    const request = requests.buildRequestPayload(allocator, "node.invoke", params) catch |err| {
        logger.warn("Failed to build node.invoke request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.invoke: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodeInvokeRequest(request.id);
    ctx.clearOperatorNotice();
}

fn sendNodeDescribeRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    node_id: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_node_describe_request_id != null) {
        ctx.setOperatorNotice("Another node describe request is already in progress.") catch {};
        return;
    }

    const params = nodes_proto.NodeDescribeParams{
        .nodeId = node_id,
    };
    const request = requests.buildRequestPayload(allocator, "node.describe", params) catch |err| {
        logger.warn("Failed to build node.describe request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send node.describe: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingNodeDescribeRequest(request.id);
    ctx.clearOperatorNotice();
}

fn sendExecApprovalResolveRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    request_id: []const u8,
    decision: []const u8,
) void {
    if (!ws_client.is_connected) return;
    if (ctx.state != .connected) return;
    if (ctx.pending_approval_resolve_request_id != null) {
        ctx.setOperatorNotice("Another approval resolve request is already in progress.") catch {};
        return;
    }

    const params = approvals_proto.ExecApprovalResolveParams{
        .id = request_id,
        .decision = decision,
    };
    const request = requests.buildRequestPayload(allocator, "exec.approval.resolve", params) catch |err| {
        logger.warn("Failed to build exec.approval.resolve request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    const target_copy = allocator.dupe(u8, request_id) catch {
        allocator.free(request.payload);
        allocator.free(request.id);
        return;
    };
    const decision_copy = allocator.dupe(u8, decision) catch {
        allocator.free(request.payload);
        allocator.free(request.id);
        allocator.free(target_copy);
        return;
    };

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send exec.approval.resolve: {}", .{err});
        allocator.free(request.payload);
        allocator.free(request.id);
        allocator.free(target_copy);
        allocator.free(decision_copy);
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingApprovalResolveRequest(request.id, target_copy, decision_copy);
    ctx.clearOperatorNotice();
}

fn sendChatMessageRequest(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    session_key: []const u8,
    message: []const u8,
) void {
    if (!ws_client.is_connected or ctx.state != .connected) {
        logger.warn("Cannot send chat message while disconnected", .{});
        return;
    }

    const idempotency = requests.makeRequestId(allocator) catch |err| {
        logger.warn("Failed to generate idempotency key: {}", .{err});
        return;
    };
    defer allocator.free(idempotency);

    const params = chat_proto.ChatSendParams{
        .sessionKey = session_key,
        .message = message,
        .deliver = false,
        .idempotencyKey = idempotency,
    };

    const request = requests.buildRequestPayload(allocator, "chat.send", params) catch |err| {
        logger.warn("Failed to build chat.send request: {}", .{err});
        return;
    };
    errdefer {
        allocator.free(request.payload);
        allocator.free(request.id);
    }

    var msg = buildUserMessage(allocator, idempotency, message) catch |err| {
        logger.warn("Failed to build user message: {}", .{err});
        return;
    };
    ctx.upsertSessionMessageOwned(session_key, msg) catch |err| {
        logger.warn("Failed to append user message: {}", .{err});
        freeChatMessageOwned(allocator, &msg);
    };

    ws_client.send(request.payload) catch |err| {
        logger.err("Failed to send chat.send: {}", .{err});
        return;
    };
    allocator.free(request.payload);
    ctx.setPendingSendRequest(request.id);
}

fn freeChatMessageOwned(allocator: std.mem.Allocator, msg: *types.ChatMessage) void {
    allocator.free(msg.id);
    allocator.free(msg.role);
    allocator.free(msg.content);
    if (msg.attachments) |attachments| {
        for (attachments) |*attachment| {
            allocator.free(attachment.kind);
            allocator.free(attachment.url);
            if (attachment.name) |name| allocator.free(name);
        }
        allocator.free(attachments);
    }
}

fn buildUserMessage(
    allocator: std.mem.Allocator,
    id: []const u8,
    content: []const u8,
) !types.ChatMessage {
    const id_copy = try std.fmt.allocPrint(allocator, "user:{s}", .{id});
    errdefer allocator.free(id_copy);
    const role = try allocator.dupe(u8, "user");
    errdefer allocator.free(role);
    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);
    return .{
        .id = id_copy,
        .role = role,
        .content = content_copy,
        .timestamp = std.time.milliTimestamp(),
        .attachments = null,
    };
}

fn agentDisplayName(registry: *agent_registry.AgentRegistry, agent_id: []const u8) []const u8 {
    if (registry.find(agent_id)) |agent| return agent.display_name;
    return agent_id;
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}

fn syncRegistryDefaults(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    sessions: []const types.Session,
) bool {
    var changed = false;
    for (registry.agents.items) |*agent| {
        var default_valid = false;
        if (agent.default_session_key) |key| {
            for (sessions) |session| {
                if (!std.mem.eql(u8, session.key, key)) continue;
                if (isNotificationSession(session)) break;
                const parts = session_keys.parse(session.key) orelse break;
                if (std.mem.eql(u8, parts.agent_id, agent.id)) {
                    default_valid = true;
                }
                break;
            }
        }

        if (!default_valid) {
            var best_key: ?[]const u8 = null;
            var best_updated: i64 = -1;
            for (sessions) |session| {
                if (isNotificationSession(session)) continue;
                const parts = session_keys.parse(session.key) orelse continue;
                if (!std.mem.eql(u8, parts.agent_id, agent.id)) continue;
                const updated = session.updated_at orelse 0;
                if (updated > best_updated) {
                    best_updated = updated;
                    best_key = session.key;
                }
            }
            if (best_key) |key| {
                if (agent.default_session_key) |existing| {
                    allocator.free(existing);
                }
                agent.default_session_key = allocator.dupe(u8, key) catch agent.default_session_key;
                changed = true;
            } else if (agent.default_session_key != null) {
                allocator.free(agent.default_session_key.?);
                agent.default_session_key = null;
                changed = true;
            }
        }
    }
    return changed;
}

fn ensureChatPanelsReady(
    allocator: std.mem.Allocator,
    ctx: *client_state.ClientContext,
    ws_client: *websocket_client.WebSocketClient,
    registry: *agent_registry.AgentRegistry,
    manager: *panel_manager.PanelManager,
) void {
    if (!ws_client.is_connected or ctx.state != .connected) return;

    var index: usize = 0;
    while (index < manager.workspace.panels.items.len) : (index += 1) {
        var panel = &manager.workspace.panels.items[index];
        if (panel.kind != .Chat) continue;
        const agent_id = panel.data.Chat.agent_id;
        var session_key = panel.data.Chat.session_key;
        if (session_key == null and agent_id != null) {
            if (registry.find(agent_id.?)) |agent| {
                if (agent.default_session_key) |default_key| {
                    panel.data.Chat.session_key = allocator.dupe(u8, default_key) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    manager.workspace.markDirty();
                }
            }
        }
        if (session_key == null) {
            if (ctx.current_session) |current| {
                var matches_agent = true;
                if (agent_id) |id| {
                    if (session_keys.parse(current)) |parts| {
                        matches_agent = std.mem.eql(u8, parts.agent_id, id);
                    } else {
                        matches_agent = std.mem.eql(u8, id, "main");
                    }
                }
                if (matches_agent) {
                    panel.data.Chat.session_key = allocator.dupe(u8, current) catch panel.data.Chat.session_key;
                    session_key = panel.data.Chat.session_key;
                    manager.workspace.markDirty();
                }
            }
        }
        if (session_key) |key| {
            if (ctx.findSessionState(key)) |state_ptr| {
                if (state_ptr.pending_history_request_id == null and !state_ptr.history_loaded) {
                    sendChatHistoryRequest(allocator, ctx, ws_client, key);
                }
            } else {
                sendChatHistoryRequest(allocator, ctx, ws_client, key);
            }
        }
    }
}

fn closeAgentChatPanels(manager: *panel_manager.PanelManager, agent_id: []const u8) void {
    var index: usize = 0;
    while (index < manager.workspace.panels.items.len) {
        const panel = &manager.workspace.panels.items[index];
        if (panel.kind == .Chat) {
            if (panel.data.Chat.agent_id) |existing| {
                if (std.mem.eql(u8, existing, agent_id)) {
                    _ = manager.closePanel(panel.id);
                    continue;
                }
            }
        }
        index += 1;
    }
}

fn clearChatPanelsForSession(
    manager: *panel_manager.PanelManager,
    allocator: std.mem.Allocator,
    session_key: []const u8,
) void {
    for (manager.workspace.panels.items) |*panel| {
        if (panel.kind != .Chat) continue;
        if (panel.data.Chat.session_key) |existing| {
            if (std.mem.eql(u8, existing, session_key)) {
                allocator.free(existing);
                panel.data.Chat.session_key = null;
                manager.workspace.markDirty();
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    profiler.setThreadName("main");

    try initLogging(allocator);
    defer logger.deinit();

    var cfg = try config.loadOrDefault(allocator, "ziggystarclaw_config.json");
    defer cfg.deinit(allocator);
    // If the user has never saved a config yet, create one so it's easy to edit by hand.
    const cfg_missing = blk: {
        std.fs.cwd().access("ziggystarclaw_config.json", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => break :blk false,
        };
        break :blk false;
    };
    if (cfg_missing) {
        config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
            logger.err("Failed to write default config: {}", .{err});
        };
    }
    if (config.migrateThemePackPath(allocator, &cfg)) {
        logger.info("Migrated ui_theme_pack to: {s}", .{cfg.ui_theme_pack orelse ""});
        config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
            logger.err("Failed to save migrated config: {}", .{err});
        };
    }
    {
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
        defer if (cwd) |v| allocator.free(v);
        const cfg_path = std.fs.cwd().realpathAlloc(allocator, "ziggystarclaw_config.json") catch null;
        defer if (cfg_path) |v| allocator.free(v);
        logger.info("Config file: {s} (cwd: {s})", .{ cfg_path orelse "ziggystarclaw_config.json", cwd orelse "." });
    }
    var theme_eng = theme_engine.ThemeEngine.init(allocator, theme_engine.PlatformCaps.defaultForTarget());
    defer theme_eng.deinit();
    theme_eng.applyThemePackDirFromPath(cfg.ui_theme_pack, true) catch |err| {
        logger.warn("Failed to load theme pack: {}", .{err});
    };
    // Apply initial mode after the pack loads so packs can opt out of user light/dark toggles.
    {
        const pack_default = theme_engine.runtime.getPackDefaultMode() orelse .light;
        if (theme_engine.runtime.getPackModeLockToDefault()) {
            theme.setMode(pack_default);
        } else if (cfg.ui_theme) |label| {
            theme.setMode(theme.modeFromLabel(label));
        } else if (theme_engine.runtime.getPackDefaultMode() != null) {
            theme.setMode(pack_default);
        }
    }
    var theme_pack_watch: ThemePackWatch = .{};
    var agents = try agent_registry.AgentRegistry.loadOrDefault(allocator, "ziggystarclaw_agents.json");
    defer agents.deinit(allocator);
    var app_state_state = app_state.loadOrDefault(allocator, "ziggystarclaw_state.json") catch app_state.initDefault();
    var auto_connect_enabled = app_state_state.last_connected;
    var auto_connect_pending = auto_connect_enabled and cfg.auto_connect_on_launch and cfg.server_url.len > 0;

    var ws_client = websocket_client.WebSocketClient.init(
        allocator,
        cfg.server_url,
        cfg.token,
        cfg.insecure_tls,
        cfg.connect_host_override,
    );
    var connect_job = ConnectJob{
        .allocator = allocator,
        .ws_client = &ws_client,
    };
    ws_client.setReadTimeout(15_000);
    defer ws_client.deinit();

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        logger.err("SDL init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();
    _ = sdl.SDL_SetHint("SDL_IME_SHOW_UI", "1");
    sdl_input_backend.init(allocator);
    input_router.setBackend(input_backend.sdl3);
    defer input_router.deinit(allocator);
    defer sdl_input_backend.deinit();

    var window_width: c_int = 1280;
    var window_height: c_int = 720;
    if (app_state_state.window_width) |w| {
        if (w > 200) window_width = @intCast(w);
    }
    if (app_state_state.window_height) |h| {
        if (h > 200) window_height = @intCast(h);
    }

    const window_flags: sdl.SDL_WindowFlags = @intCast(
        sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    const window = sdl.SDL_CreateWindow("ZiggyStarClaw", window_width, window_height, window_flags) orelse {
        logger.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlWindowCreateFailed;
    };
    var main_window_owned_by_ui: bool = false;
    errdefer if (!main_window_owned_by_ui) sdl.SDL_DestroyWindow(window);
    text_input_backend.init(@ptrCast(window));
    defer text_input_backend.deinit();
    setWindowIcon(window);
    if (app_state_state.window_maximized) {
        _ = sdl.SDL_MaximizeWindow(window);
    } else if (app_state_state.window_pos_x != null and app_state_state.window_pos_y != null) {
        _ = sdl.SDL_SetWindowPosition(
            window,
            @intCast(app_state_state.window_pos_x.?),
            @intCast(app_state_state.window_pos_y.?),
        );
    }

    logSurfaceBackend(window);

    var gpu = try multi_renderer.Shared.init(allocator, window);
    defer gpu.deinit();

    // Global unique panel id allocator shared across all windows.
    var next_panel_id_global: workspace.PanelId = 1;

    const main_win = try allocator.create(UiWindow);
    main_win.* = .{
        .window = window,
        .id = sdl.SDL_GetWindowID(window),
        .queue = input_state.InputQueue.init(allocator),
        .swapchain = multi_renderer.WindowSwapchain.initMain(&gpu, window),
        // Initialize immediately so early errors don't trip `destroyUiWindow`.
        .manager = panel_manager.PanelManager.init(allocator, workspace.Workspace.initEmpty(allocator), &next_panel_id_global),
        .ui_state = .{ .theme_layout_presets_enabled = true },
        .title = try allocator.dupe(u8, "ZiggyStarClaw"),
        .persist_in_workspace = false,
        .profile_override = null,
        .theme_mode_override = null,
        .image_sampling_override = null,
        .pixel_snap_textured_override = null,
    };
    errdefer destroyUiWindow(allocator, main_win);
    main_window_owned_by_ui = true;

    var ui_windows: std.ArrayList(*UiWindow) = .empty;
    try ui_windows.append(allocator, main_win);
    defer {
        for (ui_windows.items) |w| destroyUiWindow(allocator, w);
        ui_windows.deinit(allocator);
    }

    const dpi_scale_raw: f32 = sdl.SDL_GetWindowDisplayScale(window);
    const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
    if (!font_system.isInitialized()) {
        font_system.init(std.heap.page_allocator);
    }
    var fb_w_init: c_int = 0;
    var fb_h_init: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &fb_w_init, &fb_h_init);
    const fb_w_u32: u32 = @intCast(if (fb_w_init > 0) fb_w_init else 1);
    const fb_h_u32: u32 = @intCast(if (fb_h_init > 0) fb_h_init else 1);
    theme_eng.resolveProfileFromConfig(fb_w_u32, fb_h_u32, cfg.ui_profile);
    theme.applyTypography(dpi_scale * theme_eng.active_profile.ui_scale);
    image_cache.init(allocator);
    attachment_cache.init(allocator);
    image_cache.setEnabled(true);
    defer image_cache.deinit();
    defer attachment_cache.deinit();
    // renderers are owned by `ui_windows`

    const workspace_file_exists: bool = blk: {
        std.fs.cwd().access("ziggystarclaw_workspace.json", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        break :blk true;
    };

    var ctx = try client_state.ClientContext.init(allocator);
    defer ctx.deinit();
    var loaded = workspace_store.loadMultiOrDefault(allocator, "ziggystarclaw_workspace.json") catch |err| blk: {
        logger.warn("Failed to load workspace: {}", .{err});
        const fallback = workspace_store.MultiWorkspace{
            .main = workspace.Workspace.initDefault(allocator) catch |init_err| {
                logger.err("Failed to init default workspace: {}", .{init_err});
                return init_err;
            },
            .windows = allocator.alloc(workspace_store.DetachedWindow, 0) catch return err,
            .next_panel_id = 1,
        };
        break :blk fallback;
    };
    defer {
        // We transfer window workspaces into actual UiWindows below; this cleanup only runs
        // for any remaining (emptied) workspaces/metadata.
        for (loaded.windows) |*w| w.deinit(allocator);
        allocator.free(loaded.windows);
        loaded.main.deinit(allocator);
    }

    // Restore the global panel id allocator from disk (and then bump it based on loaded panels).
    next_panel_id_global = loaded.next_panel_id;

    const workspace_state = loaded.main;
    loaded.main = workspace.Workspace.initEmpty(allocator);

    main_win.manager.deinit();
    main_win.manager = panel_manager.PanelManager.init(allocator, workspace_state, &next_panel_id_global);
    // If we loaded a workspace from disk, do not auto-apply the theme pack's workspace layout preset
    // for the current profile on startup. (It can re-open panels the user explicitly tore off.)
    if (workspace_file_exists) {
        const pid = theme_eng.active_profile.id;
        const idx: usize = switch (pid) {
            .desktop => 0,
            .phone => 1,
            .tablet => 2,
            .fullscreen => 3,
        };
        main_win.ui_state.theme_layout_applied[idx] = true;
    }

    // Spawn any persisted secondary windows.
    if (theme_eng.caps.supports_multi_window and loaded.windows.len > 0) {
        for (loaded.windows) |*w| {
            var title_buf: [192]u8 = undefined;
            const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{w.title}) catch "ZiggyStarClaw";

            const profile_override: ?theme_engine.ProfileId = profile.profileFromLabel(w.profile);
            const mode_override: ?theme.Mode = if (w.variant) |v| theme.modeFromLabel(v) else null;
            const sampling_override: ?ui_commands.ImageSampling = if (w.image_sampling) |v| parseImageSamplingLabel(v) else null;
            const pixel_override: ?bool = w.pixel_snap_textured;

            const max_cint_u32: u32 = @intCast(std.math.maxInt(c_int));
            const width_u32: u32 = std.math.clamp(w.width, @as(u32, 320), max_cint_u32);
            const height_u32: u32 = std.math.clamp(w.height, @as(u32, 240), max_cint_u32);
            const width: c_int = @intCast(width_u32);
            const height: c_int = @intCast(height_u32);

            const ws_for_new = w.ws;
            w.ws = workspace.Workspace.initEmpty(allocator);

            const new_win = createUiWindow(
                allocator,
                &gpu,
                title_z,
                width,
                height,
                window_flags,
                ws_for_new,
                &next_panel_id_global,
                true,
                false,
                profile_override,
                mode_override,
                sampling_override,
                pixel_override,
            ) catch |create_err| blk2: {
                logger.warn("Failed to restore window '{s}': {}", .{ w.title, create_err });
                break :blk2 null;
            };
            if (new_win) |uw| {
                ui_windows.append(allocator, uw) catch {
                    destroyUiWindow(allocator, uw);
                };
            }
        }
    }

    defer ui.deinit(allocator);
    var command_inbox = ui_command_inbox.UiCommandInbox.init(allocator);
    defer command_inbox.deinit(allocator);

    var message_queue = MessageQueue{};
    defer message_queue.deinit(allocator);
    var read_loop = ReadLoop{
        .allocator = allocator,
        .ws_client = &ws_client,
        .queue = &message_queue,
    };
    var read_thread: ?std.Thread = null;
    defer stopReadThread(&read_loop, &read_thread);
    var should_reconnect = false;
    var reconnect_backoff_ms: u32 = 500;
    var next_reconnect_at_ms: i64 = 0;
    var next_ping_at_ms: i64 = 0;
    defer {
        app_state_state.last_connected = auto_connect_enabled;
        const flags = sdl.SDL_GetWindowFlags(window);
        const iconified = (flags & sdl.SDL_WINDOW_MINIMIZED) != 0;
        if (!iconified) {
            var size_w: c_int = 0;
            var size_h: c_int = 0;
            _ = sdl.SDL_GetWindowSize(window, &size_w, &size_h);
            var pos_x: c_int = 0;
            var pos_y: c_int = 0;
            _ = sdl.SDL_GetWindowPosition(window, &pos_x, &pos_y);
            app_state_state.window_width = size_w;
            app_state_state.window_height = size_h;
            app_state_state.window_pos_x = pos_x;
            app_state_state.window_pos_y = pos_y;
        }
        app_state_state.window_maximized = (flags & sdl.SDL_WINDOW_MAXIMIZED) != 0;
        app_state.save(allocator, "ziggystarclaw_state.json", app_state_state) catch |err| {
            logger.warn("Failed to save app state: {}", .{err});
        };
    }

    logger.info("ZiggyStarClaw client (native) loaded. Server: {s}", .{cfg.server_url});

    if (auto_connect_pending) {
        ctx.state = .connecting;
        ctx.clearError();
        ws_client.url = cfg.server_url;
        ws_client.token = cfg.token;
        ws_client.insecure_tls = cfg.insecure_tls;
        ws_client.connect_host_override = cfg.connect_host_override;
        auto_connect_enabled = true;
        should_reconnect = true;
        reconnect_backoff_ms = 500;
        next_reconnect_at_ms = 0;
        if (!connect_job.isRunning()) {
            const started = connect_job.start() catch |err| blk: {
                logger.err("Failed to start connect thread: {}", .{err});
                ctx.state = .error_state;
                ctx.setError(@errorName(err)) catch {};
                break :blk false;
            };
            if (!started) {
                logger.warn("Connect attempt already in progress", .{});
            }
        }
        auto_connect_pending = false;
    }

    var should_close = false;
    var window_close_requests: std.ArrayList(u32) = .empty;
    defer window_close_requests.deinit(allocator);
    while (!should_close) {
        profiler.frameMark();
        const frame_zone = profiler.zone(@src(), "frame");
        defer frame_zone.end();
        window_close_requests.clearRetainingCapacity();
        {
            const zone = profiler.zone(@src(), "frame.events");
            defer zone.end();
            var event: sdl.SDL_Event = undefined;
            while (sdl.SDL_PollEvent(&event)) {
                sdl_input_backend.pushEvent(&event);
                switch (event.type) {
                    sdl.SDL_EVENT_QUIT,
                    => should_close = true,
                    sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                        const wid = event.window.windowID;
                        if (wid == main_win.id) {
                            should_close = true;
                        } else {
                            window_close_requests.append(allocator, wid) catch {};
                        }
                    },
                    else => {},
                }
            }
        }

        if (read_thread != null and !read_loop.running.load(.monotonic)) {
            stopReadThread(&read_loop, &read_thread);
        }
        if (!ws_client.is_connected and ctx.state == .connected) {
            ctx.state = .disconnected;
            if (should_reconnect and next_reconnect_at_ms == 0) {
                const now_ms = std.time.milliTimestamp();
                next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                logger.info("Reconnect scheduled in {d}ms", .{reconnect_backoff_ms});
            }
        }

        var drained = message_queue.drain();
        defer {
            for (drained.items) |payload| {
                allocator.free(payload);
            }
            drained.deinit(allocator);
        }
        {
            const zone = profiler.zone(@src(), "frame.net");
            defer zone.end();
            for (drained.items) |payload| {
                const update = event_handler.handleRawMessage(&ctx, payload) catch |err| blk: {
                    logger.err("Failed to handle server message: {}", .{err});
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
                        logger.warn("Failed to store device token: {}", .{err});
                    };
                }
            }
        }

        if (ws_client.is_connected and ctx.state == .connected) {
            if (ctx.sessions.items.len == 0 and ctx.pending_sessions_request_id == null) {
                sendSessionsListRequest(allocator, &ctx, &ws_client);
            }
            if (ctx.nodes.items.len == 0 and ctx.pending_nodes_request_id == null) {
                sendNodesListRequest(allocator, &ctx, &ws_client);
            }
        }

        if (ctx.sessions_updated) {
            if (syncRegistryDefaults(allocator, &agents, ctx.sessions.items)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
            ctx.clearSessionsUpdated();
        }

        if (ws_client.is_connected and ctx.state == .connected) {
            const now_ms = std.time.milliTimestamp();
            if (next_ping_at_ms == 0 or now_ms >= next_ping_at_ms) {
                ws_client.sendPing() catch |err| {
                    logger.warn("WebSocket ping failed: {}", .{err});
                };
                next_ping_at_ms = now_ms + 10_000;
            }
        } else {
            next_ping_at_ms = 0;
        }

        const kb_focus = sdl.SDL_GetKeyboardFocus();
        const focused_id: u32 = if (kb_focus) |w| sdl.SDL_GetWindowID(w) else main_win.id;

        var ui_action: ui.UiAction = .{};
        var active_window: *UiWindow = main_win;
        var any_save_workspace: bool = false;
        var detach_req: ?struct { wid: u32, panel_ptr: *workspace.Panel } = null;
        {
            const zone = profiler.zone(@src(), "frame.ui");
            defer zone.end();

            // Apply assistant UI commands to the currently focused window only.
            // Other windows still render the shared app state (sessions, agents, etc.),
            // but panel/layout interactions remain independent per window.
            for (ui_windows.items) |w| {
                if (w.id == focused_id) {
                    active_window = w;
                    break;
                }
            }
            ui.frameBegin(allocator, &ctx, &active_window.manager, &command_inbox);
            for (ui_windows.items) |w| {
                const win_zone = profiler.zone(@src(), "frame.ui.window");
                defer win_zone.end();

                var w_fb_w: c_int = 0;
                var w_fb_h: c_int = 0;
                _ = sdl.SDL_GetWindowSizeInPixels(w.window, &w_fb_w, &w_fb_h);
                const w_fb_width: u32 = if (w_fb_w > 0) @intCast(w_fb_w) else 1;
                const w_fb_height: u32 = if (w_fb_h > 0) @intCast(w_fb_h) else 1;

                // Per-window theme pack override: activate the correct pack before we resolve
                // profile/mode/typography and emit draw commands for this window.
                const desired_pack: ?[]const u8 = w.ui_state.theme_pack_override orelse cfg.ui_theme_pack;
                const force_reload_pack = w.ui_state.theme_pack_reload_requested;
                if (w.ui_state.theme_pack_reload_requested) w.ui_state.theme_pack_reload_requested = false;
                {
                    const tz = profiler.zone(@src(), "theme.activate_pack_for_render");
                    defer tz.end();
                    theme_eng.activateThemePackForRender(desired_pack, force_reload_pack) catch {};
                }

                // Multi-window: each window can have a different framebuffer size (and potentially DPI),
                // so resolve profile and typography scale per window before we record its UI commands.
                // This makes "auto" profile selection (desktop/phone/tablet/fullscreen) window-local,
                // and keeps hit-target sizing / hover rules correct per window.
                const w_dpi_scale_raw: f32 = sdl.SDL_GetWindowDisplayScale(w.window);
                const w_dpi_scale: f32 = if (w_dpi_scale_raw > 0.0) w_dpi_scale_raw else 1.0;
                const requested_profile: ?[]const u8 = if (w.profile_override) |pid|
                    profile.labelForProfile(pid)
                else if (cfg.ui_profile) |label|
                    label
                else if (theme_engine.runtime.getPackDefaultProfile()) |pid|
                    profile.labelForProfile(pid)
                else
                    null;
                theme_eng.resolveProfileFromConfig(w_fb_width, w_fb_height, requested_profile);
                const pack_default = theme_engine.runtime.getPackDefaultMode() orelse .light;
                const cfg_mode: theme.Mode = if (theme_engine.runtime.getPackModeLockToDefault())
                    pack_default
                else if (cfg.ui_theme) |label|
                    theme.modeFromLabel(label)
                else
                    pack_default;
                theme.setMode(w.theme_mode_override orelse cfg_mode);
                theme.applyTypography(w_dpi_scale * theme_eng.active_profile.ui_scale);

                w.queue.clear(allocator);
                sdl_input_backend.setCollectWindow(w.window);
                input_router.setExternalQueue(&w.queue);
                input_router.collect(allocator);

                w.swapchain.beginFrame(&gpu, w_fb_width, w_fb_height);
                const action = ui.drawWindow(
                    allocator,
                    &ctx,
                    &cfg,
                    &agents,
                    ws_client.is_connected,
                    build_options.app_version,
                    w_fb_width,
                    w_fb_height,
                    &w.manager,
                    &command_inbox,
                    &w.queue,
                    &w.ui_state,
                );
                if (action.save_workspace) any_save_workspace = true;
                if (action.detach_panel) |pp| {
                    // UI already removed the panel from the manager; keep ownership in a heap node
                    // until we spawn the tear-off window at the end of the frame.
                    if (detach_req == null) {
                        detach_req = .{ .wid = w.id, .panel_ptr = pp };
                    } else {
                        // Only one detach per frame is supported; don't leak if multiple fire.
                        const moved = pp.*;
                        allocator.destroy(pp);
                        var tmp = moved;
                        tmp.deinit(allocator);
                    }
                }
                if (w.id == focused_id) {
                    ui_action = action;
                    active_window = w;
                }

                if (command_queue.get()) |list| {
                    const defaults = theme_engine.runtime.getRenderDefaults();
                    list.meta.image_sampling = w.image_sampling_override orelse defaults.image_sampling;
                    list.meta.pixel_snap_textured = w.pixel_snap_textured_override orelse defaults.pixel_snap_textured;
                    gpu.ui_renderer.beginFrame(w_fb_width, w_fb_height);
                    w.swapchain.render(&gpu, list);
                }
            }
            sdl_input_backend.setCollectWindow(null);
            ui.frameEnd();
        }
        if (any_save_workspace) ui_action.save_workspace = true;

        if (ui_action.config_updated) {
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            const pack_default = theme_engine.runtime.getPackDefaultMode() orelse .light;
            if (theme_engine.runtime.getPackModeLockToDefault()) {
                theme.setMode(pack_default);
            } else if (cfg.ui_theme) |label| {
                theme.setMode(theme.modeFromLabel(label));
            } else if (theme_engine.runtime.getPackDefaultMode() != null) {
                theme.setMode(pack_default);
            }
        }

        if (ui_action.clear_theme_pack_override) {
            if (active_window.ui_state.theme_pack_override) |buf| {
                allocator.free(buf);
                active_window.ui_state.theme_pack_override = null;
            }
            active_window.ui_state.theme_layout_applied = .{ false, false, false, false };
        }
        if (ui_action.reload_theme_pack_override) {
            active_window.ui_state.theme_pack_reload_requested = true;
        }

        var pack_applied_this_frame = false;
        if (ui_action.config_updated or ui_action.reload_theme_pack) {
            const applied_ok = if (theme_eng.activateThemePackForRender(cfg.ui_theme_pack, ui_action.reload_theme_pack))
                true
            else |err| blk: {
                if (cfg.ui_theme_pack) |pack_path| {
                    logger.warn("Failed to load theme pack '{s}': {}", .{ pack_path, err });
                } else {
                    logger.warn("Failed to apply theme pack: {}", .{err});
                }
                break :blk false;
            };
            if (applied_ok) {
                pack_applied_this_frame = true;
                if (cfg.ui_theme_pack) |pack_path| {
                    if (config.pushRecentThemePack(allocator, &cfg, pack_path)) {
                        ui_action.save_config = true;
                    }
                }
            }
            // Profile/typography are resolved per-window during UI draw.
        }

        updateThemePackWatch(allocator, &theme_pack_watch, &theme_eng, &cfg, pack_applied_this_frame);

        // Theme pack browse dialog (desktop only).
        if (ui_action.browse_theme_pack or ui_action.browse_theme_pack_override) {
            if (builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .macos) {
                theme_pack_browse.mutex.lock();
                const can_launch = !theme_pack_browse.in_flight;
                if (can_launch) {
                    theme_pack_browse.in_flight = true;
                    theme_pack_browse.target = if (ui_action.browse_theme_pack_override) .window_override else .config;
                    theme_pack_browse.target_window_id = if (ui_action.browse_theme_pack_override) active_window.id else 0;
                }
                theme_pack_browse.mutex.unlock();
                if (can_launch) {
                    const themes_dir_abs = std.fs.cwd().realpathAlloc(allocator, "themes") catch null;
                    defer if (themes_dir_abs) |v| allocator.free(v);

                    // SDL copies/consumes the path as needed; safe to pass a temporary null-terminated buffer.
                    if (themes_dir_abs) |abs_path| {
                        const z = allocator.alloc(u8, abs_path.len + 1) catch null;
                        if (z) |buf| {
                            defer allocator.free(buf);
                            @memcpy(buf[0..abs_path.len], abs_path);
                            buf[abs_path.len] = 0;
                            sdl.SDL_ShowOpenFolderDialog(sdlDialogPickThemePack, null, active_window.window, @ptrCast(buf.ptr), false);
                        } else {
                            sdl.SDL_ShowOpenFolderDialog(sdlDialogPickThemePack, null, active_window.window, null, false);
                        }
                    } else {
                        sdl.SDL_ShowOpenFolderDialog(sdlDialogPickThemePack, null, active_window.window, null, false);
                    }
                }
            }
        }

        // Consume browse dialog result.
        var picked_c: ?[]u8 = null;
        var had_error: bool = false;
        var browse_target: @TypeOf(theme_pack_browse.target) = .config;
        var browse_target_wid: u32 = 0;
        {
            theme_pack_browse.mutex.lock();
            picked_c = theme_pack_browse.pending_path;
            theme_pack_browse.pending_path = null;
            had_error = theme_pack_browse.pending_error;
            theme_pack_browse.pending_error = false;
            browse_target = theme_pack_browse.target;
            browse_target_wid = theme_pack_browse.target_window_id;
            theme_pack_browse.target = .config;
            theme_pack_browse.target_window_id = 0;
            theme_pack_browse.mutex.unlock();
        }
        if (picked_c) |picked| {
            defer std.heap.c_allocator.free(picked);

            const chosen = themePackRootFromSelection(picked);
            // Prefer storing a portable relative path when the chosen folder is under ./themes.
            const themes_abs = std.fs.cwd().realpathAlloc(allocator, "themes") catch null;
            defer if (themes_abs) |v| allocator.free(v);

            var stored: ?[]u8 = null;
            if (themes_abs) |themes_root| {
                if (std.mem.startsWith(u8, chosen, themes_root)) {
                    // Accept both "/themes/<name>" and "/themes/<name>/..."
                    var rel = chosen[themes_root.len..];
                    if (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
                    const first_sep = std.mem.indexOfAny(u8, rel, "/\\") orelse rel.len;
                    if (first_sep > 0) {
                        stored = std.fmt.allocPrint(allocator, "themes/{s}", .{rel[0..first_sep]}) catch null;
                    }
                }
            }
            if (stored == null) {
                stored = allocator.dupe(u8, chosen) catch null;
            }

            if (stored) |path| {
                defer allocator.free(path);
                switch (browse_target) {
                    .config => {
                        const new_value = allocator.dupe(u8, path) catch null;
                        if (new_value) |owned| {
                            if (cfg.ui_theme_pack) |v| allocator.free(v);
                            cfg.ui_theme_pack = owned;
                            ui.syncSettings(allocator, cfg);

                            // Apply immediately; only persist if apply succeeded.
                            if (theme_eng.activateThemePackForRender(cfg.ui_theme_pack, true)) |_| {
                                if (cfg.ui_theme_pack) |pack_path| {
                                    _ = config.pushRecentThemePack(allocator, &cfg, pack_path);
                                }
                                config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
                                    logger.err("Failed to save config: {}", .{err});
                                };
                            } else |err| {
                                logger.warn("Failed to load theme pack '{s}': {}", .{ path, err });
                            }
                        }
                    },
                    .window_override => {
                        // Validate/apply first; only set override if it loads.
                        if (theme_eng.activateThemePackForRender(path, true)) |_| {
                            var target_window: ?*UiWindow = null;
                            for (ui_windows.items) |w| {
                                if (w.id == browse_target_wid) {
                                    target_window = w;
                                    break;
                                }
                            }
                            if (target_window) |tw| {
                                if (tw.ui_state.theme_pack_override) |old| allocator.free(old);
                                tw.ui_state.theme_pack_override = allocator.dupe(u8, path) catch null;
                                tw.ui_state.theme_layout_applied = .{ false, false, false, false };
                            }
                        } else |err| {
                            logger.warn("Failed to load theme pack '{s}': {}", .{ path, err });
                        }
                    },
                }
            }
        } else if (had_error) {
            logger.warn("Theme pack browse failed: {s}", .{sdl.SDL_GetError()});
        }

        if (ui_action.save_config) {
            const cfg_path = std.fs.cwd().realpathAlloc(allocator, "ziggystarclaw_config.json") catch null;
            defer if (cfg_path) |v| allocator.free(v);
            logger.info("Saving config: {s}", .{cfg_path orelse "ziggystarclaw_config.json"});
            config.save(allocator, "ziggystarclaw_config.json", cfg) catch |err| {
                logger.err("Failed to save config: {}", .{err});
            };
        }

        if (detach_req) |req| {
            // Detach: move the panel from the source window into a new window.
            detach_block: {
                var source_window: ?*UiWindow = null;
                for (ui_windows.items) |w| {
                    if (w.id == req.wid) {
                        source_window = w;
                        break;
                    }
                }
                if (source_window) |src_w| {
                    const panel = req.panel_ptr.*;
                    allocator.destroy(req.panel_ptr);
                    var ws_new = workspace.Workspace.initEmpty(allocator);
                    // Transfer the panel into the new window workspace.
                    if (ws_new.panels.append(allocator, panel)) |_| {} else |err| {
                        logger.warn("Failed to allocate detached window workspace: {}", .{err});
                        // Put the panel back to avoid losing it.
                        _ = src_w.manager.putPanel(panel) catch {
                            var tmp = panel;
                            tmp.deinit(allocator);
                        };
                        ws_new.deinit(allocator);
                        break :detach_block;
                    }
                    ws_new.focused_panel_id = panel.id;

                    var title_buf: [192]u8 = undefined;
                    const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{panel.title}) catch "ZiggyStarClaw";
                    const size = defaultWindowSizeForPanelKind(panel.kind);

                    const new_win = createUiWindow(
                        allocator,
                        &gpu,
                        title_z,
                        size.w,
                        size.h,
                        window_flags,
                        ws_new,
                        &next_panel_id_global,
                        true,
                        false,
                        src_w.profile_override,
                        src_w.theme_mode_override,
                        src_w.image_sampling_override,
                        src_w.pixel_snap_textured_override,
                    ) catch |err| blk: {
                        logger.warn("Failed to detach panel into new window: {}", .{err});
                        // Reattach: pull the panel back out of ws_new before freeing.
                        const restored = ws_new.panels.pop();
                        ws_new.deinit(allocator);
                        if (restored) |p| {
                            _ = src_w.manager.putPanel(p) catch {
                                var tmp = p;
                                tmp.deinit(allocator);
                            };
                        }
                        break :blk null;
                    };
                    if (new_win) |wnew| {
                        var pos_x: c_int = 0;
                        var pos_y: c_int = 0;
                        _ = sdl.SDL_GetWindowPosition(src_w.window, &pos_x, &pos_y);
                        _ = sdl.SDL_SetWindowPosition(wnew.window, pos_x + 24, pos_y + 24);
                        ui_windows.append(allocator, wnew) catch {
                            destroyUiWindow(allocator, wnew);
                        };
                    }
                } else {
                    // Source window disappeared; avoid leaking the detached panel.
                    var tmp = req.panel_ptr.*;
                    allocator.destroy(req.panel_ptr);
                    tmp.deinit(allocator);
                }
            }
        }

        if (ui_action.save_workspace) save_ws: {
            // Persist the main workspace plus any secondary windows.
            var count: usize = 0;
            for (ui_windows.items) |w| {
                if (w.id == main_win.id) continue;
                if (!w.persist_in_workspace) continue;
                count += 1;
            }
            const views = allocator.alloc(workspace_store.DetachedWindowView, count) catch |err| {
                logger.err("Failed to allocate workspace save list: {}", .{err});
                workspace_store.saveMulti(
                    allocator,
                    "ziggystarclaw_workspace.json",
                    &main_win.manager.workspace,
                    &[_]workspace_store.DetachedWindowView{},
                    next_panel_id_global,
                ) catch |save_err| {
                    logger.err("Failed to save workspace: {}", .{save_err});
                };
                for (ui_windows.items) |w| {
                    w.manager.workspace.markClean();
                }
                // Can't include window list this frame.
                break :save_ws;
            };
            defer allocator.free(views);

            var filled: usize = 0;
            for (ui_windows.items) |w| {
                if (w.id == main_win.id) continue;
                if (!w.persist_in_workspace) continue;
                var size_w: c_int = 0;
                var size_h: c_int = 0;
                _ = sdl.SDL_GetWindowSize(w.window, &size_w, &size_h);
                const w_u32: u32 = @intCast(if (size_w > 0) size_w else 1);
                const h_u32: u32 = @intCast(if (size_h > 0) size_h else 1);

                views[filled] = .{
                    .title = w.title,
                    .width = w_u32,
                    .height = h_u32,
                    .profile = if (w.profile_override) |pid| profile.labelForProfile(pid) else null,
                    .variant = if (w.theme_mode_override) |m| theme.labelForMode(m) else null,
                    .image_sampling = if (w.image_sampling_override) |s| labelForImageSampling(s) else null,
                    .pixel_snap_textured = w.pixel_snap_textured_override,
                    .ws = &w.manager.workspace,
                };
                filled += 1;
            }

            workspace_store.saveMulti(
                allocator,
                "ziggystarclaw_workspace.json",
                &main_win.manager.workspace,
                views[0..filled],
                next_panel_id_global,
            ) catch |err| {
                logger.err("Failed to save workspace: {}", .{err});
            };

            for (ui_windows.items) |w| {
                w.manager.workspace.markClean();
            }
        }

        if (ui_action.check_updates) {
            const manifest_url = cfg.update_manifest_url orelse "";
            update_checker.UpdateState.startCheck(
                &ctx.update_state,
                allocator,
                manifest_url,
                build_options.app_version,
                true,
            );
        }
        if (ui_action.download_update) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_url) |download_url| {
                const file_name = snapshot.download_file orelse "ziggystarclaw_update.zip";
                update_checker.UpdateState.startDownload(&ctx.update_state, allocator, download_url, file_name);
            }
        }
        if (ui_action.open_release) {
            const snapshot = ctx.update_state.snapshot();
            const release_url = snapshot.release_url orelse
                "https://github.com/DeanoC/ZiggyStarClaw/releases/latest";
            openUrl(allocator, release_url);
        }

        if (ui_action.open_node_logs and builtin.os.tag == .windows) {
            // Node runner logs are written to node-service.log next to the unified node config.
            const node_cfg_path = unified_config.defaultConfigPath(allocator) catch null;
            if (node_cfg_path) |cfg_path| {
                defer allocator.free(cfg_path);

                const cfg_dir = std.fs.path.dirname(cfg_path) orelse ".";
                const log_path = std.fs.path.join(allocator, &.{ cfg_dir, "node-service.log" }) catch null;
                if (log_path) |p| {
                    defer allocator.free(p);

                    const log_exists = blk: {
                        std.fs.cwd().access(p, .{}) catch |err| switch (err) {
                            error.FileNotFound => break :blk false,
                            else => break :blk false,
                        };
                        break :blk true;
                    };

                    if (log_exists) {
                        openPath(allocator, p);
                    } else {
                        openPath(allocator, cfg_dir);
                    }
                } else {
                    openPath(allocator, cfg_dir);
                }
            }
        }

        if (builtin.os.tag == .windows) {
            if (ui_action.node_service_install_onlogon) {
                spawnWinNodeServiceJob(.install_onlogon, cfg.server_url, cfg.token, cfg.insecure_tls);
            }
            if (ui_action.node_service_uninstall) {
                spawnWinNodeServiceJob(.uninstall, cfg.server_url, cfg.token, cfg.insecure_tls);
            }
            if (ui_action.node_service_start) {
                spawnWinNodeServiceJob(.start, cfg.server_url, cfg.token, cfg.insecure_tls);
            }
            if (ui_action.node_service_stop) {
                spawnWinNodeServiceJob(.stop, cfg.server_url, cfg.token, cfg.insecure_tls);
            }
            if (ui_action.node_service_status) {
                spawnWinNodeServiceJob(.status, cfg.server_url, cfg.token, cfg.insecure_tls);
            }
        }

        if (ui_action.open_url) |url| {
            defer allocator.free(url);
            openUrl(allocator, url);
        }
        if (ui_action.open_download) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_path) |path| {
                openPath(allocator, path);
            }
        }
        if (ui_action.install_update) {
            const snapshot = ctx.update_state.snapshot();
            if (snapshot.download_path) |path| {
                if (installUpdate(allocator, path)) {
                    should_close = true;
                }
            }
        }
        if (ui_action.clear_saved) {
            cfg.deinit(allocator);
            cfg = config.initDefault(allocator) catch |err| {
                logger.err("Failed to reset config: {}", .{err});
                return;
            };
            if (cfg.ui_theme) |label| {
                theme.setMode(theme.modeFromLabel(label));
            }
            _ = std.fs.cwd().deleteFile("ziggystarclaw_config.json") catch {};
            app_state_state.last_connected = false;
            auto_connect_enabled = false;
            auto_connect_pending = false;
            _ = std.fs.cwd().deleteFile("ziggystarclaw_state.json") catch {};
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            ui.syncSettings(allocator, cfg);
        }

        if (ui_action.connect) {
            ctx.state = .connecting;
            ctx.clearError();
            auto_connect_enabled = true;
            ws_client.url = cfg.server_url;
            ws_client.token = cfg.token;
            ws_client.insecure_tls = cfg.insecure_tls;
            ws_client.connect_host_override = cfg.connect_host_override;
            should_reconnect = true;
            reconnect_backoff_ms = 500;
            next_reconnect_at_ms = 0;
            const started = connect_job.start() catch |err| blk: {
                logger.err("Failed to start connect thread: {}", .{err});
                ctx.state = .error_state;
                ctx.setError(@errorName(err)) catch {};
                break :blk false;
            };
            if (!started) {
                logger.warn("Connect attempt already in progress", .{});
            }
        }

        if (ui_action.disconnect) {
            connect_job.requestCancel();
            stopReadThread(&read_loop, &read_thread);
            if (!connect_job.isRunning()) {
                ws_client.disconnect();
            }
            should_reconnect = false;
            auto_connect_enabled = false;
            next_reconnect_at_ms = 0;
            reconnect_backoff_ms = 500;
            ctx.state = .disconnected;
            ctx.clearPendingRequests();
            ctx.clearAllSessionStates();
            ctx.clearNodes();
            ctx.clearCurrentNode();
            ctx.clearApprovals();
            ctx.clearNodeDescribes();
            ctx.clearNodeResult();
            ctx.clearOperatorNotice();
            next_ping_at_ms = 0;
        }

        if (ui_action.refresh_sessions) {
            sendSessionsListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.new_session) {
            if (ws_client.is_connected) {
                const key = makeNewSessionKey(allocator, "main") catch null;
                if (key) |session_key| {
                    defer allocator.free(session_key);
                    sendSessionsResetRequest(allocator, &ctx, &ws_client, session_key);
                    if (agents.setDefaultSession(allocator, "main", session_key) catch false) {
                        agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                    }
                    _ = active_window.manager.ensureChatPanelForAgent("main", agentDisplayName(&agents, "main"), session_key) catch {};
                    ctx.clearSessionState(session_key);
                    ctx.setCurrentSession(session_key) catch {};
                    sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
                    sendSessionsListRequest(allocator, &ctx, &ws_client);
                }
            }
        }

        if (ui_action.new_chat_agent_id) |agent_id| {
            defer allocator.free(agent_id);
            if (ws_client.is_connected) {
                const key = makeNewSessionKey(allocator, agent_id) catch null;
                if (key) |session_key| {
                    defer allocator.free(session_key);
                    sendSessionsResetRequest(allocator, &ctx, &ws_client, session_key);
                    if (agents.setDefaultSession(allocator, agent_id, session_key) catch false) {
                        agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                    }

                    _ = active_window.manager.ensureChatPanelForAgent(agent_id, agentDisplayName(&agents, agent_id), session_key) catch {};
                    ctx.clearSessionState(session_key);
                    ctx.setCurrentSession(session_key) catch {};
                    sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
                    sendSessionsListRequest(allocator, &ctx, &ws_client);
                }
            }
        }

        if (ui_action.refresh_nodes) {
            sendNodesListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.open_session) |open| {
            defer allocator.free(open.agent_id);
            defer allocator.free(open.session_key);
            ctx.setCurrentSession(open.session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
            _ = active_window.manager.ensureChatPanelForAgent(open.agent_id, agentDisplayName(&agents, open.agent_id), open.session_key) catch {};
            if (ws_client.is_connected) {
                sendChatHistoryRequest(allocator, &ctx, &ws_client, open.session_key);
            }
        }

        if (ui_action.select_session) |session_key| {
            defer allocator.free(session_key);
            ctx.setCurrentSession(session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
            if (session_keys.parse(session_key)) |parts| {
                _ = active_window.manager.ensureChatPanelForAgent(parts.agent_id, agentDisplayName(&agents, parts.agent_id), session_key) catch {};
            } else {
                _ = active_window.manager.ensureChatPanelForAgent("main", agentDisplayName(&agents, "main"), session_key) catch {};
            }
            if (ws_client.is_connected) {
                sendChatHistoryRequest(allocator, &ctx, &ws_client, session_key);
            }
        }

        if (ui_action.set_default_session) |choice| {
            defer allocator.free(choice.agent_id);
            defer allocator.free(choice.session_key);
            if (agents.setDefaultSession(allocator, choice.agent_id, choice.session_key) catch false) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
        }

        if (ui_action.delete_session) |session_key| {
            defer allocator.free(session_key);
            sendSessionsDeleteRequest(allocator, &ctx, &ws_client, session_key);
            _ = ctx.removeSessionByKey(session_key);
            ctx.clearSessionState(session_key);
            for (ui_windows.items) |w| {
                clearChatPanelsForSession(&w.manager, allocator, session_key);
            }
            if (agents.clearDefaultIfMatches(allocator, session_key)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
            }
            sendSessionsListRequest(allocator, &ctx, &ws_client);
        }

        if (ui_action.add_agent) |agent_action| {
            const owned = agent_action;
            if (agents.addOwned(allocator, .{
                .id = owned.id,
                .display_name = owned.display_name,
                .icon = owned.icon,
                .soul_path = null,
                .config_path = null,
                .personality_path = null,
                .default_session_key = null,
            })) |_| {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                _ = active_window.manager.ensureChatPanelForAgent(owned.id, agentDisplayName(&agents, owned.id), null) catch {};
            } else |err| {
                logger.warn("Failed to add agent: {}", .{err});
                allocator.free(owned.id);
                allocator.free(owned.display_name);
                allocator.free(owned.icon);
            }
        }

        if (ui_action.remove_agent_id) |agent_id| {
            defer allocator.free(agent_id);
            if (agents.remove(allocator, agent_id)) {
                agent_registry.AgentRegistry.save(allocator, "ziggystarclaw_agents.json", agents) catch {};
                for (ui_windows.items) |w| {
                    closeAgentChatPanels(&w.manager, agent_id);
                }
            }
        }

        if (ui_action.focus_session) |session_key| {
            defer allocator.free(session_key);
            ctx.setCurrentSession(session_key) catch |err| {
                logger.warn("Failed to set session: {}", .{err});
            };
        }

        if (ui_action.select_node) |node_id| {
            defer allocator.free(node_id);
            ctx.setCurrentNode(node_id) catch |err| {
                logger.warn("Failed to set node: {}", .{err});
            };
        }

        if (ui_action.invoke_node) |invoke| {
            var invoke_mut = invoke;
            defer invoke_mut.deinit(allocator);
            if (invoke_mut.node_id.len == 0 or invoke_mut.command.len == 0) {
                ctx.setOperatorNotice("Node ID and command are required.") catch {};
            } else {
                sendNodeInvokeRequest(
                    allocator,
                    &ctx,
                    &ws_client,
                    invoke_mut.node_id,
                    invoke_mut.command,
                    invoke_mut.params_json,
                    invoke_mut.timeout_ms,
                );
            }
        }

        if (ui_action.describe_node) |node_id| {
            defer allocator.free(node_id);
            if (node_id.len == 0) {
                ctx.setOperatorNotice("Node ID is required for describe.") catch {};
            } else {
                sendNodeDescribeRequest(allocator, &ctx, &ws_client, node_id);
            }
        }

        if (ui_action.resolve_approval) |resolve| {
            var resolve_mut = resolve;
            defer resolve_mut.deinit(allocator);
            sendExecApprovalResolveRequest(
                allocator,
                &ctx,
                &ws_client,
                resolve_mut.request_id,
                approvalDecisionLabel(resolve_mut.decision),
            );
        }

        if (ui_action.send_message) |payload| {
            defer allocator.free(payload.session_key);
            defer allocator.free(payload.message);
            ctx.setCurrentSession(payload.session_key) catch {};
            sendChatMessageRequest(allocator, &ctx, &ws_client, payload.session_key, payload.message);
        }

        for (ui_windows.items) |w| {
            ensureChatPanelsReady(allocator, &ctx, &ws_client, &agents, &w.manager);
        }

        if (ui_action.clear_node_result) {
            ctx.clearNodeResult();
        }

        if (ui_action.clear_node_describe) |node_id| {
            defer allocator.free(node_id);
            _ = ctx.removeNodeDescribeById(node_id);
        }

        if (ui_action.clear_operator_notice) {
            ctx.clearOperatorNotice();
        }

        if (connect_job.takeResult()) |result| {
            if (result.canceled) {
                if (result.err) |err_msg| {
                    allocator.free(err_msg);
                }
                ws_client.disconnect();
                ctx.state = .disconnected;
                ctx.clearError();
                next_ping_at_ms = 0;
            } else if (result.ok) {
                ctx.clearError();
                ctx.state = .authenticating;
                next_ping_at_ms = 0;
                startReadThread(&read_loop, &read_thread) catch |err| {
                    logger.err("Failed to start read thread: {}", .{err});
                };
            } else {
                ctx.state = .error_state;
                if (result.err) |err_msg| {
                    ctx.setError(err_msg) catch {};
                    allocator.free(err_msg);
                }
                if (should_reconnect) {
                    const now_ms = std.time.milliTimestamp();
                    next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                    const grown = reconnect_backoff_ms + reconnect_backoff_ms / 2;
                    reconnect_backoff_ms = if (grown > 15_000) 15_000 else grown;
                }
            }
        }

        if (should_reconnect and !ws_client.is_connected and read_thread == null) {
            const now_ms = std.time.milliTimestamp();
            if (next_reconnect_at_ms == 0 or now_ms >= next_reconnect_at_ms) {
                ctx.state = .connecting;
                ws_client.url = cfg.server_url;
                ws_client.token = cfg.token;
                ws_client.insecure_tls = cfg.insecure_tls;
                ws_client.connect_host_override = cfg.connect_host_override;
                if (!connect_job.isRunning()) {
                    const started = connect_job.start() catch blk: {
                        break :blk false;
                    };
                    if (!started) {
                        next_reconnect_at_ms = now_ms + reconnect_backoff_ms;
                        const grown = reconnect_backoff_ms + reconnect_backoff_ms / 2;
                        reconnect_backoff_ms = if (grown > 15_000) 15_000 else grown;
                        logger.info("Reconnect scheduled in {d}ms", .{reconnect_backoff_ms});
                    }
                }
            }
        }

        if ((ui_action.spawn_window or ui_action.spawn_window_template != null) and theme_eng.caps.supports_multi_window) {
            const index: usize = ui_windows.items.len + 1;

            var cur_w: c_int = 960;
            var cur_h: c_int = 720;
            _ = sdl.SDL_GetWindowSize(active_window.window, &cur_w, &cur_h);
            if (cur_w < 300) cur_w = 960;
            if (cur_h < 200) cur_h = 720;

            var title_buf: [96]u8 = undefined;
            var title_z: [:0]const u8 = "ZiggyStarClaw";
            var profile_override: ?theme_engine.ProfileId = active_window.profile_override;
            var mode_override: ?theme.Mode = active_window.theme_mode_override;
            var sampling_override: ?ui_commands.ImageSampling = active_window.image_sampling_override;
            var pixel_override: ?bool = active_window.pixel_snap_textured_override;

            var ws_for_new: workspace.Workspace = undefined;
            var ws_owned: bool = false;
            defer if (ws_owned) ws_for_new.deinit(allocator);

            if (ui_action.spawn_window_template) |tpl_idx| {
                const templates = theme_engine.runtime.getWindowTemplates();
                if (tpl_idx < templates.len) {
                    const tpl = templates[tpl_idx];
                    const max_cint_u32: u32 = @intCast(std.math.maxInt(c_int));
                    if (tpl.width > 0) cur_w = @intCast(@min(max_cint_u32, tpl.width));
                    if (tpl.height > 0) cur_h = @intCast(@min(max_cint_u32, tpl.height));
                    const base_title = if (tpl.title.len > 0) tpl.title else tpl.id;
                    title_z = std.fmt.bufPrintZ(&title_buf, "{s} ({d})", .{ base_title, index }) catch "ZiggyStarClaw";
                    if (profile.profileFromLabel(tpl.profile)) |pid| {
                        profile_override = pid;
                    }
                    if (tpl.variant) |variant| {
                        mode_override = theme.modeFromLabel(variant);
                    }
                    if (tpl.image_sampling) |label| {
                        sampling_override = parseImageSamplingLabel(label);
                    }
                    if (tpl.pixel_snap_textured) |snap| {
                        pixel_override = snap;
                    }
                    if (buildWorkspaceFromTemplate(allocator, tpl, &next_panel_id_global)) |ws_val| {
                        ws_for_new = ws_val;
                        ws_owned = true;
                    } else |_| {}
                }
            }

            if (!ws_owned) {
                title_z = std.fmt.bufPrintZ(&title_buf, "ZiggyStarClaw ({d})", .{index}) catch "ZiggyStarClaw";
                if (cloneWorkspaceRemap(allocator, &active_window.manager.workspace, &next_panel_id_global)) |ws_val| {
                    ws_for_new = ws_val;
                    ws_owned = true;
                } else |_| {}
            }

            const new_win = if (ws_owned)
                createUiWindow(
                    allocator,
                    &gpu,
                    title_z,
                    cur_w,
                    cur_h,
                    window_flags,
                    ws_for_new,
                    &next_panel_id_global,
                    false,
                    false,
                    profile_override,
                    mode_override,
                    sampling_override,
                    pixel_override,
                ) catch |err| blk: {
                    logger.warn("Failed to create window: {}", .{err});
                    break :blk null;
                }
            else
                null;

            if (new_win) |w| {
                // `createUiWindow` owns the workspace; don't free it here.
                ws_owned = false;

                var pos_x: c_int = 0;
                var pos_y: c_int = 0;
                _ = sdl.SDL_GetWindowPosition(active_window.window, &pos_x, &pos_y);
                const offs: c_int = @intCast(@min(index * 24, 240));
                _ = sdl.SDL_SetWindowPosition(w.window, pos_x + offs, pos_y + offs);
                ui_windows.append(allocator, w) catch {
                    destroyUiWindow(allocator, w);
                };
            }
        }

        if (window_close_requests.items.len > 0) {
            for (window_close_requests.items) |wid| {
                var i: usize = 0;
                while (i < ui_windows.items.len) {
                    const w = ui_windows.items[i];
                    if (w.id == wid and w.id != main_win.id) {
                        _ = ui_windows.swapRemove(i);
                        if (w.persist_in_workspace) {
                            // Dock panels back into the main window before closing (tear-off window behavior).
                            var taken = takeWorkspaceFromManager(allocator, &w.manager);
                            defer taken.deinit(allocator);
                            while (taken.panels.items.len > 0) {
                                const moved_panel_opt = taken.panels.pop();
                                if (moved_panel_opt) |moved_panel| {
                                    main_win.manager.putPanel(moved_panel) catch {
                                        // If we can't reattach, drop the panel safely.
                                        var tmp = moved_panel;
                                        tmp.deinit(allocator);
                                    };
                                } else {
                                    break;
                                }
                            }
                        }
                        destroyUiWindow(allocator, w);
                        break;
                    }
                    i += 1;
                }
            }
        }

        // Rendering is performed per-window during the UI loop above.
    }
}

fn approvalDecisionLabel(decision: operator_view.ExecApprovalDecision) []const u8 {
    return switch (decision) {
        .allow_once => "allow-once",
        .allow_always => "allow-always",
        .deny => "deny",
    };
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
    } else {
        logger.initFile(startup_log_path) catch |err| {
            logger.warn("Failed to open startup log: {}", .{err});
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
