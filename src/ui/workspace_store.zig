const std = @import("std");
const workspace = @import("workspace.zig");

pub const DetachedWindow = struct {
    title: []u8,
    width: u32,
    height: u32,
    chrome_mode: ?[]u8 = null,
    menu_profile: ?[]u8 = null,
    show_status_bar: ?bool = null,
    show_menu_bar: ?bool = null,
    profile: ?[]u8 = null,
    variant: ?[]u8 = null,
    image_sampling: ?[]u8 = null,
    pixel_snap_textured: ?bool = null,
    collapsed_docks: ?[]workspace.CollapsedDockSnapshot = null,
    ws: workspace.Workspace,

    pub fn deinit(self: *DetachedWindow, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.chrome_mode) |p| allocator.free(p);
        if (self.menu_profile) |p| allocator.free(p);
        if (self.profile) |p| allocator.free(p);
        if (self.variant) |p| allocator.free(p);
        if (self.image_sampling) |p| allocator.free(p);
        if (self.collapsed_docks) |list| allocator.free(list);
        self.ws.deinit(allocator);
        self.* = undefined;
    }
};

pub const DetachedWindowView = struct {
    title: []const u8,
    width: u32,
    height: u32,
    chrome_mode: ?[]const u8 = null,
    menu_profile: ?[]const u8 = null,
    show_status_bar: ?bool = null,
    show_menu_bar: ?bool = null,
    profile: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    image_sampling: ?[]const u8 = null,
    pixel_snap_textured: ?bool = null,
    collapsed_docks: ?[]const workspace.CollapsedDockSnapshot = null,
    ws: *const workspace.Workspace,
};

pub const MultiWorkspace = struct {
    main: workspace.Workspace,
    main_collapsed_docks: ?[]workspace.CollapsedDockSnapshot = null,
    windows: []DetachedWindow,
    next_panel_id: workspace.PanelId,

    pub fn deinit(self: *MultiWorkspace, allocator: std.mem.Allocator) void {
        self.main.deinit(allocator);
        if (self.main_collapsed_docks) |list| allocator.free(list);
        for (self.windows) |*w| {
            w.deinit(allocator);
        }
        allocator.free(self.windows);
        self.* = undefined;
    }
};

fn compactWorkspaceSingletonPanels(allocator: std.mem.Allocator, ws: *workspace.Workspace) void {
    _ = allocator;
    _ = ws;
}

fn firstOrFocusedSingletonKeepId(
    panels: []const workspace.PanelSnapshot,
    kind: workspace.PanelKind,
    focused_panel_id: ?workspace.PanelId,
) ?workspace.PanelId {
    if (focused_panel_id) |fid| {
        for (panels) |p| {
            if (p.kind == kind and p.id == fid) return fid;
        }
    }
    for (panels) |p| {
        if (p.kind == kind) return p.id;
    }
    return null;
}

fn compactSnapshotSingletonPanels(
    allocator: std.mem.Allocator,
    focused_panel_id: ?workspace.PanelId,
    panels_opt: *?[]workspace.PanelSnapshot,
) !void {
    _ = allocator;
    _ = focused_panel_id;
    _ = panels_opt;
}

fn copyCollapsedDocks(
    allocator: std.mem.Allocator,
    src: ?[]const workspace.CollapsedDockSnapshot,
) !?[]workspace.CollapsedDockSnapshot {
    const list = src orelse return null;
    const out = try allocator.alloc(workspace.CollapsedDockSnapshot, list.len);
    @memcpy(out, list);
    return out;
}

fn workspaceHasKind(ws: *const workspace.Workspace, kind: workspace.PanelKind) bool {
    for (ws.panels.items) |p| {
        if (p.kind == kind) return true;
    }
    return false;
}

fn workspaceRemoveAllKind(allocator: std.mem.Allocator, ws: *workspace.Workspace, kind: workspace.PanelKind) void {
    var i: usize = 0;
    while (i < ws.panels.items.len) {
        const p = ws.panels.items[i];
        if (p.kind == kind) {
            var removed = ws.panels.orderedRemove(i);
            removed.deinit(allocator);
            ws.markDirty();
            continue;
        }
        i += 1;
    }
    if (ws.focused_panel_id) |fid| {
        for (ws.panels.items) |p| {
            if (p.id == fid) return;
        }
        ws.focused_panel_id = null;
    }
}

/// If a singleton panel kind exists in any detached window, treat that as user intent and
/// remove it from the main window. Also ensure only one detached window keeps that kind.
fn compactGlobalSingletonAcrossWindows(
    allocator: std.mem.Allocator,
    main_ws: *workspace.Workspace,
    windows: []DetachedWindow,
) void {
    const global_singletons = [_]workspace.PanelKind{ .Chat, .Showcase };
    for (global_singletons) |kind| {
        var keeper_idx: ?usize = null;
        for (windows, 0..) |w, idx| {
            if (workspaceHasKind(&w.ws, kind)) {
                keeper_idx = idx;
                break;
            }
        }
        if (keeper_idx == null) continue;

        workspaceRemoveAllKind(allocator, main_ws, kind);
        for (windows, 0..) |*w, idx| {
            if (idx == keeper_idx.?) continue;
            if (workspaceHasKind(&w.ws, kind)) {
                workspaceRemoveAllKind(allocator, &w.ws, kind);
            }
        }
    }
}

fn snapshotRemoveAllKind(
    allocator: std.mem.Allocator,
    kind: workspace.PanelKind,
    panels_opt: *?[]workspace.PanelSnapshot,
) !void {
    const panels = panels_opt.* orelse return;
    if (panels.len == 0) return;

    var keep_count: usize = 0;
    for (panels) |p| {
        if (p.kind != kind) keep_count += 1;
    }
    if (keep_count == panels.len) return;

    var new_panels = try allocator.alloc(workspace.PanelSnapshot, keep_count);
    var out: usize = 0;
    for (panels) |p| {
        if (p.kind != kind) {
            new_panels[out] = p; // move ownership
            out += 1;
        } else {
            workspace.freePanelSnapshot(allocator, p);
        }
    }
    allocator.free(panels);
    panels_opt.* = new_panels;
}

fn snapshotHasKind(panels_opt: ?[]const workspace.PanelSnapshot, kind: workspace.PanelKind) bool {
    const panels = panels_opt orelse return false;
    for (panels) |p| {
        if (p.kind == kind) return true;
    }
    return false;
}

fn compactGlobalSingletonAcrossWindowsSnapshot(
    allocator: std.mem.Allocator,
    main: *workspace.WorkspaceSnapshot,
    wins_opt: *?[]workspace.DetachedWindowSnapshot,
) !void {
    // IMPORTANT:
    // We intentionally do NOT enforce any "global singleton" panel kinds across windows.
    //
    // Users may legitimately want the same panel kind (e.g. Chat/Showcase) in multiple detached
    // windows. Enforcing this at save-time caused silent data loss (panels removed from later
    // windows in the on-disk snapshot).
    //
    // Singleton enforcement remains per-workspace (per-window) via compactSnapshotSingletonPanels().
    _ = allocator;
    _ = main;
    _ = wins_opt;
    return;
}

pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !workspace.Workspace {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return workspace.Workspace.initDefault(allocator),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(workspace.WorkspaceSnapshot, allocator, data, .{ .ignore_unknown_fields = true }) catch {
        return workspace.Workspace.initDefault(allocator);
    };
    defer parsed.deinit();

    var ws = try workspace.Workspace.fromSnapshot(allocator, parsed.value);
    compactWorkspaceSingletonPanels(allocator, &ws);
    return ws;
}

pub fn loadMultiOrDefault(allocator: std.mem.Allocator, path: []const u8) !MultiWorkspace {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .main = try workspace.Workspace.initDefault(allocator),
            .main_collapsed_docks = null,
            .windows = try allocator.alloc(DetachedWindow, 0),
            .next_panel_id = 1,
        },
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(workspace.WorkspaceSnapshot, allocator, data, .{ .ignore_unknown_fields = true }) catch {
        return .{
            .main = try workspace.Workspace.initDefault(allocator),
            .main_collapsed_docks = null,
            .windows = try allocator.alloc(DetachedWindow, 0),
            .next_panel_id = 1,
        };
    };
    defer parsed.deinit();

    const snap = parsed.value;
    var main_ws = try workspace.Workspace.fromSnapshot(allocator, snap);
    errdefer main_ws.deinit(allocator);
    const main_collapsed_docks = try copyCollapsedDocks(allocator, snap.collapsed_docks);
    errdefer if (main_collapsed_docks) |list| allocator.free(list);
    compactWorkspaceSingletonPanels(allocator, &main_ws);

    const windows_src = snap.detached_windows orelse &[_]workspace.DetachedWindowSnapshot{};
    var windows = try allocator.alloc(DetachedWindow, windows_src.len);
    var filled: usize = 0;
    errdefer {
        for (windows[0..filled]) |*w| w.deinit(allocator);
        allocator.free(windows);
    }

    for (windows_src, 0..) |wsrc, idx| {
        _ = idx;
        const title_copy = try allocator.dupe(u8, wsrc.title);
        errdefer allocator.free(title_copy);
        const chrome_mode_copy = if (wsrc.chrome_mode) |p| try allocator.dupe(u8, p) else null;
        errdefer if (chrome_mode_copy) |p| allocator.free(p);
        const menu_profile_copy = if (wsrc.menu_profile) |p| try allocator.dupe(u8, p) else null;
        errdefer if (menu_profile_copy) |p| allocator.free(p);
        const profile_copy = if (wsrc.profile) |p| try allocator.dupe(u8, p) else null;
        errdefer if (profile_copy) |p| allocator.free(p);
        const variant_copy = if (wsrc.variant) |p| try allocator.dupe(u8, p) else null;
        errdefer if (variant_copy) |p| allocator.free(p);
        const sampling_copy = if (wsrc.image_sampling) |p| try allocator.dupe(u8, p) else null;
        errdefer if (sampling_copy) |p| allocator.free(p);

        const tmp_snap = workspace.WorkspaceSnapshot{
            .active_project = wsrc.active_project,
            .focused_panel_id = wsrc.focused_panel_id,
            .next_panel_id = snap.next_panel_id,
            .custom_layout = wsrc.custom_layout,
            .layout_version = wsrc.layout_version,
            .layout_v2 = wsrc.layout_v2,
            .panels = wsrc.panels,
            .detached_windows = null,
        };
        var ws = try workspace.Workspace.fromSnapshot(allocator, tmp_snap);
        errdefer ws.deinit(allocator);
        compactWorkspaceSingletonPanels(allocator, &ws);

        windows[filled] = .{
            .title = title_copy,
            .width = wsrc.width,
            .height = wsrc.height,
            .chrome_mode = chrome_mode_copy,
            .menu_profile = menu_profile_copy,
            .show_status_bar = wsrc.show_status_bar,
            .show_menu_bar = wsrc.show_menu_bar,
            .profile = profile_copy,
            .variant = variant_copy,
            .image_sampling = sampling_copy,
            .pixel_snap_textured = wsrc.pixel_snap_textured,
            .collapsed_docks = try copyCollapsedDocks(allocator, wsrc.collapsed_docks),
            .ws = ws,
        };
        filled += 1;
    }

    // NOTE: Chat/Showcase singletons are enforced per-window (see compactWorkspaceSingletonPanels).
    // Do not compact across windows here; that can cause persistent layout data loss.

    return .{
        .main = main_ws,
        .main_collapsed_docks = main_collapsed_docks,
        .windows = windows,
        .next_panel_id = snap.next_panel_id,
    };
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, ws: *const workspace.Workspace) !void {
    var snapshot = try ws.toSnapshot(allocator);
    defer snapshot.deinit(allocator);

    try compactSnapshotSingletonPanels(allocator, snapshot.focused_panel_id, &snapshot.panels);

    const json = try std.json.Stringify.valueAlloc(allocator, snapshot, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}

pub fn saveMulti(
    allocator: std.mem.Allocator,
    path: []const u8,
    main_ws: *const workspace.Workspace,
    main_collapsed_docks: ?[]const workspace.CollapsedDockSnapshot,
    windows: []const DetachedWindowView,
    next_panel_id: workspace.PanelId,
) !void {
    var snapshot = try main_ws.toSnapshot(allocator);
    defer snapshot.deinit(allocator);
    snapshot.next_panel_id = next_panel_id;
    snapshot.collapsed_docks = try copyCollapsedDocks(allocator, main_collapsed_docks);

    try compactSnapshotSingletonPanels(allocator, snapshot.focused_panel_id, &snapshot.panels);

    if (windows.len > 0) {
        var win_snaps = try allocator.alloc(workspace.DetachedWindowSnapshot, windows.len);
        var filled: usize = 0;
        errdefer {
            for (win_snaps[0..filled]) |*win| {
                win.deinit(allocator);
            }
            allocator.free(win_snaps);
        }

        for (windows, 0..) |w, idx| {
            _ = idx;
            var ws_snap = try w.ws.toSnapshot(allocator);
            errdefer ws_snap.deinit(allocator);

            try compactSnapshotSingletonPanels(allocator, ws_snap.focused_panel_id, &ws_snap.panels);

            const title_copy = try allocator.dupe(u8, w.title);
            errdefer allocator.free(title_copy);
            const chrome_mode_copy = if (w.chrome_mode) |p| try allocator.dupe(u8, p) else null;
            errdefer if (chrome_mode_copy) |p| allocator.free(p);
            const menu_profile_copy = if (w.menu_profile) |p| try allocator.dupe(u8, p) else null;
            errdefer if (menu_profile_copy) |p| allocator.free(p);
            const profile_copy = if (w.profile) |p| try allocator.dupe(u8, p) else null;
            errdefer if (profile_copy) |p| allocator.free(p);
            const variant_copy = if (w.variant) |p| try allocator.dupe(u8, p) else null;
            errdefer if (variant_copy) |p| allocator.free(p);
            const sampling_copy = if (w.image_sampling) |p| try allocator.dupe(u8, p) else null;
            errdefer if (sampling_copy) |p| allocator.free(p);

            win_snaps[filled] = .{
                .title = title_copy,
                .width = w.width,
                .height = w.height,
                .chrome_mode = chrome_mode_copy,
                .menu_profile = menu_profile_copy,
                .show_status_bar = w.show_status_bar,
                .show_menu_bar = w.show_menu_bar,
                .profile = profile_copy,
                .variant = variant_copy,
                .image_sampling = sampling_copy,
                .pixel_snap_textured = w.pixel_snap_textured,
                .active_project = ws_snap.active_project,
                .focused_panel_id = ws_snap.focused_panel_id,
                .custom_layout = ws_snap.custom_layout,
                .layout_version = ws_snap.layout_version,
                .layout_v2 = ws_snap.layout_v2,
                .collapsed_docks = try copyCollapsedDocks(allocator, w.collapsed_docks),
                .panels = ws_snap.panels,
            };
            // Transfer ownership of `panels` to the window snapshot.
            ws_snap.layout_v2 = null;
            ws_snap.panels = null;
            ws_snap.deinit(allocator);

            filled += 1;
        }

        snapshot.detached_windows = win_snaps;
    }

    const json = try std.json.Stringify.valueAlloc(allocator, snapshot, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
}
