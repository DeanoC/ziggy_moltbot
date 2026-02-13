const std = @import("std");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");
const dock_graph = @import("layout/dock_graph.zig");
const dock_rail = @import("layout/dock_rail.zig");
const panel_manager = @import("panel_manager.zig");
const text_buffer = @import("text_buffer.zig");
const workspace = @import("workspace.zig");
const draw_context = @import("draw_context.zig");
const command_queue = @import("render/command_queue.zig");
const data_uri = @import("data_uri.zig");
const attachment_cache = @import("attachment_cache.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const chat_view = @import("chat_view.zig");
const image_cache = @import("image_cache.zig");
const ui_systems = @import("ui_systems.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const cursor = @import("input/cursor.zig");
const nav = @import("input/nav.zig");
const nav_router = @import("input/nav_router.zig");
const colors = @import("theme/colors.zig");
const style_sheet = @import("theme_engine/style_sheet.zig");
const agent_registry = @import("../client/agent_registry.zig");
const session_keys = @import("../client/session_keys.zig");
const types = @import("../protocol/types.zig");
const chat_panel = @import("panels/chat_panel.zig");
const code_editor_panel = @import("panels/code_editor_panel.zig");
const tool_output_panel = @import("panels/tool_output_panel.zig");
const control_panel = @import("panels/control_panel.zig");
const agents_panel = @import("panels/agents_panel.zig");
const inbox_panel = @import("panels/inbox_panel.zig");
const workboard_panel = @import("panels/workboard_panel.zig");
const settings_panel = @import("panels/settings_panel.zig");
const operator_view = @import("operator_view.zig");
const approvals_inbox_view = @import("approvals_inbox_view.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const showcase_panel = @import("panels/showcase_panel.zig");
const session_presenter = @import("session_presenter.zig");
const status_bar = @import("status_bar.zig");
const widgets = @import("widgets/widgets.zig");
const text_input_backend = @import("input/text_input_backend.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const profiler = @import("../utils/profiler.zig");
const panel_chrome = @import("panel_chrome.zig");
const surface_chrome = @import("surface_chrome.zig");

pub const SendMessageAction = struct {
    session_key: []u8,
    message: []u8,
};

pub const WindowChromeRole = enum {
    main_workspace,
    detached_panel,
    template_utility,
};

pub const WindowMenuProfile = enum {
    full,
    compact,
    minimal,
};

pub const WindowUiState = struct {
    custom_split_dragging: bool = false,
    custom_window_menu_open: bool = false,
    dock_drag: DockDragState = .{},
    split_drag: DockSplitDragState = .{},
    nav: nav.NavState = .{},
    chrome_role: WindowChromeRole = .main_workspace,
    menu_profile: WindowMenuProfile = .full,
    show_status_bar: bool = true,
    show_menu_bar: bool = true,
    // Last dock content rect used for layout in window-local coordinates.
    // Native cross-window drag/drop uses this to align target hit-testing with rendered bounds.
    last_dock_content_rect: draw_context.Rect = .{
        .min = .{ 0.0, 0.0 },
        .max = .{ 0.0, 0.0 },
    },
    collapsed_docks: dock_rail.CollapsedSet = .{},
    dock_flyout: DockFlyoutState = .{},
    dock_rail_anim: DockRailAnimState = .{},

    fullscreen_page: FullscreenPage = .home,
    // When true, the first frame for a given profile applies the theme pack's `layouts/workspace.json`
    // preset (open panels, focus, optional sizing). For tear-off / template windows we keep the
    // workspace exactly as authored/saved and do not auto-open extra panels.
    theme_layout_presets_enabled: bool = true,
    // Track which profile layouts have been applied for this window so theme layout
    // presets don't fight user-driven layout changes every frame.
    theme_layout_applied: [4]bool = .{ false, false, false, false },
    // Optional per-window theme pack override. When null, the window uses the global config pack.
    theme_pack_override: ?[]u8 = null,
    // When set (by the Window menu), the native main loop will force-reload the window's pack.
    theme_pack_reload_requested: bool = false,

    pub fn deinit(self: *WindowUiState, allocator: std.mem.Allocator) void {
        self.nav.deinit(allocator);
        if (self.theme_pack_override) |buf| allocator.free(buf);
        self.* = undefined;
    }
};

const FullscreenPage = enum {
    home,
    agents,
    settings,
    chat,
    workboard,
    showcase,
};

pub const UiAction = struct {
    send_message: ?SendMessageAction = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    reload_theme_pack: bool = false,
    browse_theme_pack: bool = false,
    browse_theme_pack_override: bool = false,
    clear_theme_pack_override: bool = false,
    reload_theme_pack_override: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    spawn_window: bool = false,
    spawn_window_template: ?u32 = null,
    refresh_sessions: bool = false,
    new_session: bool = false,
    new_chat_session_key: ?[]u8 = null,
    select_session: ?[]u8 = null,
    select_session_id: ?[]u8 = null,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?@import("panels/agents_panel.zig").AgentSessionAction = null,
    set_default_session: ?@import("panels/agents_panel.zig").AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    add_agent: ?@import("panels/agents_panel.zig").AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
    open_agent_file: ?@import("panels/agents_panel.zig").AgentFileOpenAction = null,
    focus_session: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,

    node_profile_apply_client: bool = false,
    node_profile_apply_service: bool = false,
    node_profile_apply_session: bool = false,

    // Windows node runner helpers (SCM service)
    node_service_install_onlogon: bool = false,
    node_service_start: bool = false,
    node_service_stop: bool = false,
    node_service_status: bool = false,
    node_service_uninstall: bool = false,
    open_node_logs: bool = false,

    refresh_nodes: bool = false,
    refresh_workboard: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?@import("operator_view.zig").NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?@import("operator_view.zig").ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
    save_workspace: bool = false,
    detach_panel_id: ?workspace.PanelId = null,
    detach_group_node_id: ?dock_graph.NodeId = null,
    // When non-null, the UI already removed the panel from the source manager; the native loop
    // should create the tear-off window from this panel and then free the pointer.
    detach_panel: ?*workspace.Panel = null,
    open_url: ?[]u8 = null,
};

const PanelDrawResult = struct {
    session_key: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

const PanelFrameResult = struct {
    content_rect: draw_context.Rect,
    close_clicked: bool,
    detach_clicked: bool,
    clicked: bool,
};

const DockDragState = struct {
    panel_id: ?workspace.PanelId = null,
    source_node_id: ?dock_graph.NodeId = null,
    source_tab_index: usize = 0,
    press_pos: [2]f32 = .{ 0.0, 0.0 },
    dragging: bool = false,

    pub fn clear(self: *DockDragState) void {
        self.* = .{};
    }
};

const DockSplitDragState = struct {
    node_id: ?dock_graph.NodeId = null,
    axis: dock_graph.Axis = .vertical,

    pub fn clear(self: *DockSplitDragState) void {
        self.* = .{};
    }
};

const DockFlyoutState = struct {
    node_id: ?dock_graph.NodeId = null,
    side: dock_rail.Side = .left,
    pinned: bool = false,

    pub fn clear(self: *DockFlyoutState) void {
        self.* = .{};
    }
};

const DockRailAnimState = struct {
    initialized: bool = false,
    left_width: f32 = 0.0,
    right_width: f32 = 0.0,

    pub fn update(self: *DockRailAnimState, target_left: f32, target_right: f32, dt: f32) void {
        if (!self.initialized) {
            self.initialized = true;
            self.left_width = target_left;
            self.right_width = target_right;
            return;
        }
        self.left_width = smoothDockRailWidth(self.left_width, target_left, dt);
        self.right_width = smoothDockRailWidth(self.right_width, target_right, dt);
    }
};

fn smoothDockRailWidth(current: f32, target: f32, dt: f32) f32 {
    if (@abs(current - target) <= 0.2) return target;
    const blend = 1.0 - std.math.exp(-14.0 * dt);
    return current + (target - current) * blend;
}

const DockTabHit = struct {
    panel_id: workspace.PanelId,
    node_id: dock_graph.NodeId,
    tab_index: usize,
    rect: draw_context.Rect,
};

const DockTabHitList = struct {
    items: [64]DockTabHit = undefined,
    len: usize = 0,

    pub fn append(self: *DockTabHitList, item: DockTabHit) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *const DockTabHitList) []const DockTabHit {
        return self.items[0..self.len];
    }
};

const DockDropTarget = struct {
    node_id: dock_graph.NodeId,
    location: dock_graph.DropLocation,
    rect: draw_context.Rect,
};

const DockDropTargetList = struct {
    items: [96]DockDropTarget = undefined,
    len: usize = 0,

    pub fn append(self: *DockDropTargetList, item: DockDropTarget) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn findAt(self: *const DockDropTargetList, pos: [2]f32) ?DockDropTarget {
        // Prefer center targets, then side targets to match IDE expectations.
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location != .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location == .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        return null;
    }
};

const DockGroupFrameResult = struct {
    content_rect: draw_context.Rect,
    close_panel_id: ?workspace.PanelId = null,
    detach_panel_id: ?workspace.PanelId = null,
    collapse_clicked: bool = false,
    frame_clicked: bool = false,
};

const DockRailInteractionResult = struct {
    hovered_item: ?dock_rail.Item = null,
    clicked_item: ?dock_rail.Item = null,
    focus_panel_id: ?workspace.PanelId = null,
};

const DockFlyoutResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    session_key: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    changed_layout: bool = false,
    expand_node_id: ?dock_graph.NodeId = null,
};

const WindowPanelToggle = struct {
    label: []const u8,
    kind: workspace.PanelKind,
};

const window_panel_toggles = [_]WindowPanelToggle{
    .{ .label = "Workspace", .kind = .Control },
    .{ .label = "Chat", .kind = .Chat },
    .{ .label = "Agents", .kind = .Agents },
    .{ .label = "Operator", .kind = .Operator },
    .{ .label = "Approvals", .kind = .ApprovalsInbox },
    .{ .label = "Activity", .kind = .Inbox },
    .{ .label = "Workboard", .kind = .Workboard },
    .{ .label = "Settings", .kind = .Settings },
    .{ .label = "Showcase", .kind = .Showcase },
};

fn customMenuHeight(line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs * 2.0;
}

fn statusBarHeight(line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs * 2.0;
}

fn focusedDockNodeId(manager: *panel_manager.PanelManager) ?dock_graph.NodeId {
    const focused_panel = manager.workspace.focused_panel_id orelse return null;
    const loc = manager.workspace.dock_layout.findPanel(focused_panel) orelse return null;
    return loc.node_id;
}

fn resetDockLayout(manager: *panel_manager.PanelManager) void {
    manager.workspace.dock_layout.clear();
    if (manager.workspace.syncDockLayout() catch false) {
        manager.workspace.markDirty();
    }
}

fn moveFocusedTabToNewGroup(manager: *panel_manager.PanelManager) bool {
    const focused_panel = manager.workspace.focused_panel_id orelse return false;
    const loc = manager.workspace.dock_layout.findPanel(focused_panel) orelse return false;
    if (manager.workspace.dock_layout.splitNodeWithPanel(loc.node_id, focused_panel, .right) catch false) {
        manager.workspace.markDirty();
        manager.focusPanel(focused_panel);
        return true;
    }
    return false;
}

fn closeFocusedGroup(manager: *panel_manager.PanelManager, allocator: std.mem.Allocator) bool {
    const node_id = focusedDockNodeId(manager) orelse return false;
    const node = manager.workspace.dock_layout.getNode(node_id) orelse return false;
    const tabs = switch (node.*) {
        .tabs => |t| t,
        .split => return false,
    };
    if (tabs.tabs.items.len == 0) return false;

    var panel_ids = std.ArrayList(workspace.PanelId).empty;
    defer panel_ids.deinit(allocator);
    panel_ids.ensureTotalCapacity(allocator, tabs.tabs.items.len) catch return false;
    panel_ids.appendSlice(allocator, tabs.tabs.items) catch return false;

    var closed_any = false;
    for (panel_ids.items) |pid| {
        if (manager.closePanel(pid)) {
            closed_any = true;
        }
    }
    return closed_any;
}

fn drawCustomMenuBar(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    cfg: *const config.Config,
    action: *UiAction,
    win_state: *WindowUiState,
) void {
    const t = dc.theme;
    surface_chrome.drawMenuBar(dc, rect);
    dc.drawRect(rect, .{ .stroke = t.colors.border, .thickness = 1.0 });

    const label = "Window";
    const button_width = dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
    const button_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.sm, rect.min[1] + t.spacing.xs },
        .{ button_width, rect.size()[1] - t.spacing.xs * 2.0 },
    );
    const menu_open = win_state.custom_window_menu_open;
    if (widgets.button.draw(dc, button_rect, label, queue, .{
        .variant = if (menu_open) .secondary else .ghost,
        .radius = t.radius.sm,
    })) {
        win_state.custom_window_menu_open = !win_state.custom_window_menu_open;
    }

    if (!win_state.custom_window_menu_open) {
        return;
    }

    if (win_state.menu_profile != .full) {
        drawContextualWindowMenu(dc, rect, queue, manager, action, win_state);
        return;
    }

    const menu_padding = t.spacing.xs;
    const item_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const menu_width: f32 = computeWindowMenuWidth(dc, cfg, win_state, item_height);
    // Multi-window is a platform capability (desktop native), not a UI profile feature.
    // Even if the user is running the Phone/Tablet profile on desktop, they may still want
    // detachable/multi-window UI (Winamp-style use case).
    const allow_multi_window = (builtin.cpu.arch != .wasm32) and !builtin.abi.isAndroid();
    const templates_all = theme_runtime.getWindowTemplates();
    const max_templates: usize = 8;
    const templates = templates_all[0..@min(templates_all.len, max_templates)];
    const recent = cfg.ui_theme_pack_recent orelse &[_][]const u8{};
    const max_recent: usize = 4;
    const recent_shown: usize = @min(recent.len, max_recent);
    const panel_items_u: usize = window_panel_toggles.len;
    const layout_items_u: usize = 3 + (if (allow_multi_window) @as(usize, 1) else @as(usize, 0));
    const theme_items_u: usize = @as(usize, 3) + (if (win_state.theme_pack_override != null) @as(usize, 1) else @as(usize, 0)) + recent_shown;
    const multi_items_u: usize = if (allow_multi_window) (1 + templates.len) else 0;
    const item_count_u: usize = panel_items_u + layout_items_u + theme_items_u + multi_items_u;
    const item_count: f32 = @floatFromInt(item_count_u);
    const menu_height = menu_padding * 2.0 + item_height * item_count;
    const menu_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + t.spacing.sm, rect.max[1] + t.spacing.xs },
        .{ menu_width, menu_height },
    );
    panel_chrome.draw(dc, menu_rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });

    var cursor_y = menu_rect.min[1] + menu_padding;
    for (window_panel_toggles) |entry| {
        const has_panel = manager.hasPanel(entry.kind);
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            entry.label,
            has_panel,
            false,
        )) {
            if (has_panel) {
                _ = manager.closePanelByKind(entry.kind);
            } else {
                manager.ensurePanel(entry.kind);
            }
            win_state.custom_window_menu_open = false;
        }
        cursor_y += item_height;
    }

    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Layout: Reset",
        false,
        false,
    )) {
        resetDockLayout(manager);
        win_state.custom_window_menu_open = false;
    }

    cursor_y += item_height;
    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Layout: Move tab to new group",
        false,
        manager.workspace.focused_panel_id == null,
    )) {
        _ = moveFocusedTabToNewGroup(manager);
        win_state.custom_window_menu_open = false;
    }

    cursor_y += item_height;
    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Layout: Close group",
        false,
        focusedDockNodeId(manager) == null,
    )) {
        _ = closeFocusedGroup(manager, dc.allocator);
        win_state.custom_window_menu_open = false;
    }

    if (allow_multi_window) {
        cursor_y += item_height;
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "Layout: Move group to window",
            false,
            focusedDockNodeId(manager) == null,
        )) {
            action.detach_group_node_id = focusedDockNodeId(manager);
            win_state.custom_window_menu_open = false;
        }
    }

    const can_browse_pack = builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .macos;
    const global_pack = cfg.ui_theme_pack orelse "";
    const effective_pack = win_state.theme_pack_override orelse global_pack;

    cursor_y += item_height;
    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Theme pack: Global",
        win_state.theme_pack_override == null,
        false,
    )) {
        if (win_state.theme_pack_override) |buf| {
            dc.allocator.free(buf);
            win_state.theme_pack_override = null;
        }
        win_state.theme_layout_applied = .{ false, false, false, false };
        win_state.custom_window_menu_open = false;
    }

    cursor_y += item_height;
    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Theme pack: Browse...",
        false,
        !can_browse_pack,
    )) {
        if (can_browse_pack) {
            action.browse_theme_pack_override = true;
        }
        win_state.custom_window_menu_open = false;
    }

    cursor_y += item_height;
    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Theme pack: Reload",
        false,
        effective_pack.len == 0,
    )) {
        if (effective_pack.len > 0) {
            win_state.theme_pack_reload_requested = true;
        }
        win_state.custom_window_menu_open = false;
    }

    if (win_state.theme_pack_override != null) {
        cursor_y += item_height;
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "Theme pack: Clear override",
            false,
            false,
        )) {
            if (win_state.theme_pack_override) |buf| {
                dc.allocator.free(buf);
                win_state.theme_pack_override = null;
            }
            win_state.theme_layout_applied = .{ false, false, false, false };
            win_state.custom_window_menu_open = false;
        }
    }

    // Quick picks from the global MRU list.
    if (recent_shown > 0) {
        var i: usize = 0;
        while (i < recent_shown) : (i += 1) {
            const item = recent[i];
            var label_buf: [200]u8 = undefined;
            const short = blk: {
                const prefix = "themes/";
                if (std.mem.startsWith(u8, item, prefix)) break :blk item[prefix.len..];
                const idx = std.mem.lastIndexOfAny(u8, item, "/\\") orelse break :blk item;
                if (idx + 1 < item.len) break :blk item[idx + 1 ..];
                break :blk item;
            };
            const item_label = std.fmt.bufPrint(&label_buf, "Theme: {s}", .{short}) catch "Theme";

            cursor_y += item_height;
            if (drawMenuItem(
                dc,
                queue,
                draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
                item_label,
                win_state.theme_pack_override != null and std.mem.eql(u8, win_state.theme_pack_override.?, item),
                false,
            )) {
                const owned = dc.allocator.dupe(u8, item) catch null;
                if (owned) |buf| {
                    if (win_state.theme_pack_override) |old| dc.allocator.free(old);
                    win_state.theme_pack_override = buf;
                    win_state.theme_layout_applied = .{ false, false, false, false };
                }
                win_state.custom_window_menu_open = false;
            }
        }
    }

    if (allow_multi_window) {
        cursor_y += item_height;
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "New Window",
            false,
            false,
        )) {
            action.spawn_window = true;
            win_state.custom_window_menu_open = false;
        }

        for (templates, 0..) |tpl, idx| {
            cursor_y += item_height;
            var label_buf: [96]u8 = undefined;
            const title = if (tpl.title.len > 0) tpl.title else tpl.id;
            const label2 = std.fmt.bufPrint(&label_buf, "New: {s}", .{title}) catch title;
            if (drawMenuItem(
                dc,
                queue,
                draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
                label2,
                false,
                false,
            )) {
                action.spawn_window_template = @intCast(idx);
                win_state.custom_window_menu_open = false;
            }
        }
    }

    var clicked_outside = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and !menu_rect.contains(md.pos) and !button_rect.contains(md.pos)) {
                    clicked_outside = true;
                }
            },
            else => {},
        }
    }
    if (clicked_outside) {
        win_state.custom_window_menu_open = false;
    }
}

fn drawContextualWindowMenu(
    dc: *draw_context.DrawContext,
    menu_bar_rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    action: *UiAction,
    win_state: *WindowUiState,
) void {
    const t = dc.theme;
    const menu_padding = t.spacing.xs;
    const item_height = dc.lineHeight() + t.spacing.xs * 2.0;
    const allow_multi_window = (builtin.cpu.arch != .wasm32) and !builtin.abi.isAndroid();
    const templates_all = theme_runtime.getWindowTemplates();
    const max_templates: usize = 8;
    const templates = templates_all[0..@min(templates_all.len, max_templates)];

    const include_panel_toggles = win_state.menu_profile == .compact;
    const include_multi = allow_multi_window;
    const include_move_tab_group = win_state.menu_profile == .compact;
    const panel_items: usize = if (include_panel_toggles) window_panel_toggles.len else 0;
    const layout_items: usize = 2 + (if (include_move_tab_group) @as(usize, 1) else @as(usize, 0)) + (if (allow_multi_window) @as(usize, 1) else @as(usize, 0));
    const multi_items: usize = if (include_multi) (1 + templates.len) else 0;
    const item_count_u: usize = panel_items + layout_items + multi_items;
    if (item_count_u == 0) {
        win_state.custom_window_menu_open = false;
        return;
    }

    const menu_width: f32 = if (win_state.menu_profile == .minimal) 240.0 else 300.0;
    const item_count: f32 = @floatFromInt(item_count_u);
    const menu_height = menu_padding * 2.0 + item_height * item_count;
    const menu_rect = draw_context.Rect.fromMinSize(
        .{ menu_bar_rect.min[0] + t.spacing.sm, menu_bar_rect.max[1] + t.spacing.xs },
        .{ menu_width, menu_height },
    );

    panel_chrome.draw(dc, menu_rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });

    var cursor_y = menu_rect.min[1] + menu_padding;
    if (include_panel_toggles) {
        for (window_panel_toggles) |entry| {
            const has_panel = manager.hasPanel(entry.kind);
            if (drawMenuItem(
                dc,
                queue,
                draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
                entry.label,
                has_panel,
                false,
            )) {
                if (has_panel) {
                    _ = manager.closePanelByKind(entry.kind);
                } else {
                    manager.ensurePanel(entry.kind);
                }
                win_state.custom_window_menu_open = false;
            }
            cursor_y += item_height;
        }
    }

    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Layout: Reset",
        false,
        false,
    )) {
        resetDockLayout(manager);
        win_state.custom_window_menu_open = false;
    }
    cursor_y += item_height;

    if (drawMenuItem(
        dc,
        queue,
        draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
        "Layout: Close group",
        false,
        focusedDockNodeId(manager) == null,
    )) {
        _ = closeFocusedGroup(manager, dc.allocator);
        win_state.custom_window_menu_open = false;
    }
    cursor_y += item_height;

    if (include_move_tab_group) {
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "Layout: Move tab to new group",
            false,
            manager.workspace.focused_panel_id == null,
        )) {
            _ = moveFocusedTabToNewGroup(manager);
            win_state.custom_window_menu_open = false;
        }
        cursor_y += item_height;
    }

    if (allow_multi_window) {
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "Layout: Move group to window",
            false,
            focusedDockNodeId(manager) == null,
        )) {
            action.detach_group_node_id = focusedDockNodeId(manager);
            win_state.custom_window_menu_open = false;
        }
        cursor_y += item_height;
    }

    if (include_multi) {
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "New Window",
            false,
            false,
        )) {
            action.spawn_window = true;
            win_state.custom_window_menu_open = false;
        }
        cursor_y += item_height;

        for (templates, 0..) |tpl, idx| {
            var label_buf: [96]u8 = undefined;
            const title = if (tpl.title.len > 0) tpl.title else tpl.id;
            const label = std.fmt.bufPrint(&label_buf, "New: {s}", .{title}) catch title;
            if (drawMenuItem(
                dc,
                queue,
                draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
                label,
                false,
                false,
            )) {
                action.spawn_window_template = @intCast(idx);
                win_state.custom_window_menu_open = false;
            }
            cursor_y += item_height;
        }
    }

    var clicked_outside = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and !menu_rect.contains(md.pos)) {
                    clicked_outside = true;
                }
            },
            else => {},
        }
    }
    if (clicked_outside) {
        win_state.custom_window_menu_open = false;
    }
}

fn drawMenuItem(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    label: []const u8,
    selected: bool,
    disabled: bool,
) bool {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const item_style = ss.menu.item;
    const cs = ss.checkbox;
    const nav_state = nav_router.get();
    const nav_id = if (nav_state != null) nav_router.makeWidgetId(@returnAddress(), "main_window.menu_item", label) else 0;
    if (nav_state) |navp| navp.registerItem(dc.allocator, nav_id, rect);
    const nav_active = if (nav_state) |navp| navp.isActive() else false;
    const focused = if (nav_state) |navp| navp.isFocusedId(nav_id) else false;

    const allow_hover = theme_runtime.allowHover(queue);
    const hovered = (allow_hover and rect.contains(queue.state.mouse_pos)) or (nav_active and focused);
    const pressed = rect.contains(queue.state.mouse_pos) and queue.state.mouse_down_left and queue.state.pointer_kind != .nav;

    const radius = item_style.radius orelse t.radius.sm;
    const transparent: colors.Color = .{ 0.0, 0.0, 0.0, 0.0 };
    var fill: ?style_sheet.Paint = item_style.fill;
    var text_color: colors.Color = item_style.text orelse t.colors.text_primary;
    var border_color: colors.Color = item_style.border orelse transparent;

    // Apply selection + interaction state overrides (most-specific last).
    if (selected and item_style.states.selected.isSet()) {
        const st = item_style.states.selected;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }
    if (focused and item_style.states.focused.isSet()) {
        const st = item_style.states.focused;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }
    if (hovered and item_style.states.hover.isSet()) {
        const st = item_style.states.hover;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }
    if (pressed and item_style.states.pressed.isSet()) {
        const st = item_style.states.pressed;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }
    if (selected and hovered and item_style.states.selected_hover.isSet()) {
        const st = item_style.states.selected_hover;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }
    if (disabled and item_style.states.disabled.isSet()) {
        const st = item_style.states.disabled;
        if (st.fill) |v| fill = v;
        if (st.text) |v| text_color = v;
        if (st.border) |v| border_color = v;
    }

    if (!disabled) {
        if (fill) |paint| {
            panel_chrome.drawPaintRoundedRect(dc, rect, radius, paint);
        } else if (hovered) {
            dc.drawRoundedRect(rect, radius, .{ .fill = colors.withAlpha(t.colors.primary, 0.08) });
        }
    } else {
        if (fill) |paint| {
            panel_chrome.drawPaintRoundedRect(dc, rect, radius, paint);
        }
        text_color = t.colors.text_secondary;
    }
    if (border_color[3] > 0.001) {
        dc.drawRoundedRect(rect, radius, .{ .fill = null, .stroke = border_color, .thickness = 1.0 });
    }

    const line_height = dc.lineHeight();
    const text_y = rect.min[1] + (rect.size()[1] - line_height) * 0.5;
    const box_size = @min(rect.size()[1], line_height) * 0.9;
    const box_min = .{
        rect.min[0] + t.spacing.sm,
        rect.min[1] + (rect.size()[1] - box_size) * 0.5,
    };
    const box_rect = draw_context.Rect{
        .min = box_min,
        .max = .{ box_min[0] + box_size, box_min[1] + box_size },
    };
    const unchecked_fill = cs.fill orelse style_sheet.Paint{ .solid = t.colors.surface };
    const checked_fill = cs.fill_checked orelse style_sheet.Paint{ .solid = t.colors.primary };
    const box_fill = if (selected) checked_fill else unchecked_fill;
    var box_border = cs.border orelse t.colors.border;
    if (selected) {
        box_border = cs.border_checked orelse box_border;
    }
    const box_radius = cs.radius orelse t.radius.sm;
    panel_chrome.drawPaintRoundedRect(dc, box_rect, box_radius, box_fill);
    dc.drawRoundedRect(box_rect, box_radius, .{ .fill = null, .stroke = box_border, .thickness = 1.0 });
    if (selected) {
        const inset = box_size * 0.2;
        const x0 = box_rect.min[0] + inset;
        const y0 = box_rect.min[1] + box_size * 0.55;
        const x1 = box_rect.min[0] + box_size * 0.45;
        const y1 = box_rect.min[1] + box_size * 0.75;
        const x2 = box_rect.min[0] + box_size * 0.8;
        const y2 = box_rect.min[1] + box_size * 0.3;
        const thickness = @max(1.5, box_size * 0.12);
        const check_color = cs.check orelse colors.rgba(255, 255, 255, 255);
        dc.drawLine(.{ x0, y0 }, .{ x1, y1 }, thickness, check_color);
        dc.drawLine(.{ x1, y1 }, .{ x2, y2 }, thickness, check_color);
    }

    const label_x = box_rect.max[0] + t.spacing.xs;
    dc.drawText(label, .{ label_x, text_y }, .{ .color = text_color });

    var clicked = false;
    if (!disabled) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_up => |mu| {
                    if (mu.button == .left and rect.contains(mu.pos)) {
                        if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) {
                            clicked = true;
                        }
                    }
                },
                else => {},
            }
        }
        if (!clicked and nav_active and focused) {
            clicked = nav_router.wasActivated(queue, nav_id);
        }
    }
    return clicked;
}

const PanelIdList = struct {
    items: [4]workspace.PanelId = undefined,
    len: usize = 0,

    pub fn append(self: *PanelIdList, id: workspace.PanelId) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = id;
        self.len += 1;
    }

    pub fn slice(self: *const PanelIdList) []const workspace.PanelId {
        return self.items[0..self.len];
    }
};

var safe_insets: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
var default_window_ui_state: WindowUiState = .{};
var installer_profile_only_mode: bool = false;
const attachment_fetch_limit: usize = 256 * 1024;
const attachment_editor_limit: usize = 128 * 1024;
const attachment_json_pretty_limit: usize = 64 * 1024;

const PendingAttachment = struct {
    panel_id: workspace.PanelId,
    name: []u8,
    kind: []u8,
    url: []u8,
    role: []u8,
    timestamp: i64,
};

var pending_attachment_fetches: std.ArrayList(PendingAttachment) = .empty;

pub fn setSafeInsets(left: f32, top: f32, right: f32, bottom: f32) void {
    safe_insets = .{ left, top, right, bottom };
}

pub fn setInstallerProfileOnlyMode(enabled: bool) void {
    installer_profile_only_mode = enabled;
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    framebuffer_width: u32,
    framebuffer_height: u32,
    use_wgpu_renderer: bool,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
) UiAction {
    _ = use_wgpu_renderer;
    const zone = profiler.zone(@src(), "ui.draw");
    defer zone.end();
    frameBegin(allocator, ctx, manager, inbox);
    defer frameEnd();
    const queue = collectInput(allocator);
    return drawWindow(allocator, ctx, cfg, registry, is_connected, app_version, framebuffer_width, framebuffer_height, manager, inbox, queue, &default_window_ui_state);
}

pub fn frameBegin(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
) void {
    image_cache.beginFrame();
    _ = ui_systems.beginFrame();
    text_input_backend.beginFrame();

    var session_it = ctx.session_states.iterator();
    while (session_it.next()) |entry| {
        inbox.collectFromMessages(allocator, entry.key_ptr.*, entry.value_ptr.messages.items, manager);
    }
}

pub fn frameEnd() void {
    text_input_backend.endFrame();
}

pub fn collectInput(allocator: std.mem.Allocator) *input_state.InputQueue {
    _ = input_router.beginFrame(allocator);
    input_router.collect(allocator);
    return input_router.getQueue();
}

pub fn drawWindow(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    framebuffer_width: u32,
    framebuffer_height: u32,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    queue: *input_state.InputQueue,
    win_state: *WindowUiState,
) UiAction {
    var action = UiAction{};
    const zone = profiler.zone(@src(), "ui.draw_window");
    defer zone.end();
    var pending_attachment: ?sessions_panel.AttachmentOpen = null;

    const t = theme.activeTheme();

    const display_w = @as(f32, @floatFromInt(framebuffer_width));
    const display_h = @as(f32, @floatFromInt(framebuffer_height));
    if (display_w > 0.0 and display_h > 0.0) {
        const left = safe_insets[0];
        const top = safe_insets[1];
        const right = safe_insets[2];
        const bottom = safe_insets[3];
        const width = @max(1.0, display_w - left - right);
        const extra_bottom: f32 = if (builtin.abi.isAndroid()) 24.0 else 0.0;
        const height = @max(1.0, display_h - top - bottom - extra_bottom);
        const host_rect = draw_context.Rect.fromMinSize(.{ left, top }, .{ width, height });

        nav_router.set(&win_state.nav);
        defer nav_router.set(null);
        win_state.nav.beginFrame(allocator, host_rect, queue);
        defer win_state.nav.endFrame(allocator);

        drawWorkspaceHost(
            allocator,
            ctx,
            cfg,
            registry,
            is_connected,
            app_version,
            manager,
            inbox,
            queue,
            t,
            host_rect,
            &action,
            &pending_attachment,
            win_state,
        );
    }

    if (manager.workspace.dirty) action.save_workspace = true;

    // Clear any pointer capture on mouse-up/focus-lost even if the release happened
    // outside widgets (important when spawning new windows during a click).
    input_state.endFrame(queue);

    return action;
}

fn drawWorkspaceHost(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    queue: *input_state.InputQueue,
    t: *const theme.Theme,
    host_rect: draw_context.Rect,
    action: *UiAction,
    pending_attachment: *?sessions_panel.AttachmentOpen,
    win_state: *WindowUiState,
) void {
    const zone = profiler.zone(@src(), "ui.workspace");
    defer zone.end();
    _ = command_queue.beginFrame(allocator);
    defer command_queue.endFrame();

    cursor.set(.arrow);
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, host_rect);
    defer dc.deinit();

    surface_chrome.drawBackground(&dc, host_rect);

    if (installer_profile_only_mode) {
        win_state.last_dock_content_rect = .{
            .min = .{ 0.0, 0.0 },
            .max = .{ 0.0, 0.0 },
        };
        ensureOnlyPanelKind(manager, .Control);
        if (selectPanelForKind(manager, .Control)) |panel| {
            panel.data.Control.active_tab = .Settings;
            const inset = t.spacing.md;
            const content_rect = draw_context.Rect.fromMinSize(
                .{ host_rect.min[0] + inset, host_rect.min[1] + inset },
                .{
                    @max(1.0, host_rect.size()[0] - inset * 2.0),
                    @max(1.0, host_rect.size()[1] - inset * 2.0),
                },
            );
            _ = drawPanelContents(
                allocator,
                ctx,
                cfg,
                registry,
                is_connected,
                app_version,
                panel,
                content_rect,
                inbox,
                manager,
                action,
                pending_attachment,
                win_state,
                true,
            );
        }
        drawControllerFocusOverlay(&dc, queue, host_rect);
        ui_systems.endFrame(&dc);
        return;
    }

    if (theme_runtime.getProfile().id == .fullscreen) {
        win_state.last_dock_content_rect = .{
            .min = .{ 0.0, 0.0 },
            .max = .{ 0.0, 0.0 },
        };
        drawFullscreenHost(
            allocator,
            ctx,
            cfg,
            registry,
            is_connected,
            app_version,
            manager,
            inbox,
            queue,
            &dc,
            host_rect,
            action,
            pending_attachment,
            win_state,
        );
        ui_systems.endFrame(&dc);
        return;
    }

    if (win_state.theme_layout_presets_enabled) {
        applyThemeWorkspaceLayoutPreset(manager, win_state);
    }
    if (manager.workspace.syncDockLayout() catch false) {
        manager.workspace.markDirty();
    }

    const line_height = dc.lineHeight();
    const menu_height = if (win_state.show_menu_bar) customMenuHeight(line_height, t) else 0.0;
    const status_height = if (win_state.show_status_bar) statusBarHeight(line_height, t) else 0.0;
    const menu_rect = draw_context.Rect.fromMinSize(host_rect.min, .{ host_rect.size()[0], menu_height });

    const status_rect = draw_context.Rect.fromMinSize(
        .{ host_rect.min[0], host_rect.max[1] - status_height },
        .{ host_rect.size()[0], status_height },
    );

    const content_height = @max(0.0, host_rect.size()[1] - menu_height - status_height);
    const content_rect = draw_context.Rect.fromMinSize(
        .{ host_rect.min[0], menu_rect.max[1] },
        .{ host_rect.size()[0], content_height },
    );

    win_state.collapsed_docks.prune(&manager.workspace.dock_layout);
    if (win_state.dock_flyout.node_id) |node_id| {
        if (!win_state.collapsed_docks.isCollapsed(node_id)) {
            win_state.dock_flyout.clear();
        }
    }

    const rail_button_extent = @max(20.0, line_height + t.spacing.xs * 2.0);
    const rail_strip_width = rail_button_extent + t.spacing.xs * 2.0;
    const target_left_rail_width: f32 = if (win_state.collapsed_docks.countForSide(.left) > 0) rail_strip_width else 0.0;
    const target_right_rail_width: f32 = if (win_state.collapsed_docks.countForSide(.right) > 0) rail_strip_width else 0.0;
    win_state.dock_rail_anim.update(target_left_rail_width, target_right_rail_width, ui_systems.frameDtSeconds());
    const left_rail_width = win_state.dock_rail_anim.left_width;
    const right_rail_width = win_state.dock_rail_anim.right_width;
    const dock_content_rect = draw_context.Rect.fromMinSize(
        .{ content_rect.min[0] + left_rail_width, content_rect.min[1] },
        .{ @max(0.0, content_rect.size()[0] - left_rail_width - right_rail_width), content_rect.size()[1] },
    );
    win_state.last_dock_content_rect = dock_content_rect;

    const keyboard_result = handleDockKeyboardShortcuts(queue, manager, dock_content_rect, win_state);
    if (keyboard_result.changed_layout) {
        manager.workspace.markDirty();
    }

    var layout_graph_storage = dock_graph.Graph.init(allocator);
    var using_layout_graph_storage = false;
    defer if (using_layout_graph_storage) layout_graph_storage.deinit();

    var layout_graph: *const dock_graph.Graph = &manager.workspace.dock_layout;
    if (win_state.collapsed_docks.len > 0) {
        if (layout_graph_storage.cloneFrom(&manager.workspace.dock_layout)) |_| {
            using_layout_graph_storage = true;
            for (win_state.collapsed_docks.items[0..win_state.collapsed_docks.len]) |item| {
                const node = manager.workspace.dock_layout.getNode(item.node_id) orelse continue;
                const tabs = switch (node.*) {
                    .tabs => |tabs_node| tabs_node,
                    .split => continue,
                };
                for (tabs.tabs.items) |panel_id| {
                    _ = layout_graph_storage.removePanel(panel_id);
                }
            }
            layout_graph = &layout_graph_storage;
        } else |_| {}
    }

    const layout_result = layout_graph.computeLayout(dock_content_rect);
    const splitters = layout_graph.computeSplitters(dock_content_rect);
    const split_changed = handleDockSplitInteractions(queue, manager, win_state, &splitters);
    if (split_changed) {
        manager.workspace.markDirty();
    }
    drawDockSplitters(&dc, queue, win_state, &splitters);

    var focus_panel_id: ?workspace.PanelId = null;
    if (keyboard_result.focus_panel_id) |pid| {
        focus_panel_id = pid;
    }
    var close_panel_id: ?workspace.PanelId = null;
    var active_session_key: ?[]const u8 = null;
    var active_agent_id: ?[]const u8 = null;
    var tab_hits = DockTabHitList{};
    var drop_targets = DockDropTargetList{};
    const flyout_rect_opt = activeDockFlyoutRect(&dc, manager, win_state, content_rect, left_rail_width, right_rail_width);
    var block_under_flyout = false;
    if (flyout_rect_opt) |fly_rect| {
        if (fly_rect.contains(queue.state.mouse_pos)) {
            block_under_flyout = true;
        } else {
            for (queue.events.items) |evt| {
                switch (evt) {
                    .mouse_down => |md| {
                        if (md.button == .left and fly_rect.contains(md.pos)) {
                            block_under_flyout = true;
                        }
                    },
                    .mouse_up => |mu| {
                        if (mu.button == .left and fly_rect.contains(mu.pos)) {
                            block_under_flyout = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    for (layout_result.slice()) |group| {
        const node = layout_graph.getNode(group.node_id) orelse continue;
        const tabs_node = switch (node.*) {
            .tabs => |tabs| tabs,
            .split => continue,
        };
        if (tabs_node.tabs.items.len == 0) continue;

        const active_index = @min(tabs_node.active, tabs_node.tabs.items.len - 1);
        const active_panel_id = tabs_node.tabs.items[active_index];
        const panel = findPanelById(manager, active_panel_id) orelse continue;

        nav_router.pushScope(panel.id);
        defer nav_router.popScope();

        const focused = if (manager.workspace.focused_panel_id) |id| id == panel.id else false;
        panel.state.is_focused = focused;
        const collapse_side = dock_rail.collapsibleSideForRect(dock_content_rect, group.rect);

        const frame = drawDockGroupFrame(
            &dc,
            group.rect,
            queue,
            manager,
            win_state,
            block_under_flyout,
            group.node_id,
            tabs_node.tabs.items,
            active_index,
            focused,
            collapse_side,
            &tab_hits,
            &drop_targets,
        );
        if (frame.collapse_clicked) {
            if (collapse_side) |side| {
                win_state.collapsed_docks.collapse(group.node_id, side);
            }
            continue;
        }
        if (frame.frame_clicked) {
            focus_panel_id = panel.id;
        }
        if (frame.close_panel_id) |pid| {
            close_panel_id = pid;
        }
        if (frame.detach_panel_id) |pid| {
            if (action.detach_panel == null) {
                if (manager.takePanel(pid)) |moved| {
                    if (allocator.create(workspace.Panel)) |pp| {
                        pp.* = moved;
                        action.detach_panel = pp;
                    } else |_| {
                        _ = manager.putPanel(moved) catch {};
                    }
                }
            }
            continue;
        }

        const draw_result = drawPanelContents(
            allocator,
            ctx,
            cfg,
            registry,
            is_connected,
            app_version,
            panel,
            frame.content_rect,
            inbox,
            manager,
            action,
            pending_attachment,
            win_state,
            installer_profile_only_mode,
        );
        if (panel.kind == .Chat and draw_result.session_key != null) {
            if (focused) {
                active_session_key = draw_result.session_key;
                active_agent_id = draw_result.agent_id;
            }
        }
    }

    const drag_result = handleDockTabInteractions(queue, manager, win_state, &tab_hits, &drop_targets, dock_content_rect);
    if (drag_result.changed_layout) {
        manager.workspace.markDirty();
    }
    if (drag_result.focus_panel_id) |pid| {
        focus_panel_id = pid;
    }
    if (drag_result.detach_panel_id) |pid| {
        if (action.detach_panel == null) {
            if (manager.takePanel(pid)) |moved| {
                if (allocator.create(workspace.Panel)) |pp| {
                    pp.* = moved;
                    action.detach_panel = pp;
                    action.detach_panel_id = pid;
                } else |_| {
                    _ = manager.putPanel(moved) catch {};
                }
            }
        }
    }
    drawDockDragOverlay(&dc, queue, manager, win_state, &drop_targets, dock_content_rect);

    const rail_result = drawCollapsedDockRails(&dc, queue, manager, win_state, content_rect, left_rail_width, right_rail_width);
    if (rail_result.focus_panel_id) |pid| {
        focus_panel_id = pid;
    }
    if (rail_result.clicked_item) |item| {
        if (win_state.dock_flyout.node_id != null and win_state.dock_flyout.node_id.? == item.node_id and win_state.dock_flyout.pinned) {
            win_state.dock_flyout.clear();
        } else {
            win_state.dock_flyout.node_id = item.node_id;
            win_state.dock_flyout.side = item.side;
            win_state.dock_flyout.pinned = true;
        }
    } else if (!win_state.dock_flyout.pinned) {
        if (rail_result.hovered_item) |item| {
            win_state.dock_flyout.node_id = item.node_id;
            win_state.dock_flyout.side = item.side;
        }
    }

    const flyout_result = drawCollapsedDockFlyout(
        allocator,
        ctx,
        cfg,
        registry,
        is_connected,
        app_version,
        manager,
        inbox,
        queue,
        &dc,
        action,
        pending_attachment,
        win_state,
        content_rect,
        left_rail_width,
        right_rail_width,
    );
    if (flyout_result.changed_layout) {
        manager.workspace.markDirty();
    }
    if (flyout_result.focus_panel_id) |pid| {
        focus_panel_id = pid;
    }
    if (flyout_result.expand_node_id) |node_id| {
        _ = win_state.collapsed_docks.expand(node_id);
        win_state.dock_flyout.clear();
    }
    if (flyout_result.session_key != null) {
        active_session_key = flyout_result.session_key;
        active_agent_id = flyout_result.agent_id;
    }

    if (close_panel_id) |panel_id| {
        _ = manager.closePanel(panel_id);
    }
    if (focus_panel_id) |panel_id| {
        manager.focusPanel(panel_id);
    }

    if (pending_attachment.*) |attachment| {
        openAttachmentInEditor(allocator, manager, attachment);
        pending_attachment.* = null;
    }
    syncAttachmentFetches(allocator, manager);

    if (win_state.show_menu_bar) {
        drawCustomMenuBar(&dc, menu_rect, queue, manager, cfg, action, win_state);
    }

    var total_chat_panels: usize = 0;
    var unique_agent_ids: [32][]const u8 = undefined;
    var unique_agent_count: usize = 0;
    var counted_session_keys: [64][]const u8 = undefined;
    var counted_session_count: usize = 0;
    var lone_session_key: ?[]const u8 = null;
    var lone_agent_id: ?[]const u8 = null;
    var total_messages_across_chats: usize = 0;

    for (manager.workspace.panels.items) |panel| {
        if (panel.kind != .Chat) continue;
        total_chat_panels += 1;

        const panel_agent_id = if (panel.data.Chat.agent_id) |id|
            id
        else if (panel.data.Chat.session_key) |session_key|
            if (session_keys.parse(session_key)) |parts| parts.agent_id else "main"
        else
            "main";
        appendUniqueSlice(unique_agent_ids[0..], &unique_agent_count, panel_agent_id);

        if (panel.data.Chat.session_key) |session_key| {
            if (lone_session_key == null) {
                lone_session_key = session_key;
                lone_agent_id = panel_agent_id;
            } else if (!std.mem.eql(u8, lone_session_key.?, session_key)) {
                lone_session_key = null;
                lone_agent_id = null;
            }

            if (!containsSlice(counted_session_keys[0..counted_session_count], session_key)) {
                appendUniqueSlice(counted_session_keys[0..], &counted_session_count, session_key);
                if (ctx.findSessionState(session_key)) |session_state| {
                    total_messages_across_chats += session_state.messages.items.len;
                }
            }
        } else {
            lone_session_key = null;
            lone_agent_id = null;
        }
    }

    var agent_name: ?[]const u8 = null;
    var session_label: ?[]const u8 = null;
    var session_label_buf: [96]u8 = undefined;
    var aggregate_label_buf: [64]u8 = undefined;
    var message_count: usize = 0;
    if (active_session_key) |session_key| {
        session_label = resolveSessionLabel(ctx.sessions.items, session_key, &session_label_buf);
        if (ctx.findSessionState(session_key)) |session_state| {
            message_count = session_state.messages.items.len;
        }
        const info = resolveAgentInfo(registry, active_agent_id);
        agent_name = info.name;
    } else if (total_chat_panels == 1 and lone_session_key != null) {
        session_label = resolveSessionLabel(ctx.sessions.items, lone_session_key.?, &session_label_buf);
        if (ctx.findSessionState(lone_session_key.?)) |session_state| {
            message_count = session_state.messages.items.len;
        }
        const info = resolveAgentInfo(registry, lone_agent_id);
        agent_name = info.name;
    } else if (total_chat_panels > 1) {
        agent_name = if (unique_agent_count > 1) "Multiple" else if (unique_agent_count == 1) resolveAgentInfo(registry, unique_agent_ids[0]).name else "Multiple";
        session_label = std.fmt.bufPrint(&aggregate_label_buf, "{d} chats open", .{total_chat_panels}) catch "Multiple chats";
        message_count = total_messages_across_chats;
    }

    if (win_state.show_status_bar) {
        status_bar.drawCustom(
            &dc,
            status_rect,
            ctx.state,
            is_connected,
            agent_name,
            session_label,
            message_count,
            ctx.gateway_compatibility,
            ctx.last_error,
        );
    }

    drawControllerFocusOverlay(&dc, queue, host_rect);

    ui_systems.endFrame(&dc);
}

fn applyThemeWorkspaceLayoutPreset(manager: *panel_manager.PanelManager, win_state: *WindowUiState) void {
    const pid = theme_runtime.getProfile().id;
    const idx: usize = switch (pid) {
        .desktop => 0,
        .phone => 1,
        .tablet => 2,
        .fullscreen => 3,
    };
    if (win_state.theme_layout_applied[idx]) return;
    win_state.theme_layout_applied[idx] = true;

    const preset = theme_runtime.getWorkspaceLayout(pid) orelse return;
    const open_panels = preset.openPanels();
    if (open_panels.len == 0) return;

    for (open_panels) |kind| {
        manager.ensurePanel(kind);
    }

    if (preset.close_others) {
        var i: usize = 0;
        while (i < manager.workspace.panels.items.len) {
            const p = manager.workspace.panels.items[i];
            var wanted = false;
            for (open_panels) |k| {
                if (k == p.kind) {
                    wanted = true;
                    break;
                }
            }
            if (wanted) {
                i += 1;
                continue;
            }
            _ = manager.closePanel(p.id);
            // closePanel compacts the list; don't increment.
        }
    }

    // Apply custom layout sizing only if the user hasn't adjusted it yet (heuristic).
    if (preset.custom_layout_left_ratio != null or preset.custom_layout_min_left_width != null or preset.custom_layout_min_right_width != null) {
        const eps: f32 = 0.0005;
        const def = workspace.CustomLayoutState{};
        const cur = manager.workspace.custom_layout;
        const untouched = (@abs(cur.left_ratio - def.left_ratio) <= eps) and
            (@abs(cur.min_left_width - def.min_left_width) <= eps) and
            (@abs(cur.min_right_width - def.min_right_width) <= eps);
        if (untouched) {
            if (preset.custom_layout_left_ratio) |v| manager.workspace.custom_layout.left_ratio = v;
            if (preset.custom_layout_min_left_width) |v| manager.workspace.custom_layout.min_left_width = v;
            if (preset.custom_layout_min_right_width) |v| manager.workspace.custom_layout.min_right_width = v;
            manager.workspace.markDirty();
        }
    }

    if (preset.focused) |focus_kind| {
        for (manager.workspace.panels.items) |panel| {
            if (panel.kind == focus_kind) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }
}

fn drawControllerFocusOverlay(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    host_rect: draw_context.Rect,
) void {
    const nav_state = nav_router.get() orelse return;
    if (!nav_state.isActive()) return;

    // Find the rect that contains the virtual cursor. This is approximate but fast and
    // works well because the cursor is pinned to the focused item's center.
    const pos = queue.state.mouse_pos;
    const items = nav_state.prev_items.items;
    for (items) |it| {
        if (!it.rect.contains(pos)) continue;
        if (!host_rect.contains(it.center())) continue;
        const h = it.rect.size()[1];
        const approx_radius = std.math.clamp(h * 0.25, dc.theme.radius.sm, dc.theme.radius.lg);
        widgets.focus_ring.draw(dc, it.rect, approx_radius);
        break;
    }
}

fn ensureOnlyPanelKind(manager: *panel_manager.PanelManager, kind: workspace.PanelKind) void {
    // Open the requested one, close everything else.
    manager.ensurePanel(kind);
    var idx: usize = 0;
    while (idx < manager.workspace.panels.items.len) {
        const panel = manager.workspace.panels.items[idx];
        if (panel.kind == kind) {
            idx += 1;
            continue;
        }
        _ = manager.closePanel(panel.id);
        // closePanel compacts the list.
    }

    // Ensure focus follows.
    for (manager.workspace.panels.items) |p| {
        if (p.kind == kind) {
            manager.focusPanel(p.id);
            break;
        }
    }
}

fn drawFullscreenHost(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    queue: *input_state.InputQueue,
    dc: *draw_context.DrawContext,
    host_rect: draw_context.Rect,
    action: *UiAction,
    pending_attachment: *?sessions_panel.AttachmentOpen,
    win_state: *WindowUiState,
) void {
    const t = dc.theme;

    // Controller "back" returns to the home cards.
    if (win_state.nav.actions.back and win_state.fullscreen_page != .home) {
        win_state.fullscreen_page = .home;
    }

    const line_h = dc.lineHeight();
    const header_h = line_h + t.spacing.md * 2.0;
    const status_h = statusBarHeight(line_h, t);
    const header_rect = draw_context.Rect.fromMinSize(host_rect.min, .{ host_rect.size()[0], header_h });
    const status_rect = draw_context.Rect.fromMinSize(
        .{ host_rect.min[0], host_rect.max[1] - status_h },
        .{ host_rect.size()[0], status_h },
    );
    const content_h = @max(1.0, host_rect.size()[1] - header_h - status_h);
    const content_rect = draw_context.Rect.fromMinSize(.{ host_rect.min[0], header_rect.max[1] }, .{ host_rect.size()[0], content_h });
    const hints_h = line_h + t.spacing.sm * 2.0;
    const content_main_rect = if (content_rect.size()[1] > hints_h + t.spacing.sm)
        draw_context.Rect.fromMinSize(content_rect.min, .{ content_rect.size()[0], content_rect.size()[1] - hints_h - t.spacing.sm })
    else
        content_rect;
    const hints_rect = if (content_rect.size()[1] > hints_h + t.spacing.sm)
        draw_context.Rect.fromMinSize(.{ content_rect.min[0], content_main_rect.max[1] + t.spacing.sm }, .{ content_rect.size()[0], hints_h })
    else
        draw_context.Rect.fromMinSize(.{ content_rect.min[0], content_rect.max[1] - hints_h }, .{ content_rect.size()[0], hints_h });

    // Header chrome (same material as menu bar).
    surface_chrome.drawMenuBar(dc, header_rect);
    dc.drawRect(header_rect, .{ .stroke = t.colors.border, .thickness = 1.0 });
    dc.drawText("ZiggyStarClaw", .{ header_rect.min[0] + t.spacing.lg, header_rect.min[1] + t.spacing.md }, .{ .color = t.colors.text_primary });

    if (win_state.fullscreen_page != .home) {
        const back_label = "Back";
        const back_w = dc.measureText(back_label, 0.0)[0] + t.spacing.lg * 2.0;
        const back_rect = draw_context.Rect.fromMinSize(
            .{ header_rect.max[0] - back_w - t.spacing.lg, header_rect.min[1] + t.spacing.sm },
            .{ back_w, header_rect.size()[1] - t.spacing.sm * 2.0 },
        );
        if (widgets.button.draw(dc, back_rect, back_label, queue, .{ .variant = .secondary })) {
            win_state.fullscreen_page = .home;
        }
    }

    // Main content.
    switch (win_state.fullscreen_page) {
        .home => {
            nav_router.pushScope(1);
            drawFullscreenHome(dc, content_main_rect, queue, win_state, manager);
            nav_router.popScope();
        },
        .agents => {
            nav_router.pushScope(2);
            ensureOnlyPanelKind(manager, .Agents);
            if (selectPanelForKind(manager, .Agents)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment, win_state, installer_profile_only_mode);
            }
            nav_router.popScope();
        },
        .settings => {
            nav_router.pushScope(3);
            ensureOnlyPanelKind(manager, .Settings);
            if (selectPanelForKind(manager, .Settings)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment, win_state, installer_profile_only_mode);
            }
            nav_router.popScope();
        },
        .chat => {
            nav_router.pushScope(4);
            ensureOnlyPanelKind(manager, .Chat);
            if (selectPanelForKind(manager, .Chat)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment, win_state, installer_profile_only_mode);
            }
            nav_router.popScope();
        },
        .showcase => {
            nav_router.pushScope(5);
            ensureOnlyPanelKind(manager, .Showcase);
            if (selectPanelForKind(manager, .Showcase)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment, win_state, installer_profile_only_mode);
            }
            nav_router.popScope();
        },
        .workboard => {
            nav_router.pushScope(6);
            ensureOnlyPanelKind(manager, .Workboard);
            if (selectPanelForKind(manager, .Workboard)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment, win_state, installer_profile_only_mode);
            }
            nav_router.popScope();
        },
    }

    drawControllerHints(dc, hints_rect, win_state.fullscreen_page != .home);
    drawControllerFocusOverlay(dc, queue, host_rect);

    status_bar.drawCustom(
        dc,
        status_rect,
        ctx.state,
        is_connected,
        null,
        null,
        0,
        ctx.gateway_compatibility,
        ctx.last_error,
    );
}

fn drawControllerHints(dc: *draw_context.DrawContext, rect: draw_context.Rect, show_back: bool) void {
    const t = dc.theme;
    dc.drawRoundedRect(rect, t.radius.md, .{
        .fill = colors.withAlpha(t.colors.surface, 0.55),
        .stroke = colors.withAlpha(t.colors.border, 0.7),
        .thickness = 1.0,
    });

    const gap = t.spacing.sm;
    const pad_x = t.spacing.md;
    const pill_h = rect.size()[1] - t.spacing.xs * 2.0;
    var cursor_x = rect.min[0] + pad_x;
    const y = rect.min[1] + t.spacing.xs;

    cursor_x = drawHintPill(dc, .{ cursor_x, y }, pill_h, "A Select");
    cursor_x += gap;
    if (show_back) {
        cursor_x = drawHintPill(dc, .{ cursor_x, y }, pill_h, "B Back");
        cursor_x += gap;
    }
    cursor_x = drawHintPill(dc, .{ cursor_x, y }, pill_h, "LB/RB Tabs");
    cursor_x += gap;
    _ = drawHintPill(dc, .{ cursor_x, y }, pill_h, "LT/RT Scroll");
}

fn drawHintPill(dc: *draw_context.DrawContext, pos: [2]f32, h: f32, label: []const u8) f32 {
    const t = dc.theme;
    const text_sz = dc.measureText(label, 0.0);
    const w = text_sz[0] + t.spacing.md * 2.0;
    const r = draw_context.Rect.fromMinSize(pos, .{ w, h });
    dc.drawRoundedRect(r, t.radius.lg, .{
        .fill = colors.withAlpha(t.colors.background, 0.35),
        .stroke = colors.withAlpha(t.colors.border, 0.6),
        .thickness = 1.0,
    });
    dc.drawText(label, .{ r.min[0] + t.spacing.md, r.min[1] + (h - text_sz[1]) * 0.5 }, .{ .color = t.colors.text_secondary });
    return r.max[0];
}

fn drawFullscreenHome(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    win_state: *WindowUiState,
    manager: *panel_manager.PanelManager,
) void {
    _ = manager;
    const t = dc.theme;
    const gap = t.spacing.lg;
    const cols: usize = 3;
    const cards = [_]struct { label: []const u8, page: FullscreenPage }{
        .{ .label = "Agents", .page = .agents },
        .{ .label = "Settings", .page = .settings },
        .{ .label = "Chat", .page = .chat },
        .{ .label = "Workboard", .page = .workboard },
        .{ .label = "Showcase", .page = .showcase },
    };
    const rows: usize = (cards.len + cols - 1) / cols;
    const card_w = @max(1.0, (rect.size()[0] - gap * (@as(f32, @floatFromInt(cols - 1)))) / @as(f32, @floatFromInt(cols)));
    const card_h = @max(1.0, (rect.size()[1] - gap * (@as(f32, @floatFromInt(rows - 1)))) / @as(f32, @floatFromInt(rows)));

    const start_x = rect.min[0] + (rect.size()[0] - (card_w * @as(f32, @floatFromInt(cols)) + gap * @as(f32, @floatFromInt(cols - 1)))) * 0.5;
    const start_y = rect.min[1] + (rect.size()[1] - (card_h * @as(f32, @floatFromInt(rows)) + gap * @as(f32, @floatFromInt(rows - 1)))) * 0.5;

    for (cards, 0..) |card, idx| {
        const col: f32 = @floatFromInt(idx % cols);
        const row: f32 = @floatFromInt(idx / cols);
        const card_rect = draw_context.Rect.fromMinSize(
            .{ start_x + col * (card_w + gap), start_y + row * (card_h + gap) },
            .{ card_w, card_h },
        );
        if (widgets.button.draw(dc, card_rect, card.label, queue, .{ .variant = .primary, .radius = t.radius.lg })) {
            win_state.fullscreen_page = card.page;
        }
    }
}

fn drawPanelContents(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    panel: *workspace.Panel,
    panel_rect: ?draw_context.Rect,
    inbox: *ui_command_inbox.UiCommandInbox,
    manager: *panel_manager.PanelManager,
    action: *UiAction,
    pending_attachment: *?sessions_panel.AttachmentOpen,
    win_state: *WindowUiState,
    install_profile_only_mode: bool,
) PanelDrawResult {
    var result: PanelDrawResult = .{};
    const zone = profiler.zone(@src(), "ui.panel");
    defer zone.end();
    switch (panel.kind) {
        .Chat => {
            var agent_id = panel.data.Chat.agent_id;
            if (agent_id == null) {
                if (panel.data.Chat.session_key) |session_key| {
                    if (session_keys.parse(session_key)) |parts| {
                        panel.data.Chat.agent_id = allocator.dupe(u8, parts.agent_id) catch panel.data.Chat.agent_id;
                        agent_id = panel.data.Chat.agent_id;
                        manager.workspace.markDirty();
                    }
                }
            }

            var resolved_session_key = panel.data.Chat.session_key;
            if (resolved_session_key == null and agent_id != null) {
                if (registry.find(agent_id.?)) |agent| {
                    if (agent.default_session_key) |default_key| {
                        resolved_session_key = default_key;
                    }
                }
            }
            if (resolved_session_key == null) {
                if (ctx.current_session) |current| {
                    resolved_session_key = current;
                    if (panel.data.Chat.session_key == null) {
                        panel.data.Chat.session_key = allocator.dupe(u8, current) catch panel.data.Chat.session_key;
                        manager.workspace.markDirty();
                    }
                    if (agent_id == null) {
                        if (session_keys.parse(current)) |parts| {
                            panel.data.Chat.agent_id = allocator.dupe(u8, parts.agent_id) catch panel.data.Chat.agent_id;
                            agent_id = panel.data.Chat.agent_id;
                            manager.workspace.markDirty();
                        }
                    }
                }
            }

            const agent_info = resolveAgentInfo(registry, agent_id);
            if (!std.mem.eql(u8, panel.title, agent_info.name)) {
                if (allocator.dupe(u8, agent_info.name)) |new_title| {
                    allocator.free(panel.title);
                    panel.title = new_title;
                    manager.workspace.markDirty();
                } else |_| {}
            }

            const session_state = if (resolved_session_key) |session_key|
                ctx.getOrCreateSessionState(session_key) catch null
            else
                null;

            const chat_action = chat_panel.draw(
                allocator,
                &panel.data.Chat,
                agent_id orelse "main",
                resolved_session_key,
                session_state,
                agent_info.icon,
                agent_info.name,
                ctx.sessions.items,
                inbox,
                ctx.approvals.items.len,
                panel_rect,
            );
            if (chat_action.send_message) |message| {
                if (resolved_session_key) |session_key| {
                    const key_copy = allocator.dupe(u8, session_key) catch null;
                    if (key_copy) |owned| {
                        action.send_message = .{ .session_key = owned, .message = message };
                    } else {
                        allocator.free(message);
                    }
                } else {
                    allocator.free(message);
                }
            }
            replaceOwnedSlice(allocator, &action.select_session, chat_action.select_session);
            setOwnedSlice(allocator, &action.select_session_id, chat_action.select_session_id);
            replaceOwnedSlice(allocator, &action.new_chat_session_key, chat_action.new_chat_session_key);

            if (chat_action.open_activity_panel) {
                manager.ensurePanel(.Inbox);
            }
            if (chat_action.open_approvals_panel) {
                manager.ensurePanel(.ApprovalsInbox);
            }

            result.session_key = resolved_session_key;
            result.agent_id = agent_id;
        },
        .CodeEditor => {
            if (code_editor_panel.draw(panel, allocator, panel_rect)) {
                manager.workspace.markDirty();
            }
        },
        .ToolOutput => {
            tool_output_panel.draw(panel, allocator, panel_rect);
        },
        .Control => {
            const control_action = control_panel.draw(
                allocator,
                ctx,
                cfg,
                registry,
                is_connected,
                app_version,
                &panel.data.Control,
                panel_rect,
                win_state.theme_pack_override,
                install_profile_only_mode,
            );
            action.refresh_sessions = action.refresh_sessions or control_action.refresh_sessions;
            action.new_session = action.new_session or control_action.new_session;
            action.connect = action.connect or control_action.connect;
            action.disconnect = action.disconnect or control_action.disconnect;
            action.save_config = action.save_config or control_action.save_config;
            action.reload_theme_pack = action.reload_theme_pack or control_action.reload_theme_pack;
            action.browse_theme_pack = action.browse_theme_pack or control_action.browse_theme_pack;
            action.browse_theme_pack_override = action.browse_theme_pack_override or control_action.browse_theme_pack_override;
            action.clear_theme_pack_override = action.clear_theme_pack_override or control_action.clear_theme_pack_override;
            action.reload_theme_pack_override = action.reload_theme_pack_override or control_action.reload_theme_pack_override;
            action.clear_saved = action.clear_saved or control_action.clear_saved;
            action.config_updated = action.config_updated or control_action.config_updated;
            action.check_updates = action.check_updates or control_action.check_updates;
            action.open_release = action.open_release or control_action.open_release;
            action.download_update = action.download_update or control_action.download_update;
            action.open_download = action.open_download or control_action.open_download;
            action.install_update = action.install_update or control_action.install_update;

            action.node_profile_apply_client = action.node_profile_apply_client or control_action.node_profile_apply_client;
            action.node_profile_apply_service = action.node_profile_apply_service or control_action.node_profile_apply_service;
            action.node_profile_apply_session = action.node_profile_apply_session or control_action.node_profile_apply_session;
            action.node_service_install_onlogon = action.node_service_install_onlogon or control_action.node_service_install_onlogon;
            action.node_service_start = action.node_service_start or control_action.node_service_start;
            action.node_service_stop = action.node_service_stop or control_action.node_service_stop;
            action.node_service_status = action.node_service_status or control_action.node_service_status;
            action.node_service_uninstall = action.node_service_uninstall or control_action.node_service_uninstall;
            action.open_node_logs = action.open_node_logs or control_action.open_node_logs;
            action.refresh_nodes = action.refresh_nodes or control_action.refresh_nodes;
            action.clear_node_result = action.clear_node_result or control_action.clear_node_result;
            action.clear_operator_notice = action.clear_operator_notice or control_action.clear_operator_notice;

            if (control_action.new_chat_agent_id) |agent_id| {
                replaceOwnedSlice(allocator, &action.new_chat_agent_id, agent_id);
            }
            if (control_action.open_session) |open_session| {
                action.open_session = open_session;
            }
            if (control_action.set_default_session) |set_default| {
                action.set_default_session = set_default;
            }
            replaceOwnedSlice(allocator, &action.delete_session, control_action.delete_session);
            if (control_action.add_agent) |add_agent| {
                action.add_agent = add_agent;
            }
            replaceOwnedSlice(allocator, &action.remove_agent_id, control_action.remove_agent_id);
            replaceOwnedSlice(allocator, &action.select_node, control_action.select_node);
            if (control_action.invoke_node) |invoke| {
                action.invoke_node = invoke;
            }
            replaceOwnedSlice(allocator, &action.describe_node, control_action.describe_node);
            if (control_action.resolve_approval) |resolve| {
                action.resolve_approval = resolve;
            }
            replaceOwnedSlice(allocator, &action.clear_node_describe, control_action.clear_node_describe);
            if (control_action.open_attachment) |attachment| {
                pending_attachment.* = attachment;
            }
            replaceOwnedSlice(allocator, &action.select_session, control_action.select_session);
            if (control_action.select_session != null) {
                setOwnedSlice(allocator, &action.select_session_id, null);
            }
            replaceOwnedSlice(allocator, &action.open_url, control_action.open_url);
        },
        .Agents => {
            const agents_action = agents_panel.draw(
                allocator,
                ctx,
                registry,
                &panel.data.Agents,
                panel_rect,
            );
            action.refresh_sessions = action.refresh_sessions or agents_action.refresh;
            if (agents_action.new_chat_agent_id) |agent_id| {
                replaceOwnedSlice(allocator, &action.new_chat_agent_id, agent_id);
            }
            if (agents_action.open_session) |open_session| {
                action.open_session = open_session;
            }
            if (agents_action.set_default) |set_default| {
                action.set_default_session = set_default;
            }
            if (agents_action.delete_session) |session_key| {
                replaceOwnedSlice(allocator, &action.delete_session, session_key);
            }
            if (agents_action.add_agent) |add_agent| {
                action.add_agent = add_agent;
            }
            if (agents_action.remove_agent_id) |agent_id| {
                replaceOwnedSlice(allocator, &action.remove_agent_id, agent_id);
            }
            replaceAgentFileAction(allocator, &action.open_agent_file, agents_action.open_agent_file);
        },
        .Operator => {
            const op_action = operator_view.draw(allocator, ctx, is_connected, panel_rect);
            action.refresh_nodes = action.refresh_nodes or op_action.refresh_nodes;
            replaceOwnedSlice(allocator, &action.select_node, op_action.select_node);
            if (op_action.invoke_node) |invoke| {
                action.invoke_node = invoke;
            }
            replaceOwnedSlice(allocator, &action.describe_node, op_action.describe_node);
            if (op_action.resolve_approval) |resolve| {
                action.resolve_approval = resolve;
            }
            replaceOwnedSlice(allocator, &action.clear_node_describe, op_action.clear_node_describe);
            action.clear_node_result = action.clear_node_result or op_action.clear_node_result;
            action.clear_operator_notice = action.clear_operator_notice or op_action.clear_operator_notice;
        },
        .ApprovalsInbox => {
            const approvals_action = approvals_inbox_view.draw(allocator, ctx, panel_rect);
            if (approvals_action.resolve_approval) |resolve| {
                action.resolve_approval = resolve;
            }
        },
        .Inbox => {
            if (panel_rect) |content_rect| {
                const inbox_action = inbox_panel.draw(allocator, ctx, &panel.data.Inbox, content_rect);
                if (inbox_action.open_approvals_panel) {
                    manager.ensurePanel(.ApprovalsInbox);
                }
            }
        },
        .Workboard => {
            const wb_action = workboard_panel.draw(ctx, is_connected, panel_rect);
            action.refresh_workboard = action.refresh_workboard or wb_action.refresh;
        },
        .Settings => {
            const settings_action = settings_panel.draw(
                allocator,
                cfg,
                ctx.state,
                is_connected,
                &ctx.update_state,
                app_version,
                panel_rect,
                win_state.theme_pack_override,
                install_profile_only_mode,
            );
            action.connect = action.connect or settings_action.connect;
            action.disconnect = action.disconnect or settings_action.disconnect;
            action.save_config = action.save_config or settings_action.save;
            action.reload_theme_pack = action.reload_theme_pack or settings_action.reload_theme_pack;
            action.browse_theme_pack = action.browse_theme_pack or settings_action.browse_theme_pack;
            action.browse_theme_pack_override = action.browse_theme_pack_override or settings_action.browse_theme_pack_override;
            action.clear_theme_pack_override = action.clear_theme_pack_override or settings_action.clear_theme_pack_override;
            action.reload_theme_pack_override = action.reload_theme_pack_override or settings_action.reload_theme_pack_override;
            action.clear_saved = action.clear_saved or settings_action.clear_saved;
            action.config_updated = action.config_updated or settings_action.config_updated;
            action.check_updates = action.check_updates or settings_action.check_updates;
            action.open_release = action.open_release or settings_action.open_release;
            action.download_update = action.download_update or settings_action.download_update;
            action.open_download = action.open_download or settings_action.open_download;
            action.install_update = action.install_update or settings_action.install_update;
            action.node_service_install_onlogon = action.node_service_install_onlogon or settings_action.node_service_install_onlogon;
            action.node_service_start = action.node_service_start or settings_action.node_service_start;
            action.node_service_stop = action.node_service_stop or settings_action.node_service_stop;
            action.node_service_status = action.node_service_status or settings_action.node_service_status;
            action.node_service_uninstall = action.node_service_uninstall or settings_action.node_service_uninstall;
            action.open_node_logs = action.open_node_logs or settings_action.open_node_logs;
        },
        .Showcase => {
            const showcase_action = showcase_panel.draw(allocator, panel_rect);
            if (showcase_action.reload_effective_pack) {
                if (win_state.theme_pack_override != null) {
                    action.reload_theme_pack_override = true;
                } else {
                    action.reload_theme_pack = true;
                }
            }
            if (showcase_action.open_pack_root) {
                const root = theme_runtime.getThemePackRootPath() orelse "themes";
                const owned = allocator.dupe(u8, root) catch null;
                replaceOwnedSlice(allocator, &action.open_url, owned);
            }
        },
    }

    return result;
}

fn selectPanelForKind(
    manager: *panel_manager.PanelManager,
    kind: workspace.PanelKind,
) ?*workspace.Panel {
    if (manager.focus_request_id) |panel_id| {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.id == panel_id and panel.kind == kind) return panel;
        }
    }
    if (manager.workspace.focused_panel_id) |panel_id| {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.id == panel_id and panel.kind == kind) return panel;
        }
    }
    for (manager.workspace.panels.items) |*panel| {
        if (panel.kind == kind) return panel;
    }
    return null;
}

fn replaceOwnedSlice(allocator: std.mem.Allocator, target: *?[]u8, value: ?[]u8) void {
    if (value == null) return;
    if (target.*) |existing| {
        allocator.free(existing);
    }
    target.* = value;
}

fn setOwnedSlice(allocator: std.mem.Allocator, target: *?[]u8, value: ?[]u8) void {
    if (target.*) |existing| {
        allocator.free(existing);
    }
    target.* = value;
}

fn replaceAgentFileAction(
    allocator: std.mem.Allocator,
    target: *?@import("panels/agents_panel.zig").AgentFileOpenAction,
    value: ?@import("panels/agents_panel.zig").AgentFileOpenAction,
) void {
    if (value == null) return;
    if (target.*) |*existing| {
        existing.deinit(allocator);
    }
    target.* = value;
}

const AgentInfo = struct {
    name: []const u8,
    icon: []const u8,
};

fn resolveAgentInfo(registry: *agent_registry.AgentRegistry, agent_id: ?[]const u8) AgentInfo {
    if (agent_id) |id| {
        if (registry.find(id)) |agent| {
            return .{ .name = agent.display_name, .icon = agent.icon };
        }
        return .{ .name = id, .icon = "?" };
    }
    return .{ .name = "Agent", .icon = "?" };
}

fn resolveSessionLabel(sessions: []const types.Session, key: []const u8, label_buf: []u8) ?[]const u8 {
    const agent_id = if (session_keys.parse(key)) |parts| parts.agent_id else "main";
    return session_presenter.displayLabelForKey(sessions, agent_id, key, label_buf);
}

fn containsSlice(values: []const []const u8, value: []const u8) bool {
    for (values) |existing| {
        if (std.mem.eql(u8, existing, value)) return true;
    }
    return false;
}

fn appendUniqueSlice(storage: []([]const u8), len: *usize, value: []const u8) void {
    const available = storage[0..len.*];
    if (containsSlice(available, value)) return;
    if (len.* >= storage.len) return;
    storage[len.*] = value;
    len.* += 1;
}

const DockKeyboardResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    changed_layout: bool = false,
    collapsed_count: usize = 0,
    flyout_node_id: ?dock_graph.NodeId = null,
    flyout_pinned: bool = false,
};

pub const DockShortcutTestKey = enum {
    tab,
    page_up,
    page_down,
    left_arrow,
    right_arrow,
    up_arrow,
    down_arrow,
    enter,
};

pub const DockShortcutTestMods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const DockShortcutTestResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    changed_layout: bool = false,
    collapsed_count: usize = 0,
    flyout_node_id: ?dock_graph.NodeId = null,
    flyout_pinned: bool = false,
};

// Test hook: exercise docking keyboard shortcut behavior without a full draw frame.
pub fn applyDockShortcutForTest(
    allocator: std.mem.Allocator,
    manager: *panel_manager.PanelManager,
    content_rect: draw_context.Rect,
    key: DockShortcutTestKey,
    mods: DockShortcutTestMods,
) DockShortcutTestResult {
    var win_state = WindowUiState{};
    return applyDockShortcutForTestWithState(allocator, manager, content_rect, &win_state, key, mods);
}

pub fn applyDockShortcutForTestWithState(
    allocator: std.mem.Allocator,
    manager: *panel_manager.PanelManager,
    content_rect: draw_context.Rect,
    win_state: *WindowUiState,
    key: DockShortcutTestKey,
    mods: DockShortcutTestMods,
) DockShortcutTestResult {
    var queue = input_state.InputQueue.init(allocator);
    defer queue.deinit(allocator);
    queue.push(allocator, .{ .key_down = .{
        .key = switch (key) {
            .tab => .tab,
            .page_up => .page_up,
            .page_down => .page_down,
            .left_arrow => .left_arrow,
            .right_arrow => .right_arrow,
            .up_arrow => .up_arrow,
            .down_arrow => .down_arrow,
            .enter => .enter,
        },
        .mods = .{
            .ctrl = mods.ctrl,
            .shift = mods.shift,
            .alt = mods.alt,
            .super = false,
        },
        .repeat = false,
    } });
    const out = handleDockKeyboardShortcuts(&queue, manager, content_rect, win_state);
    return .{
        .focus_panel_id = out.focus_panel_id,
        .changed_layout = out.changed_layout,
        .collapsed_count = out.collapsed_count,
        .flyout_node_id = out.flyout_node_id,
        .flyout_pinned = out.flyout_pinned,
    };
}

fn handleDockKeyboardShortcuts(
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    content_rect: draw_context.Rect,
    win_state_opt: ?*WindowUiState,
) DockKeyboardResult {
    var out = DockKeyboardResult{};
    const focused_panel_id = manager.workspace.focused_panel_id orelse return out;
    const focused_loc = manager.workspace.dock_layout.findPanel(focused_panel_id) orelse return out;

    for (queue.events.items) |evt| {
        switch (evt) {
            .key_down => |kd| {
                if (kd.mods.ctrl and kd.mods.shift and (kd.key == .left_arrow or kd.key == .right_arrow or kd.key == .up_arrow or kd.key == .down_arrow or kd.key == .enter)) {
                    if (win_state_opt) |win_state| {
                        switch (kd.key) {
                            .left_arrow, .right_arrow => {
                                const side: dock_rail.Side = if (kd.key == .left_arrow) .left else .right;
                                const prev = win_state.collapsed_docks.sideForNode(focused_loc.node_id);
                                if (prev == null or prev.? != side) {
                                    win_state.collapsed_docks.collapse(focused_loc.node_id, side);
                                    out.changed_layout = true;
                                }
                                if (win_state.dock_flyout.node_id != null and win_state.dock_flyout.node_id.? == focused_loc.node_id) {
                                    win_state.dock_flyout.side = side;
                                }
                                out.focus_panel_id = focused_panel_id;
                            },
                            .up_arrow => {
                                if (win_state.dock_flyout.node_id != null) {
                                    win_state.dock_flyout.pinned = !win_state.dock_flyout.pinned;
                                } else {
                                    for (win_state.collapsed_docks.items[0..win_state.collapsed_docks.len]) |item| {
                                        const pid = activePanelForNode(manager, item.node_id) orelse continue;
                                        win_state.dock_flyout.node_id = item.node_id;
                                        win_state.dock_flyout.side = item.side;
                                        win_state.dock_flyout.pinned = false;
                                        out.focus_panel_id = pid;
                                        break;
                                    }
                                }
                            },
                            .down_arrow => {
                                if (win_state.dock_flyout.node_id != null) {
                                    win_state.dock_flyout.clear();
                                }
                            },
                            .enter => {
                                var target_node: ?dock_graph.NodeId = win_state.dock_flyout.node_id;
                                if (target_node == null and win_state.collapsed_docks.isCollapsed(focused_loc.node_id)) {
                                    target_node = focused_loc.node_id;
                                }
                                if (target_node) |node_id| {
                                    if (win_state.collapsed_docks.expand(node_id)) {
                                        out.changed_layout = true;
                                    }
                                    if (activePanelForNode(manager, node_id)) |pid| {
                                        out.focus_panel_id = pid;
                                    }
                                    if (win_state.dock_flyout.node_id != null and win_state.dock_flyout.node_id.? == node_id) {
                                        win_state.dock_flyout.clear();
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    continue;
                }

                if (kd.mods.ctrl and kd.key == .tab) {
                    const node = manager.workspace.dock_layout.getNode(focused_loc.node_id) orelse continue;
                    const tabs = switch (node.*) {
                        .tabs => |t| t,
                        .split => continue,
                    };
                    if (tabs.tabs.items.len == 0) continue;
                    const next = if (kd.mods.shift)
                        (tabs.active + tabs.tabs.items.len - 1) % tabs.tabs.items.len
                    else
                        (tabs.active + 1) % tabs.tabs.items.len;
                    if (manager.workspace.dock_layout.setActiveTab(focused_loc.node_id, next)) {
                        out.changed_layout = true;
                        out.focus_panel_id = tabs.tabs.items[next];
                    }
                    continue;
                }

                if (kd.mods.ctrl and (kd.key == .page_up or kd.key == .page_down)) {
                    const layout = manager.workspace.dock_layout.computeLayout(content_rect);
                    const groups = layout.slice();
                    if (groups.len <= 1) continue;
                    var cur_idx: usize = 0;
                    while (cur_idx < groups.len and groups[cur_idx].node_id != focused_loc.node_id) : (cur_idx += 1) {}
                    if (cur_idx >= groups.len) continue;

                    const next_idx = if (kd.key == .page_down)
                        (cur_idx + 1) % groups.len
                    else
                        (cur_idx + groups.len - 1) % groups.len;
                    const target_node_id = groups[next_idx].node_id;
                    const target_node = manager.workspace.dock_layout.getNode(target_node_id) orelse continue;
                    const target_tabs = switch (target_node.*) {
                        .tabs => |t| t,
                        .split => continue,
                    };
                    if (target_tabs.tabs.items.len == 0) continue;
                    _ = manager.workspace.dock_layout.setActiveTab(target_node_id, target_tabs.active);
                    out.changed_layout = true;
                    out.focus_panel_id = target_tabs.tabs.items[@min(target_tabs.active, target_tabs.tabs.items.len - 1)];
                    continue;
                }

                if (kd.mods.alt and kd.mods.shift and (kd.key == .left_arrow or kd.key == .right_arrow)) {
                    const node = manager.workspace.dock_layout.getNode(focused_loc.node_id) orelse continue;
                    const tabs = switch (node.*) {
                        .tabs => |t| t,
                        .split => continue,
                    };
                    if (tabs.tabs.items.len <= 1) continue;
                    const src_idx = focused_loc.tab_index;
                    var dst_idx: usize = src_idx;
                    if (kd.key == .left_arrow and src_idx > 0) {
                        dst_idx = src_idx - 1;
                    } else if (kd.key == .right_arrow and src_idx + 1 < tabs.tabs.items.len) {
                        // movePanelToTabs() interprets insert_index as "insert before"; moving right
                        // by one tab therefore targets the slot after the immediate neighbor.
                        dst_idx = src_idx + 2;
                    } else {
                        continue;
                    }
                    if (manager.workspace.dock_layout.movePanelToTabs(focused_panel_id, focused_loc.node_id, dst_idx) catch false) {
                        out.changed_layout = true;
                        out.focus_panel_id = focused_panel_id;
                    }
                    continue;
                }

                if (kd.mods.ctrl and kd.mods.alt and (kd.key == .left_arrow or kd.key == .right_arrow or kd.key == .up_arrow or kd.key == .down_arrow)) {
                    const dir: [2]i8 = switch (kd.key) {
                        .left_arrow => .{ -1, 0 },
                        .right_arrow => .{ 1, 0 },
                        .up_arrow => .{ 0, -1 },
                        .down_arrow => .{ 0, 1 },
                        else => .{ 0, 0 },
                    };
                    const target = nearestDockNodeInDirection(
                        &manager.workspace.dock_layout,
                        content_rect,
                        focused_loc.node_id,
                        dir,
                    ) orelse continue;
                    const loc: dock_graph.DropLocation = switch (kd.key) {
                        .left_arrow => .left,
                        .right_arrow => .right,
                        .up_arrow => .top,
                        .down_arrow => .bottom,
                        else => .center,
                    };
                    if (manager.workspace.dock_layout.splitNodeWithPanel(target, focused_panel_id, loc) catch false) {
                        out.changed_layout = true;
                        out.focus_panel_id = focused_panel_id;
                    }
                    continue;
                }

                if (kd.mods.ctrl and kd.mods.alt and kd.key == .enter) {
                    const target = nearestDockNode(
                        &manager.workspace.dock_layout,
                        content_rect,
                        focused_loc.node_id,
                    ) orelse continue;
                    if (manager.workspace.dock_layout.movePanelToTabs(focused_panel_id, target, null) catch false) {
                        out.changed_layout = true;
                        out.focus_panel_id = focused_panel_id;
                    }
                }
            },
            else => {},
        }
    }

    if (win_state_opt) |win_state| {
        out.collapsed_count = win_state.collapsed_docks.len;
        out.flyout_node_id = win_state.dock_flyout.node_id;
        out.flyout_pinned = win_state.dock_flyout.pinned;
    }
    return out;
}

fn rectCenter(rect: draw_context.Rect) [2]f32 {
    return .{
        rect.min[0] + rect.size()[0] * 0.5,
        rect.min[1] + rect.size()[1] * 0.5,
    };
}

fn nearestDockNode(
    graph: *const dock_graph.Graph,
    content_rect: draw_context.Rect,
    source_node: dock_graph.NodeId,
) ?dock_graph.NodeId {
    const layout = graph.computeLayout(content_rect);
    const groups = layout.slice();
    if (groups.len == 0) return null;

    var src_center: ?[2]f32 = null;
    for (groups) |g| {
        if (g.node_id == source_node) {
            src_center = rectCenter(g.rect);
            break;
        }
    }
    const s = src_center orelse return null;

    var best: ?dock_graph.NodeId = null;
    var best_dist: f32 = std.math.inf(f32);
    for (groups) |g| {
        if (g.node_id == source_node) continue;
        const c = rectCenter(g.rect);
        const dx = c[0] - s[0];
        const dy = c[1] - s[1];
        const d2 = dx * dx + dy * dy;
        if (d2 < best_dist) {
            best_dist = d2;
            best = g.node_id;
        }
    }
    return best;
}

fn nearestDockNodeInDirection(
    graph: *const dock_graph.Graph,
    content_rect: draw_context.Rect,
    source_node: dock_graph.NodeId,
    dir: [2]i8,
) ?dock_graph.NodeId {
    const layout = graph.computeLayout(content_rect);
    const groups = layout.slice();
    if (groups.len == 0) return null;

    var src_center: ?[2]f32 = null;
    for (groups) |g| {
        if (g.node_id == source_node) {
            src_center = rectCenter(g.rect);
            break;
        }
    }
    const s = src_center orelse return null;

    var best: ?dock_graph.NodeId = null;
    var best_dist: f32 = std.math.inf(f32);
    for (groups) |g| {
        if (g.node_id == source_node) continue;
        const c = rectCenter(g.rect);
        const dx = c[0] - s[0];
        const dy = c[1] - s[1];

        const matches_direction =
            ((dir[0] < 0 and dx < -1.0) or
                (dir[0] > 0 and dx > 1.0) or
                (dir[1] < 0 and dy < -1.0) or
                (dir[1] > 0 and dy > 1.0));
        if (!matches_direction) continue;

        const d2 = dx * dx + dy * dy;
        if (d2 < best_dist) {
            best_dist = d2;
            best = g.node_id;
        }
    }
    return best;
}

fn findTabHitAt(tab_hits: *const DockTabHitList, pos: [2]f32) ?DockTabHit {
    // Favor the last drawn tabs (top-most visual stacking).
    var idx: usize = tab_hits.len;
    while (idx > 0) {
        idx -= 1;
        const hit = tab_hits.items[idx];
        if (hit.rect.contains(pos)) return hit;
    }
    return null;
}

fn drawDockGroupFrame(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    win_state: *const WindowUiState,
    block_interactions: bool,
    node_id: dock_graph.NodeId,
    tabs: []const workspace.PanelId,
    active_index: usize,
    focused: bool,
    collapse_side: ?dock_rail.Side,
    tab_hits: *DockTabHitList,
    drop_targets: *DockDropTargetList,
) DockGroupFrameResult {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const size = rect.size();
    if (size[0] <= 0.0 or size[1] <= 0.0) {
        return .{ .content_rect = rect };
    }

    const layout_rect = panel_chrome.contentRect(rect);
    const layout_size = layout_rect.size();
    const tab_height = @min(layout_size[1], dc.lineHeight() + t.spacing.xs * 2.0);
    const header_rect = draw_context.Rect.fromMinSize(layout_rect.min, .{ layout_size[0], tab_height });

    panel_chrome.draw(dc, rect, .{
        .radius = 0.0,
        .draw_shadow = false,
        .draw_frame = true,
        .draw_border = false,
    });

    if (ss.panel.header_overlay) |paint| {
        panel_chrome.drawPaintRect(dc, header_rect, paint);
    } else {
        dc.drawRect(header_rect, .{ .fill = colors.withAlpha(t.colors.surface, 0.55) });
    }

    const base_border = ss.panel.border orelse t.colors.border;
    const focus_border = ss.panel.focus_border orelse t.colors.primary;
    dc.drawRect(layout_rect, .{
        .fill = null,
        .stroke = if (focused) focus_border else base_border,
        .thickness = 1.0,
    });

    const button_size = @min(tab_height, @max(12.0, tab_height - t.spacing.xs * 2.0));
    const button_y = layout_rect.min[1] + (tab_height - button_size) * 0.5;
    var button_x = layout_rect.max[0] - t.spacing.xs - button_size;

    const close_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_size, button_size });
    var close_panel_id: ?workspace.PanelId = null;
    if (!block_interactions and tabs.len > 0 and widgets.button.draw(dc, close_rect, "x", queue, .{
        .variant = .ghost,
        .radius = t.radius.sm,
        .style_override = &ss.panel.header_buttons.close,
    })) {
        close_panel_id = tabs[@min(active_index, tabs.len - 1)];
    }
    var buttons_left_edge = close_rect.min[0];

    button_x -= button_size + t.spacing.xs;
    var detach_panel_id: ?workspace.PanelId = null;
    const p = theme_runtime.getProfile();
    if (p.allow_multi_window and tabs.len > 0) {
        const detach_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_size, button_size });
        if (!block_interactions and widgets.button.draw(dc, detach_rect, "[]", queue, .{
            .variant = .ghost,
            .radius = t.radius.sm,
            .style_override = &ss.panel.header_buttons.detach,
        })) {
            detach_panel_id = tabs[@min(active_index, tabs.len - 1)];
        }
        buttons_left_edge = detach_rect.min[0];
        button_x -= button_size + t.spacing.xs;
    }

    var collapse_clicked = false;
    if (tabs.len > 0 and collapse_side != null) {
        const collapse_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_size, button_size });
        const collapse_label = if (collapse_side.? == .left)
            dockRailIconLabel(&ss.panel.dock_rail_icons.collapse_left, "<|")
        else
            dockRailIconLabel(&ss.panel.dock_rail_icons.collapse_right, "|>");
        if (!block_interactions and widgets.button.draw(dc, collapse_rect, collapse_label, queue, .{
            .variant = .ghost,
            .radius = t.radius.sm,
            .style_override = &ss.panel.header_buttons.detach,
        })) {
            collapse_clicked = true;
        }
        buttons_left_edge = collapse_rect.min[0];
    }

    const tabs_right_edge = buttons_left_edge - t.spacing.xs;
    var tab_x = layout_rect.min[0] + t.spacing.xs;
    const tab_pad_x = t.spacing.sm;
    const tab_radius = t.radius.sm;
    for (tabs, 0..) |panel_id, idx| {
        const panel = findPanelById(manager, panel_id) orelse continue;
        const label = panel.title;
        const label_w = dc.measureText(label, 0.0)[0];
        const tab_w = label_w + tab_pad_x * 2.0;
        if (tab_x + tab_w > tabs_right_edge) break;

        const tab_rect = draw_context.Rect.fromMinSize(
            .{ tab_x, header_rect.min[1] + t.spacing.xs * 0.4 },
            .{ tab_w, header_rect.size()[1] - t.spacing.xs * 0.8 },
        );
        const active = idx == active_index;
        const hovered = tab_rect.contains(queue.state.mouse_pos);
        const fill = if (active)
            colors.withAlpha(t.colors.primary, 0.18)
        else if (hovered and theme_runtime.allowHover(queue))
            colors.withAlpha(t.colors.primary, 0.10)
        else
            colors.withAlpha(t.colors.surface, 0.50);
        const stroke = if (active) t.colors.primary else colors.withAlpha(t.colors.border, 0.7);

        dc.drawRoundedRect(tab_rect, tab_radius, .{
            .fill = fill,
            .stroke = stroke,
            .thickness = 1.0,
        });
        const label_pos = .{
            tab_rect.min[0] + tab_pad_x,
            tab_rect.min[1] + (tab_rect.size()[1] - dc.lineHeight()) * 0.5,
        };
        dc.drawText(label, label_pos, .{
            .color = if (active) t.colors.text_primary else t.colors.text_secondary,
        });

        if (!block_interactions) {
            tab_hits.append(.{
                .panel_id = panel_id,
                .node_id = node_id,
                .tab_index = idx,
                .rect = tab_rect,
            });
        }
        tab_x = tab_rect.max[0] + t.spacing.xs;
    }

    const divider_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], header_rect.max[1] - 1.0 },
        .{ layout_rect.size()[0], 1.0 },
    );
    dc.drawRect(divider_rect, .{ .fill = t.colors.divider });

    const content_height = @max(0.0, layout_size[1] - tab_height);
    const content_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], layout_rect.min[1] + tab_height },
        .{ layout_size[0], content_height },
    );

    const center_w = content_rect.size()[0] * 0.42;
    const center_h = content_rect.size()[1] * 0.42;
    const center_rect = draw_context.Rect.fromMinSize(
        .{ content_rect.min[0] + (content_rect.size()[0] - center_w) * 0.5, content_rect.min[1] + (content_rect.size()[1] - center_h) * 0.5 },
        .{ center_w, center_h },
    );
    var is_source_group = false;
    if (win_state.dock_drag.source_node_id != null and win_state.dock_drag.source_node_id.? == node_id) {
        is_source_group = true;
    }
    if (!is_source_group) {
        drop_targets.append(.{ .node_id = node_id, .location = .center, .rect = center_rect });
    }

    var allow_edge_targets = true;
    if (is_source_group) {
        if (manager.workspace.dock_layout.getNode(node_id)) |src_node| {
            switch (src_node.*) {
                .tabs => |src_tabs| allow_edge_targets = src_tabs.tabs.items.len > 1,
                .split => allow_edge_targets = false,
            }
        }
    }
    if (allow_edge_targets) {
        const side_w = @max(24.0, @min(content_rect.size()[0] * 0.20, 108.0));
        const side_h = @max(24.0, @min(content_rect.size()[1] * 0.20, 108.0));
        // Prefer top/bottom bands before left/right so dragging near top/bottom corners
        // doesn't unexpectedly resolve to side splits.
        drop_targets.append(.{ .node_id = node_id, .location = .top, .rect = draw_context.Rect.fromMinSize(content_rect.min, .{ content_rect.size()[0], side_h }) });
        drop_targets.append(.{ .node_id = node_id, .location = .bottom, .rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], content_rect.max[1] - side_h }, .{ content_rect.size()[0], side_h }) });
        drop_targets.append(.{ .node_id = node_id, .location = .left, .rect = draw_context.Rect.fromMinSize(content_rect.min, .{ side_w, content_rect.size()[1] }) });
        drop_targets.append(.{ .node_id = node_id, .location = .right, .rect = draw_context.Rect.fromMinSize(.{ content_rect.max[0] - side_w, content_rect.min[1] }, .{ side_w, content_rect.size()[1] }) });
    }

    var frame_clicked = false;
    if (!block_interactions) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left and rect.contains(md.pos)) frame_clicked = true;
                },
                else => {},
            }
        }
    }

    return .{
        .content_rect = content_rect,
        .close_panel_id = close_panel_id,
        .detach_panel_id = detach_panel_id,
        .collapse_clicked = collapse_clicked,
        .frame_clicked = frame_clicked,
    };
}

fn activeDockFlyoutRect(
    dc: *const draw_context.DrawContext,
    manager: *panel_manager.PanelManager,
    win_state: *const WindowUiState,
    content_rect: draw_context.Rect,
    left_rail_width: f32,
    right_rail_width: f32,
) ?draw_context.Rect {
    const node_id = win_state.dock_flyout.node_id orelse return null;
    const side = win_state.dock_flyout.side;
    const node = manager.workspace.dock_layout.getNode(node_id) orelse return null;
    const tabs_node = switch (node.*) {
        .tabs => |tabs| tabs,
        .split => return null,
    };
    if (tabs_node.tabs.items.len == 0) return null;

    const t = dc.theme;
    const pad = t.spacing.xs;
    const avail_width = @max(0.0, content_rect.size()[0] - left_rail_width - right_rail_width - pad * 3.0);
    if (avail_width <= 120.0) return null;

    var flyout_width = std.math.clamp(content_rect.size()[0] * 0.34, 300.0, 760.0);
    if (flyout_width > avail_width) flyout_width = avail_width;
    const flyout_height = @max(0.0, content_rect.size()[1] - pad * 2.0);
    if (flyout_height <= 0.0) return null;
    const flyout_x = switch (side) {
        .left => content_rect.min[0] + left_rail_width + pad,
        .right => content_rect.max[0] - right_rail_width - pad - flyout_width,
    };
    return draw_context.Rect.fromMinSize(
        .{ flyout_x, content_rect.min[1] + pad },
        .{ flyout_width, flyout_height },
    );
}

fn drawCollapsedDockRails(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    win_state: *WindowUiState,
    content_rect: draw_context.Rect,
    left_rail_width: f32,
    right_rail_width: f32,
) DockRailInteractionResult {
    var out: DockRailInteractionResult = .{};
    if (left_rail_width <= 0.0 and right_rail_width <= 0.0) return out;
    const t = dc.theme;
    const focused_node_id = focusedDockNodeId(manager);
    const ss = theme_runtime.getStyleSheet();
    const allow_hover = theme_runtime.allowHover(queue);

    if (left_rail_width > 0.0) {
        const left_rect = draw_context.Rect.fromMinSize(content_rect.min, .{ left_rail_width, content_rect.size()[1] });
        dc.drawRect(left_rect, .{
            .fill = colors.withAlpha(t.colors.surface, 0.72),
            .stroke = colors.withAlpha(t.colors.border, 0.85),
            .thickness = 1.0,
        });

        const button_size = @max(12.0, left_rail_width - t.spacing.xs * 2.0);
        var y = left_rect.min[1] + t.spacing.xs;
        for (win_state.collapsed_docks.items[0..win_state.collapsed_docks.len]) |item| {
            if (item.side != .left) continue;
            const node = manager.workspace.dock_layout.getNode(item.node_id) orelse continue;
            const tabs = switch (node.*) {
                .tabs => |tabs_node| tabs_node,
                .split => continue,
            };
            for (tabs.tabs.items, 0..) |panel_id, tab_index| {
                const panel = findPanelById(manager, panel_id) orelse continue;
                if (y + button_size > left_rect.max[1]) break;
                const button_rect = draw_context.Rect.fromMinSize(
                    .{ left_rect.min[0] + t.spacing.xs, y },
                    .{ button_size, button_size },
                );
                const focused = focused_node_id != null and focused_node_id.? == item.node_id and tab_index == tabs.active;
                if (allow_hover and button_rect.contains(queue.state.mouse_pos)) {
                    out.hovered_item = item;
                }
                if (widgets.button.draw(dc, button_rect, railIconForPanel(panel, &ss.panel.dock_rail_icons), queue, .{
                    .variant = if (focused) .secondary else .ghost,
                    .radius = t.radius.sm,
                })) {
                    _ = manager.workspace.dock_layout.setActiveTab(item.node_id, tab_index);
                    out.clicked_item = item;
                    out.focus_panel_id = panel_id;
                }
                y += button_size + t.spacing.xs;
            }
        }
    }

    if (right_rail_width > 0.0) {
        const right_rect = draw_context.Rect.fromMinSize(
            .{ content_rect.max[0] - right_rail_width, content_rect.min[1] },
            .{ right_rail_width, content_rect.size()[1] },
        );
        dc.drawRect(right_rect, .{
            .fill = colors.withAlpha(t.colors.surface, 0.72),
            .stroke = colors.withAlpha(t.colors.border, 0.85),
            .thickness = 1.0,
        });

        const button_size = @max(12.0, right_rail_width - t.spacing.xs * 2.0);
        var y = right_rect.min[1] + t.spacing.xs;
        for (win_state.collapsed_docks.items[0..win_state.collapsed_docks.len]) |item| {
            if (item.side != .right) continue;
            const node = manager.workspace.dock_layout.getNode(item.node_id) orelse continue;
            const tabs = switch (node.*) {
                .tabs => |tabs_node| tabs_node,
                .split => continue,
            };
            for (tabs.tabs.items, 0..) |panel_id, tab_index| {
                const panel = findPanelById(manager, panel_id) orelse continue;
                if (y + button_size > right_rect.max[1]) break;
                const button_rect = draw_context.Rect.fromMinSize(
                    .{ right_rect.min[0] + t.spacing.xs, y },
                    .{ button_size, button_size },
                );
                const focused = focused_node_id != null and focused_node_id.? == item.node_id and tab_index == tabs.active;
                if (allow_hover and button_rect.contains(queue.state.mouse_pos)) {
                    out.hovered_item = item;
                }
                if (widgets.button.draw(dc, button_rect, railIconForPanel(panel, &ss.panel.dock_rail_icons), queue, .{
                    .variant = if (focused) .secondary else .ghost,
                    .radius = t.radius.sm,
                })) {
                    _ = manager.workspace.dock_layout.setActiveTab(item.node_id, tab_index);
                    out.clicked_item = item;
                    out.focus_panel_id = panel_id;
                }
                y += button_size + t.spacing.xs;
            }
        }
    }

    return out;
}

fn drawCollapsedDockFlyout(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    registry: *agent_registry.AgentRegistry,
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    queue: *input_state.InputQueue,
    dc: *draw_context.DrawContext,
    action: *UiAction,
    pending_attachment: *?sessions_panel.AttachmentOpen,
    win_state: *WindowUiState,
    content_rect: draw_context.Rect,
    left_rail_width: f32,
    right_rail_width: f32,
) DockFlyoutResult {
    var out: DockFlyoutResult = .{};
    const node_id = win_state.dock_flyout.node_id orelse return out;
    const side = win_state.dock_flyout.side;
    const node = manager.workspace.dock_layout.getNode(node_id) orelse {
        win_state.dock_flyout.clear();
        return out;
    };
    const tabs_node = switch (node.*) {
        .tabs => |tabs| tabs,
        .split => {
            win_state.dock_flyout.clear();
            return out;
        },
    };
    if (tabs_node.tabs.items.len == 0) {
        win_state.dock_flyout.clear();
        return out;
    }

    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const pad = t.spacing.xs;
    const avail_width = @max(0.0, content_rect.size()[0] - left_rail_width - right_rail_width - pad * 3.0);
    if (avail_width <= 120.0) return out;

    var flyout_width = std.math.clamp(content_rect.size()[0] * 0.34, 300.0, 760.0);
    if (flyout_width > avail_width) flyout_width = avail_width;
    const flyout_height = @max(0.0, content_rect.size()[1] - pad * 2.0);
    if (flyout_height <= 0.0) return out;
    const flyout_x = switch (side) {
        .left => content_rect.min[0] + left_rail_width + pad,
        .right => content_rect.max[0] - right_rail_width - pad - flyout_width,
    };
    const flyout_rect = draw_context.Rect.fromMinSize(
        .{ flyout_x, content_rect.min[1] + pad },
        .{ flyout_width, flyout_height },
    );
    const left_rail_rect = if (left_rail_width > 0.0)
        draw_context.Rect.fromMinSize(content_rect.min, .{ left_rail_width, content_rect.size()[1] })
    else
        draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 0.0, 0.0 });
    const right_rail_rect = if (right_rail_width > 0.0)
        draw_context.Rect.fromMinSize(
            .{ content_rect.max[0] - right_rail_width, content_rect.min[1] },
            .{ right_rail_width, content_rect.size()[1] },
        )
    else
        draw_context.Rect.fromMinSize(.{ 0.0, 0.0 }, .{ 0.0, 0.0 });

    if (!win_state.dock_flyout.pinned) {
        const pos = queue.state.mouse_pos;
        const over_rail = left_rail_rect.contains(pos) or right_rail_rect.contains(pos);
        if (!over_rail and !flyout_rect.contains(pos)) {
            win_state.dock_flyout.clear();
            return out;
        }
    }

    if (win_state.dock_flyout.pinned) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    if (flyout_rect.contains(md.pos)) continue;
                    if (left_rail_rect.contains(md.pos) or right_rail_rect.contains(md.pos)) continue;
                    win_state.dock_flyout.clear();
                    return out;
                },
                else => {},
            }
        }
    }

    panel_chrome.draw(dc, flyout_rect, .{
        .radius = 0.0,
        .draw_shadow = false,
        .draw_frame = true,
        .draw_border = false,
    });
    const layout_rect = panel_chrome.contentRect(flyout_rect);
    const layout_size = layout_rect.size();
    const tab_height = @min(layout_size[1], dc.lineHeight() + t.spacing.xs * 2.0);
    const header_rect = draw_context.Rect.fromMinSize(layout_rect.min, .{ layout_size[0], tab_height });

    if (ss.panel.header_overlay) |paint| {
        panel_chrome.drawPaintRect(dc, header_rect, paint);
    } else {
        dc.drawRect(header_rect, .{ .fill = colors.withAlpha(t.colors.surface, 0.7) });
    }

    const focus_border = ss.panel.focus_border orelse t.colors.primary;
    dc.drawRect(layout_rect, .{
        .fill = null,
        .stroke = focus_border,
        .thickness = 1.0,
    });

    const button_size = @min(tab_height, @max(12.0, tab_height - t.spacing.xs * 2.0));
    const button_y = layout_rect.min[1] + (tab_height - button_size) * 0.5;
    var button_x = layout_rect.max[0] - t.spacing.xs - button_size;

    const close_flyout_label = dockRailIconLabel(&ss.panel.dock_rail_icons.close_flyout, "x");
    const close_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_size, button_size });
    if (widgets.button.draw(dc, close_rect, close_flyout_label, queue, .{
        .variant = .ghost,
        .radius = t.radius.sm,
        .style_override = &ss.panel.header_buttons.close,
    })) {
        win_state.dock_flyout.clear();
        return out;
    }
    button_x -= button_size + t.spacing.xs;

    const expand_fallback = switch (side) {
        .left => "|>",
        .right => "<|",
    };
    const pin_label = dockRailIconLabel(&ss.panel.dock_rail_icons.pin, expand_fallback);
    const pin_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ button_size, button_size });
    if (widgets.button.draw(dc, pin_rect, pin_label, queue, .{
        .variant = .ghost,
        .radius = t.radius.sm,
        .style_override = &ss.panel.header_buttons.detach,
    })) {
        out.expand_node_id = node_id;
    }

    const tabs_right_edge = pin_rect.min[0] - t.spacing.xs;
    var clicked_tab: ?usize = null;
    var tab_x = layout_rect.min[0] + t.spacing.xs;
    const tab_pad_x = t.spacing.sm;
    const tab_radius = t.radius.sm;
    for (tabs_node.tabs.items, 0..) |panel_id, idx| {
        const panel = findPanelById(manager, panel_id) orelse continue;
        const label = panel.title;
        const label_w = dc.measureText(label, 0.0)[0];
        const tab_w = label_w + tab_pad_x * 2.0;
        if (tab_x + tab_w > tabs_right_edge) break;

        const tab_rect = draw_context.Rect.fromMinSize(
            .{ tab_x, header_rect.min[1] + t.spacing.xs * 0.4 },
            .{ tab_w, header_rect.size()[1] - t.spacing.xs * 0.8 },
        );
        const active = idx == @min(tabs_node.active, tabs_node.tabs.items.len - 1);
        const hovered = tab_rect.contains(queue.state.mouse_pos);
        const fill = if (active)
            colors.withAlpha(t.colors.primary, 0.18)
        else if (hovered and theme_runtime.allowHover(queue))
            colors.withAlpha(t.colors.primary, 0.10)
        else
            colors.withAlpha(t.colors.surface, 0.50);
        const stroke = if (active) t.colors.primary else colors.withAlpha(t.colors.border, 0.7);

        dc.drawRoundedRect(tab_rect, tab_radius, .{
            .fill = fill,
            .stroke = stroke,
            .thickness = 1.0,
        });
        dc.drawText(label, .{
            tab_rect.min[0] + tab_pad_x,
            tab_rect.min[1] + (tab_rect.size()[1] - dc.lineHeight()) * 0.5,
        }, .{ .color = if (active) t.colors.text_primary else t.colors.text_secondary });

        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_up => |mu| {
                    if (mu.button != .left) continue;
                    if (!tab_rect.contains(mu.pos)) continue;
                    if (queue.state.pointer_kind == .mouse or !queue.state.pointer_dragging) {
                        clicked_tab = idx;
                    }
                },
                else => {},
            }
        }

        tab_x = tab_rect.max[0] + t.spacing.xs;
    }

    if (clicked_tab) |idx| {
        if (manager.workspace.dock_layout.setActiveTab(node_id, idx)) {
            out.changed_layout = true;
        }
    }

    const divider_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], header_rect.max[1] - 1.0 },
        .{ layout_rect.size()[0], 1.0 },
    );
    dc.drawRect(divider_rect, .{ .fill = t.colors.divider });

    const content_height = @max(0.0, layout_size[1] - tab_height);
    const panel_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], layout_rect.min[1] + tab_height },
        .{ layout_size[0], content_height },
    );

    var frame_clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and flyout_rect.contains(md.pos)) frame_clicked = true;
            },
            else => {},
        }
    }

    const active_panel_id = activePanelForNode(manager, node_id) orelse return out;
    const panel = findPanelById(manager, active_panel_id) orelse return out;

    nav_router.pushScope(panel.id);
    defer nav_router.popScope();

    if (frame_clicked) out.focus_panel_id = panel.id;
    panel.state.is_focused = manager.workspace.focused_panel_id != null and manager.workspace.focused_panel_id.? == panel.id;
    const draw_result = drawPanelContents(
        allocator,
        ctx,
        cfg,
        registry,
        is_connected,
        app_version,
        panel,
        panel_rect,
        inbox,
        manager,
        action,
        pending_attachment,
        win_state,
        installer_profile_only_mode,
    );
    if (panel.kind == .Chat and draw_result.session_key != null) {
        out.session_key = draw_result.session_key;
        out.agent_id = draw_result.agent_id;
    }

    return out;
}

fn activePanelForNode(
    manager: *panel_manager.PanelManager,
    node_id: dock_graph.NodeId,
) ?workspace.PanelId {
    const node = manager.workspace.dock_layout.getNode(node_id) orelse return null;
    const tabs = switch (node.*) {
        .tabs => |t| t,
        .split => return null,
    };
    if (tabs.tabs.items.len == 0) return null;
    const active_index = @min(tabs.active, tabs.tabs.items.len - 1);
    return tabs.tabs.items[active_index];
}

fn railIconForPanel(panel: *const workspace.Panel, icons: *const style_sheet.DockRailIconsStyle) []const u8 {
    return switch (panel.kind) {
        .Chat => dockRailIconLabel(&icons.chat, "C"),
        .CodeEditor => dockRailIconLabel(&icons.code_editor, "E"),
        .ToolOutput => dockRailIconLabel(&icons.tool_output, "T"),
        .Control => dockRailIconLabel(&icons.control, "W"),
        .Agents => dockRailIconLabel(&icons.agents, "A"),
        .Operator => dockRailIconLabel(&icons.operator, "OP"),
        .ApprovalsInbox => dockRailIconLabel(&icons.approvals_inbox, "AP"),
        .Inbox => dockRailIconLabel(&icons.inbox, "AC"),
        .Workboard => dockRailIconLabel(&icons.workboard, "WB"),
        .Settings => dockRailIconLabel(&icons.settings, "SE"),
        .Showcase => dockRailIconLabel(&icons.showcase, "S"),
    };
}

fn dockRailIconLabel(icon: *const style_sheet.IconLabel, fallback: []const u8) []const u8 {
    if (icon.isSet()) return icon.slice();
    return fallback;
}

fn findSplitterAt(splitters: *const dock_graph.SplitterResult, pos: [2]f32) ?dock_graph.Splitter {
    // Prefer the last appended splitters (deepest children) for predictable hit-testing.
    var idx: usize = splitters.len;
    while (idx > 0) {
        idx -= 1;
        const sp = splitters.splitters[idx];
        if (sp.handle_rect.contains(pos)) return sp;
    }
    return null;
}

fn findSplitterByNode(splitters: *const dock_graph.SplitterResult, node_id: dock_graph.NodeId) ?dock_graph.Splitter {
    for (splitters.slice()) |sp| {
        if (sp.node_id == node_id) return sp;
    }
    return null;
}

fn handleDockSplitInteractions(
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    win_state: *WindowUiState,
    splitters: *const dock_graph.SplitterResult,
) bool {
    var changed = false;
    const hovered = findSplitterAt(splitters, queue.state.mouse_pos);
    if (hovered) |sp| {
        cursor.set(if (sp.axis == .vertical) .resize_ew else .resize_ns);
    }

    for (queue.events.items) |evt| {
        switch (evt) {
            .focus_lost => win_state.split_drag.clear(),
            .mouse_down => |md| {
                if (md.button != .left) continue;
                if (hovered) |sp| {
                    win_state.split_drag.node_id = sp.node_id;
                    win_state.split_drag.axis = sp.axis;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    win_state.split_drag.clear();
                }
            },
            else => {},
        }
    }

    const dragging_node = win_state.split_drag.node_id orelse return changed;
    const active_sp = findSplitterByNode(splitters, dragging_node) orelse {
        win_state.split_drag.clear();
        return changed;
    };

    cursor.set(if (active_sp.axis == .vertical) .resize_ew else .resize_ns);

    const container = active_sp.container_rect;
    const size = container.size();
    const min_px: f32 = 120.0;
    if (active_sp.axis == .vertical and size[0] > 0.0) {
        const min_ratio = std.math.clamp(min_px / size[0], 0.05, 0.45);
        const max_ratio = 1.0 - min_ratio;
        const ratio = std.math.clamp((queue.state.mouse_pos[0] - container.min[0]) / size[0], min_ratio, max_ratio);
        if (manager.workspace.dock_layout.setSplitRatio(active_sp.node_id, ratio)) {
            changed = true;
        }
    } else if (active_sp.axis == .horizontal and size[1] > 0.0) {
        const min_ratio = std.math.clamp(min_px / size[1], 0.05, 0.45);
        const max_ratio = 1.0 - min_ratio;
        const ratio = std.math.clamp((queue.state.mouse_pos[1] - container.min[1]) / size[1], min_ratio, max_ratio);
        if (manager.workspace.dock_layout.setSplitRatio(active_sp.node_id, ratio)) {
            changed = true;
        }
    }

    if (!queue.state.mouse_down_left) {
        win_state.split_drag.clear();
    }
    return changed;
}

fn drawDockSplitters(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    win_state: *const WindowUiState,
    splitters: *const dock_graph.SplitterResult,
) void {
    for (splitters.slice()) |sp| {
        const hovered = sp.handle_rect.contains(queue.state.mouse_pos);
        const active = win_state.split_drag.node_id != null and win_state.split_drag.node_id.? == sp.node_id;
        const fill = if (active)
            colors.withAlpha(dc.theme.colors.primary, 0.22)
        else if (hovered)
            colors.withAlpha(dc.theme.colors.primary, 0.12)
        else
            colors.withAlpha(dc.theme.colors.border, 0.08);
        dc.drawRect(sp.handle_rect, .{ .fill = fill });
    }
}

const DockInteractionResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    changed_layout: bool = false,
    detach_panel_id: ?workspace.PanelId = null,
};

fn handleDockTabInteractions(
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    win_state: *WindowUiState,
    tab_hits: *const DockTabHitList,
    drop_targets: *const DockDropTargetList,
    dock_rect: draw_context.Rect,
) DockInteractionResult {
    var out = DockInteractionResult{};
    var left_release = false;

    for (queue.events.items) |evt| {
        switch (evt) {
            .focus_lost => {
                if (win_state.dock_drag.panel_id) |pid| {
                    if (win_state.dock_drag.dragging) {
                        out.detach_panel_id = pid;
                        out.focus_panel_id = pid;
                    }
                }
                win_state.dock_drag.clear();
            },
            .mouse_down => |md| {
                if (md.button != .left) continue;
                if (findTabHitAt(tab_hits, md.pos)) |hit| {
                    win_state.dock_drag.panel_id = hit.panel_id;
                    win_state.dock_drag.source_node_id = hit.node_id;
                    win_state.dock_drag.source_tab_index = hit.tab_index;
                    win_state.dock_drag.press_pos = md.pos;
                    win_state.dock_drag.dragging = false;
                }
            },
            .mouse_up => |mu| {
                if (mu.button == .left) {
                    left_release = true;
                }
            },
            else => {},
        }
    }

    if (win_state.dock_drag.panel_id) |pid| {
        if (findPanelById(manager, pid) == null) {
            win_state.dock_drag.clear();
        }
    }

    if (win_state.dock_drag.panel_id != null and queue.state.mouse_down_left and !left_release) {
        if (!win_state.dock_drag.dragging) {
            const dx = queue.state.mouse_pos[0] - win_state.dock_drag.press_pos[0];
            const dy = queue.state.mouse_pos[1] - win_state.dock_drag.press_pos[1];
            if (dx * dx + dy * dy >= 16.0) {
                win_state.dock_drag.dragging = true;
            }
        }
    }

    if (left_release and win_state.dock_drag.panel_id != null) {
        const drag_panel_id = win_state.dock_drag.panel_id.?;
        const release_pos = queue.state.mouse_pos;
        if (win_state.dock_drag.dragging) {
            if (drop_targets.findAt(release_pos)) |target| {
                const changed = if (target.location == .center)
                    manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                else
                    manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                const repaired_layout = manager.workspace.syncDockLayout() catch false;
                if (changed) {
                    out.changed_layout = true;
                    out.focus_panel_id = drag_panel_id;
                    // Drag-drop targets are derived from the visible (collapsed-pruned) layout.
                    // When collapsed groups exist, mutating the full graph can route the drop into
                    // branches that remain hidden. Expand all collapsed groups after a successful
                    // drop so the result is always visible and predictable.
                    if (win_state.collapsed_docks.len > 0) {
                        win_state.collapsed_docks = .{};
                        win_state.dock_flyout.clear();
                        out.changed_layout = true;
                    }
                    // Ensure drag-dropped tabs don't end up "invisible" inside a collapsed node.
                    if (manager.workspace.dock_layout.findPanel(drag_panel_id)) |loc| {
                        if (win_state.collapsed_docks.expand(loc.node_id)) {
                            out.changed_layout = true;
                        }
                        if (win_state.dock_flyout.node_id != null and win_state.dock_flyout.node_id.? == loc.node_id) {
                            win_state.dock_flyout.clear();
                        }
                    }
                }
                if (repaired_layout) {
                    out.changed_layout = true;
                    if (out.focus_panel_id == null) out.focus_panel_id = drag_panel_id;
                }
            } else {
                if (!dock_rect.contains(release_pos)) {
                    out.detach_panel_id = drag_panel_id;
                    out.focus_panel_id = drag_panel_id;
                } else {
                    // Avoid accidental tear-off when release hit-testing misses a docking target.
                    // Keep focus on the dragged panel and leave layout unchanged.
                    out.focus_panel_id = drag_panel_id;
                }
            }
        } else if (findTabHitAt(tab_hits, release_pos)) |hit| {
            if (hit.panel_id == drag_panel_id) {
                if (manager.workspace.dock_layout.setActiveTab(hit.node_id, hit.tab_index)) {
                    out.changed_layout = true;
                }
                out.focus_panel_id = hit.panel_id;
            }
        }
        win_state.dock_drag.clear();
    } else if (!queue.state.mouse_down_left and win_state.dock_drag.panel_id != null) {
        const drag_panel_id = win_state.dock_drag.panel_id.?;
        if (win_state.dock_drag.dragging) {
            const release_pos = queue.state.mouse_pos;
            // Mouse-up can be dropped by the backend during cross-window drags. Treat this
            // as a release and only tear-off when the pointer is truly outside dock bounds.
            if (drop_targets.findAt(release_pos)) |target| {
                const changed = if (target.location == .center)
                    manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                else
                    manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                const repaired_layout = manager.workspace.syncDockLayout() catch false;
                const committed = changed or repaired_layout;
                if (changed) {
                    out.changed_layout = true;
                    out.focus_panel_id = drag_panel_id;
                    if (win_state.collapsed_docks.len > 0) {
                        win_state.collapsed_docks = .{};
                        win_state.dock_flyout.clear();
                        out.changed_layout = true;
                    }
                    if (manager.workspace.dock_layout.findPanel(drag_panel_id)) |loc| {
                        if (win_state.collapsed_docks.expand(loc.node_id)) {
                            out.changed_layout = true;
                        }
                        if (win_state.dock_flyout.node_id != null and win_state.dock_flyout.node_id.? == loc.node_id) {
                            win_state.dock_flyout.clear();
                        }
                    }
                }
                if (repaired_layout) {
                    out.changed_layout = true;
                    if (out.focus_panel_id == null) out.focus_panel_id = drag_panel_id;
                }
                if (!committed) {
                    if (!dock_rect.contains(release_pos)) {
                        out.detach_panel_id = drag_panel_id;
                        out.focus_panel_id = drag_panel_id;
                    } else {
                        out.focus_panel_id = drag_panel_id;
                    }
                }
            } else if (!dock_rect.contains(release_pos)) {
                out.detach_panel_id = drag_panel_id;
                out.focus_panel_id = drag_panel_id;
            } else {
                out.focus_panel_id = drag_panel_id;
            }
        }
        win_state.dock_drag.clear();
    }

    return out;
}

fn drawDockDragOverlay(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    win_state: *WindowUiState,
    drop_targets: *const DockDropTargetList,
    dock_rect: draw_context.Rect,
) void {
    if (!win_state.dock_drag.dragging) return;
    cursor.set(.arrow);
    const ss = theme_runtime.getStyleSheet();

    const hover_target = drop_targets.findAt(queue.state.mouse_pos);
    if (hover_target) |target| {
        // Show the target family for the hovered dock group so users can "read" all valid zones.
        for (drop_targets.items[0..drop_targets.len]) |candidate| {
            if (candidate.node_id != target.node_id or candidate.location == target.location) continue;
            drawDockDropPreview(dc, candidate, false, &ss.panel.dock_drop_preview);
        }
        drawDockDropPreview(dc, target, true, &ss.panel.dock_drop_preview);
    }

    const pid = win_state.dock_drag.panel_id orelse return;
    const panel = findPanelById(manager, pid) orelse return;
    var hint: []const u8 = "No dock target";
    if (hover_target) |target| {
        hint = dockDropTargetLabel(target.location);
    } else if (!dock_rect.contains(queue.state.mouse_pos)) {
        hint = "Detach to new window";
    }
    var label_buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&label_buf, "{s} -> {s}", .{ panel.title, hint }) catch panel.title;
    const text_w = dc.measureText(text, 0.0)[0];
    const pad = dc.theme.spacing.xs;
    const rect = draw_context.Rect.fromMinSize(
        .{ queue.state.mouse_pos[0] + 14.0, queue.state.mouse_pos[1] + 14.0 },
        .{ text_w + pad * 2.0, dc.lineHeight() + pad * 2.0 },
    );
    dc.drawRoundedRect(rect, dc.theme.radius.sm, .{
        .fill = colors.withAlpha(dc.theme.colors.background, 0.92),
        .stroke = colors.withAlpha(dc.theme.colors.border, 0.9),
        .thickness = 1.0,
    });
    dc.drawText(text, .{ rect.min[0] + pad, rect.min[1] + pad }, .{ .color = dc.theme.colors.text_primary });
}

fn dockDropTargetLabel(location: dock_graph.DropLocation) []const u8 {
    return switch (location) {
        .center => "Dock Center",
        .left => "Dock Left",
        .right => "Dock Right",
        .top => "Dock Top",
        .bottom => "Dock Bottom",
    };
}

fn drawDockDropPreview(
    dc: *draw_context.DrawContext,
    target: DockDropTarget,
    active: bool,
    style: *const style_sheet.DockDropPreviewStyle,
) void {
    const fill = if (active) style.active_fill else style.inactive_fill;
    const fallback_fill = style_sheet.Paint{ .solid = colors.withAlpha(dc.theme.colors.primary, if (active) 0.20 else 0.07) };
    panel_chrome.drawPaintRoundedRect(dc, target.rect, dc.theme.radius.sm, fill orelse fallback_fill);

    const base_stroke: f32 = if (active) 0.86 else 0.35;
    const stroke = if (active)
        style.active_border orelse colors.withAlpha(dc.theme.colors.primary, base_stroke)
    else
        style.inactive_border orelse colors.withAlpha(dc.theme.colors.primary, base_stroke);
    const thickness: f32 = std.math.clamp(if (active) (style.active_thickness orelse 2.0) else (style.inactive_thickness orelse 1.0), 0.5, 8.0);
    dc.drawRoundedRect(target.rect, dc.theme.radius.sm, .{
        .fill = null,
        .stroke = stroke,
        .thickness = thickness,
    });
    if (!active) return;

    const c = rectCenter(target.rect);
    const sz = target.rect.size();
    const marker = std.math.clamp(@min(sz[0], sz[1]) * 0.20, 10.0, 28.0);
    const marker_color = style.marker orelse colors.withAlpha(dc.theme.colors.primary, 0.9);
    switch (target.location) {
        .center => {
            dc.drawLine(.{ c[0] - marker, c[1] }, .{ c[0] + marker, c[1] }, 2.0, marker_color);
            dc.drawLine(.{ c[0], c[1] - marker }, .{ c[0], c[1] + marker }, 2.0, marker_color);
        },
        .left => dc.drawLine(.{ c[0] + marker * 0.7, c[1] }, .{ c[0] - marker, c[1] }, 2.0, marker_color),
        .right => dc.drawLine(.{ c[0] - marker * 0.7, c[1] }, .{ c[0] + marker, c[1] }, 2.0, marker_color),
        .top => dc.drawLine(.{ c[0], c[1] + marker * 0.7 }, .{ c[0], c[1] - marker }, 2.0, marker_color),
        .bottom => dc.drawLine(.{ c[0], c[1] - marker * 0.7 }, .{ c[0], c[1] + marker }, 2.0, marker_color),
    }
}

fn menuItemWidth(dc: *draw_context.DrawContext, label: []const u8, item_height: f32, t: *const theme.Theme) f32 {
    const line_height = dc.lineHeight();
    const box_size = @min(item_height, line_height) * 0.9;
    const label_w = dc.measureText(label, 0.0)[0];
    // box + label + padding (match drawMenuItem layout).
    return t.spacing.sm + box_size + t.spacing.xs + label_w + t.spacing.sm;
}

fn computeWindowMenuWidth(
    dc: *draw_context.DrawContext,
    cfg: *const config.Config,
    win_state: *const WindowUiState,
    item_height: f32,
) f32 {
    const t = dc.theme;
    const templates_all = theme_runtime.getWindowTemplates();
    const max_templates: usize = 8;
    const templates = templates_all[0..@min(templates_all.len, max_templates)];
    const allow_multi_window = (builtin.cpu.arch != .wasm32) and !builtin.abi.isAndroid();
    const recent = cfg.ui_theme_pack_recent orelse &[_][]const u8{};
    const max_recent: usize = 4;
    const recent_shown: usize = @min(recent.len, max_recent);

    var max_w: f32 = 0.0;
    const base_labels = [_][]const u8{
        "Workspace",
        "Chat",
        "Agents",
        "Operator",
        "Approvals",
        "Inbox",
        "Settings",
        "Showcase",
        "Layout: Reset",
        "Layout: Move tab to new group",
        "Layout: Close group",
        "Layout: Move group to window",
        "Theme pack: Global",
        "Theme pack: Browse...",
        "Theme pack: Reload",
        "Theme pack: Clear override",
        "New Window",
    };
    for (base_labels) |lbl| {
        max_w = @max(max_w, menuItemWidth(dc, lbl, item_height, t));
    }

    // Quick picks from the global MRU list (same label shortening logic as the draw loop).
    if (recent_shown > 0) {
        var i: usize = 0;
        while (i < recent_shown) : (i += 1) {
            const item = recent[i];
            var label_buf: [200]u8 = undefined;
            const short = blk: {
                const prefix = "themes/";
                if (std.mem.startsWith(u8, item, prefix)) break :blk item[prefix.len..];
                const idx = std.mem.lastIndexOfAny(u8, item, "/\\") orelse break :blk item;
                if (idx + 1 < item.len) break :blk item[idx + 1 ..];
                break :blk item;
            };
            const item_label = std.fmt.bufPrint(&label_buf, "Theme: {s}", .{short}) catch "Theme";
            max_w = @max(max_w, menuItemWidth(dc, item_label, item_height, t));
        }
    }

    if (allow_multi_window) {
        for (templates, 0..) |tpl, idx| {
            _ = idx;
            var label_buf: [96]u8 = undefined;
            const title = if (tpl.title.len > 0) tpl.title else tpl.id;
            const lbl = std.fmt.bufPrint(&label_buf, "New: {s}", .{title}) catch title;
            max_w = @max(max_w, menuItemWidth(dc, lbl, item_height, t));
        }
    }

    // Slightly widen if we show the "Clear override" line.
    if (win_state.theme_pack_override != null) {
        max_w = @max(max_w, menuItemWidth(dc, "Theme pack: Clear override", item_height, t));
    }

    // Clamp to a sane max so we don't cover the whole app on narrow windows.
    return std.math.clamp(max_w, 240.0, 520.0);
}

fn drawPanelFrame(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    title: []const u8,
    queue: *input_state.InputQueue,
    focused: bool,
) PanelFrameResult {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const size = rect.size();
    if (size[0] <= 0.0 or size[1] <= 0.0) {
        return .{
            .content_rect = rect,
            .close_clicked = false,
            .detach_clicked = false,
            .clicked = false,
        };
    }

    // Layout inside the theme-provided content inset so thick 9-slice borders don't overlap text/widgets.
    const layout_rect = panel_chrome.contentRect(rect);
    const layout_size = layout_rect.size();

    const title_height = dc.lineHeight();
    const pad_y = t.spacing.xs;
    const header_height = @min(layout_size[1], title_height + pad_y * 2.0);
    const header_rect = draw_context.Rect.fromMinSize(layout_rect.min, .{ layout_size[0], header_height });

    // Panel background/chrome (supports image fills like brushed metal).
    panel_chrome.draw(dc, rect, .{
        .radius = 0.0,
        .draw_shadow = false,
        .draw_frame = true,
        .draw_border = false,
    });

    // Header overlay: themeable, so texture-based themes can keep the "material" consistent.
    if (ss.panel.header_overlay) |paint| {
        panel_chrome.drawPaintRect(dc, header_rect, paint);
    } else {
        // Fallback: subtle solid tint to separate header from content.
        dc.drawRect(header_rect, .{ .fill = colors.withAlpha(t.colors.surface, 0.55) });
    }

    // Focus border on top of theme border/frame.
    const base_border = ss.panel.border orelse t.colors.border;
    const focus_border = ss.panel.focus_border orelse t.colors.primary;
    const border_color = if (focused) focus_border else base_border;
    dc.drawRect(layout_rect, .{ .fill = null, .stroke = border_color, .thickness = 1.0 });

    const close_size = @min(header_height, @max(12.0, header_height - pad_y * 2.0));
    const close_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.max[0] - t.spacing.xs - close_size, layout_rect.min[1] + (header_height - close_size) * 0.5 },
        .{ close_size, close_size },
    );

    // Optional detach button (multi-window desktop only).
    var detach_clicked = false;
    const p = theme_runtime.getProfile();
    if (p.allow_multi_window) {
        const detach_rect = draw_context.Rect.fromMinSize(
            .{ close_rect.min[0] - t.spacing.xs - close_size, close_rect.min[1] },
            .{ close_size, close_size },
        );
        detach_clicked = widgets.button.draw(dc, detach_rect, "[]", queue, .{
            .variant = .ghost,
            .radius = t.radius.sm,
            .style_override = &ss.panel.header_buttons.detach,
        });
    }

    const close_clicked = widgets.button.draw(dc, close_rect, "x", queue, .{
        .variant = .ghost,
        .radius = t.radius.sm,
        .style_override = &ss.panel.header_buttons.close,
    });

    const title_x = layout_rect.min[0] + t.spacing.sm;
    const title_y = layout_rect.min[1] + (header_height - title_height) * 0.5;
    theme.pushFor(t, .title);
    dc.drawText(title, .{ title_x, title_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const divider_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], header_rect.max[1] - 1.0 },
        .{ layout_rect.size()[0], 1.0 },
    );
    dc.drawRect(divider_rect, .{ .fill = t.colors.divider });

    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| {
                if (md.button == .left and rect.contains(md.pos)) {
                    clicked = true;
                }
            },
            else => {},
        }
    }

    const content_height = @max(0.0, layout_size[1] - header_height);
    const content_rect = draw_context.Rect.fromMinSize(
        .{ layout_rect.min[0], layout_rect.min[1] + header_height },
        .{ layout_size[0], content_height },
    );
    return .{
        .content_rect = content_rect,
        .close_clicked = close_clicked,
        .detach_clicked = detach_clicked,
        .clicked = clicked,
    };
}

pub fn syncSettings(allocator: std.mem.Allocator, cfg: config.Config) void {
    @import("settings_view.zig").syncFromConfig(allocator, cfg);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    chat_view.deinitGlobals(allocator);
    @import("panels/agents_panel.zig").deinit(allocator);
    @import("operator_view.zig").deinit(allocator);
    @import("settings_view.zig").deinit(allocator);
    @import("input_panel.zig").deinit(allocator);
    @import("artifact_workspace_view.zig").deinit(allocator);
    for (pending_attachment_fetches.items) |*entry| {
        freePendingAttachment(allocator, entry);
    }
    pending_attachment_fetches.deinit(allocator);
    pending_attachment_fetches = .empty;
    command_queue.deinit(allocator);
}

fn openAttachmentInEditor(
    allocator: std.mem.Allocator,
    manager: *panel_manager.PanelManager,
    attachment: sessions_panel.AttachmentOpen,
) void {
    const language = guessAttachmentLanguage(attachment);
    var pending_fetch = false;
    const content = buildAttachmentContent(allocator, attachment, &pending_fetch) orelse return;
    defer allocator.free(content);

    if (manager.findReusablePanel(.CodeEditor, attachment.name)) |panel| {
        if (!std.mem.eql(u8, panel.data.CodeEditor.language, language)) {
            allocator.free(panel.data.CodeEditor.language);
            panel.data.CodeEditor.language = allocator.dupe(u8, language) catch panel.data.CodeEditor.language;
        }
        panel.data.CodeEditor.content.set(allocator, content) catch {};
        panel.data.CodeEditor.last_modified_by = .ai;
        panel.data.CodeEditor.version += 1;
        panel.state.is_dirty = false;
        manager.focusPanel(panel.id);
        if (pending_fetch) {
            trackPendingAttachment(allocator, panel.id, attachment);
        }
        return;
    }

    const file_copy = allocator.dupe(u8, attachment.name) catch return;
    errdefer allocator.free(file_copy);
    const lang_copy = allocator.dupe(u8, language) catch {
        allocator.free(file_copy);
        return;
    };
    errdefer allocator.free(lang_copy);
    var buffer = text_buffer.TextBuffer.init(allocator, content) catch {
        allocator.free(file_copy);
        allocator.free(lang_copy);
        return;
    };
    errdefer buffer.deinit(allocator);
    const panel_data = workspace.PanelData{ .CodeEditor = .{
        .file_id = file_copy,
        .language = lang_copy,
        .content = buffer,
        .last_modified_by = .ai,
        .version = 1,
    } };
    const panel_id = manager.openPanel(.CodeEditor, attachment.name, panel_data) catch {
        var cleanup = panel_data;
        cleanup.deinit(allocator);
        return;
    };
    if (pending_fetch) {
        trackPendingAttachment(allocator, panel_id, attachment);
    }
}

fn buildAttachmentContent(
    allocator: std.mem.Allocator,
    attachment: sessions_panel.AttachmentOpen,
    pending_fetch: *bool,
) ?[]u8 {
    pending_fetch.* = false;
    if (std.mem.startsWith(u8, attachment.url, "data:")) {
        if (data_uri.decodeDataUriBytes(allocator, attachment.url)) |bytes| {
            defer allocator.free(bytes);
            if (std.unicode.utf8ValidateSlice(bytes)) {
                const slice = trimBody(bytes, attachment_editor_limit);
                if (!slice.truncated and isJsonAttachment(attachment, slice.body)) {
                    if (prettyJsonAlloc(allocator, slice.body)) |pretty| {
                        defer allocator.free(pretty);
                        return composeAttachmentContent(allocator, attachment, pretty, null, false);
                    }
                }
                return composeAttachmentContent(allocator, attachment, slice.body, null, slice.truncated);
            }
        } else |_| {}
    }

    if (isHttpUrl(attachment.url)) {
        attachment_cache.request(attachment.url, attachment_fetch_limit);
        if (attachment_cache.get(attachment.url)) |entry| {
            switch (entry.state) {
                .ready => {
                    if (entry.data) |data| {
                        const slice = trimBody(data, attachment_editor_limit);
                        if (!slice.truncated and isJsonAttachment(attachment, slice.body)) {
                            if (prettyJsonAlloc(allocator, slice.body)) |pretty| {
                                defer allocator.free(pretty);
                                return composeAttachmentContent(allocator, attachment, pretty, null, false);
                            }
                        }
                        return composeAttachmentContent(allocator, attachment, slice.body, null, slice.truncated);
                    }
                    return composeAttachmentContent(allocator, attachment, null, "Attachment content missing.", false);
                },
                .failed => {
                    var status_buf: [128]u8 = undefined;
                    const status = if (entry.error_message) |err|
                        std.fmt.bufPrint(&status_buf, "Fetch failed: {s}", .{err}) catch "Fetch failed."
                    else
                        "Fetch failed.";
                    return composeAttachmentContent(allocator, attachment, null, status, false);
                },
                .loading => {
                    pending_fetch.* = true;
                    return composeAttachmentContent(allocator, attachment, null, "Fetching attachment...", false);
                },
            }
        }
        pending_fetch.* = true;
        return composeAttachmentContent(allocator, attachment, null, "Fetching attachment...", false);
    }

    return composeAttachmentContent(allocator, attachment, null, null, false);
}

fn composeAttachmentContent(
    allocator: std.mem.Allocator,
    attachment: sessions_panel.AttachmentOpen,
    body: ?[]const u8,
    status: ?[]const u8,
    truncated: bool,
) ?[]u8 {
    const header = std.fmt.allocPrint(
        allocator,
        "Attachment: {s}\nType: {s}\nURL: {s}\nRole: {s}\nTimestamp: {d}\n",
        .{
            attachment.name,
            attachment.kind,
            attachment.url,
            attachment.role,
            attachment.timestamp,
        },
    ) catch return null;
    errdefer allocator.free(header);

    if (status) |note| {
        const combined = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ header, note }) catch return header;
        allocator.free(header);
        return combined;
    }

    if (body) |text| {
        const suffix: []const u8 = if (truncated) "\n\n[truncated]" else "";
        const combined = std.fmt.allocPrint(
            allocator,
            "{s}\n---\n{s}{s}",
            .{ header, text, suffix },
        ) catch return header;
        allocator.free(header);
        return combined;
    }

    return header;
}

fn trimBody(data: []const u8, max_len: usize) struct { body: []const u8, truncated: bool } {
    if (data.len <= max_len) return .{ .body = data, .truncated = false };
    return .{ .body = data[0..max_len], .truncated = true };
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    var index: usize = 0;
    while (index < suffix.len) : (index += 1) {
        if (std.ascii.toLower(value[start + index]) != suffix[index]) return false;
    }
    return true;
}

fn hasTokenIgnoreCase(value: []const u8, token: []const u8) bool {
    if (token.len == 0 or value.len < token.len) return false;
    var i: usize = 0;
    while (i + token.len <= value.len) : (i += 1) {
        var matches = true;
        var j: usize = 0;
        while (j < token.len) : (j += 1) {
            if (std.ascii.toLower(value[i + j]) != token[j]) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn isJsonAttachment(att: sessions_panel.AttachmentOpen, body: []const u8) bool {
    if (hasTokenIgnoreCase(att.kind, "json")) return true;
    if (endsWithIgnoreCase(att.url, ".json") or endsWithIgnoreCase(att.url, ".jsonl")) return true;
    const trimmed = std.mem.trimLeft(u8, body, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return true;
    return false;
}

fn isMarkdownAttachment(att: sessions_panel.AttachmentOpen) bool {
    if (hasTokenIgnoreCase(att.kind, "markdown")) return true;
    return endsWithIgnoreCase(att.url, ".md") or endsWithIgnoreCase(att.url, ".markdown");
}

fn isLogAttachment(att: sessions_panel.AttachmentOpen) bool {
    if (hasTokenIgnoreCase(att.kind, "log")) return true;
    return endsWithIgnoreCase(att.url, ".log");
}

fn guessAttachmentLanguage(att: sessions_panel.AttachmentOpen) []const u8 {
    if (isJsonAttachment(att, "")) return "json";
    if (isMarkdownAttachment(att)) return "markdown";
    if (isLogAttachment(att)) return "log";
    if (endsWithIgnoreCase(att.url, ".zig")) return "zig";
    if (endsWithIgnoreCase(att.url, ".toml")) return "toml";
    if (endsWithIgnoreCase(att.url, ".yaml") or endsWithIgnoreCase(att.url, ".yml")) return "yaml";
    if (endsWithIgnoreCase(att.url, ".txt")) return "text";
    if (att.kind.len > 0) return att.kind;
    return "text";
}

fn prettyJsonAlloc(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    if (body.len > attachment_json_pretty_limit) return null;
    if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
        defer parsed.deinit();
        return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch null;
    } else |_| {}
    return null;
}

fn trackPendingAttachment(
    allocator: std.mem.Allocator,
    panel_id: workspace.PanelId,
    attachment: sessions_panel.AttachmentOpen,
) void {
    var index: usize = 0;
    while (index < pending_attachment_fetches.items.len) {
        if (pending_attachment_fetches.items[index].panel_id == panel_id) {
            freePendingAttachment(allocator, &pending_attachment_fetches.items[index]);
            _ = pending_attachment_fetches.orderedRemove(index);
            break;
        }
        index += 1;
    }

    const name_copy = allocator.dupe(u8, attachment.name) catch return;
    errdefer allocator.free(name_copy);
    const kind_copy = allocator.dupe(u8, attachment.kind) catch {
        allocator.free(name_copy);
        return;
    };
    errdefer allocator.free(kind_copy);
    const url_copy = allocator.dupe(u8, attachment.url) catch {
        allocator.free(name_copy);
        allocator.free(kind_copy);
        return;
    };
    errdefer allocator.free(url_copy);
    const role_copy = allocator.dupe(u8, attachment.role) catch {
        allocator.free(name_copy);
        allocator.free(kind_copy);
        allocator.free(url_copy);
        return;
    };

    pending_attachment_fetches.append(allocator, .{
        .panel_id = panel_id,
        .name = name_copy,
        .kind = kind_copy,
        .url = url_copy,
        .role = role_copy,
        .timestamp = attachment.timestamp,
    }) catch {
        allocator.free(name_copy);
        allocator.free(kind_copy);
        allocator.free(url_copy);
        allocator.free(role_copy);
    };
}

fn freePendingAttachment(allocator: std.mem.Allocator, entry: *PendingAttachment) void {
    allocator.free(entry.name);
    allocator.free(entry.kind);
    allocator.free(entry.url);
    allocator.free(entry.role);
}

fn syncAttachmentFetches(allocator: std.mem.Allocator, manager: *panel_manager.PanelManager) void {
    var index: usize = 0;
    while (index < pending_attachment_fetches.items.len) {
        const entry = &pending_attachment_fetches.items[index];
        const panel = findPanelById(manager, entry.panel_id);
        if (panel == null or panel.?.kind != .CodeEditor) {
            freePendingAttachment(allocator, entry);
            _ = pending_attachment_fetches.orderedRemove(index);
            continue;
        }

        if (attachment_cache.get(entry.url)) |cached| {
            switch (cached.state) {
                .loading => {
                    index += 1;
                    continue;
                },
                .ready => {
                    if (cached.data) |data| {
                        const slice = trimBody(data, attachment_editor_limit);
                        const attach = sessions_panel.AttachmentOpen{
                            .name = entry.name,
                            .kind = entry.kind,
                            .url = entry.url,
                            .role = entry.role,
                            .timestamp = entry.timestamp,
                        };
                        var content: ?[]u8 = null;
                        if (!slice.truncated and isJsonAttachment(attach, slice.body)) {
                            if (prettyJsonAlloc(allocator, slice.body)) |pretty| {
                                defer allocator.free(pretty);
                                content = composeAttachmentContent(allocator, attach, pretty, null, false);
                            }
                        }
                        if (content == null) {
                            content = composeAttachmentContent(allocator, attach, slice.body, null, slice.truncated);
                        }
                        if (content) |value| {
                            defer allocator.free(value);
                            const lang = guessAttachmentLanguageFromBody(attach, slice.body);
                            updatePanelContent(manager, entry.panel_id, allocator, value, lang);
                        }
                    }
                },
                .failed => {
                    var status_buf: [128]u8 = undefined;
                    const status = if (cached.error_message) |err|
                        std.fmt.bufPrint(&status_buf, "Fetch failed: {s}", .{err}) catch "Fetch failed."
                    else
                        "Fetch failed.";
                    const attach = sessions_panel.AttachmentOpen{
                        .name = entry.name,
                        .kind = entry.kind,
                        .url = entry.url,
                        .role = entry.role,
                        .timestamp = entry.timestamp,
                    };
                    if (composeAttachmentContent(allocator, attach, null, status, false)) |content| {
                        defer allocator.free(content);
                        updatePanelContent(manager, entry.panel_id, allocator, content, null);
                    }
                },
            }
            freePendingAttachment(allocator, entry);
            _ = pending_attachment_fetches.orderedRemove(index);
            continue;
        }

        index += 1;
    }
}

fn updatePanelContent(
    manager: *panel_manager.PanelManager,
    panel_id: workspace.PanelId,
    allocator: std.mem.Allocator,
    content: []const u8,
    language: ?[]const u8,
) void {
    for (manager.workspace.panels.items) |*panel| {
        if (panel.id != panel_id or panel.kind != .CodeEditor) continue;
        if (language) |lang| {
            if (std.mem.eql(u8, panel.data.CodeEditor.language, "text") and
                !std.mem.eql(u8, panel.data.CodeEditor.language, lang))
            {
                allocator.free(panel.data.CodeEditor.language);
                panel.data.CodeEditor.language = allocator.dupe(u8, lang) catch panel.data.CodeEditor.language;
            }
        }
        panel.data.CodeEditor.content.set(allocator, content) catch {};
        panel.data.CodeEditor.last_modified_by = .ai;
        panel.data.CodeEditor.version += 1;
        panel.state.is_dirty = false;
        manager.workspace.markDirty();
        break;
    }
}

fn findPanelById(
    manager: *panel_manager.PanelManager,
    panel_id: workspace.PanelId,
) ?*workspace.Panel {
    for (manager.workspace.panels.items) |*panel| {
        if (panel.id == panel_id) return panel;
    }
    return null;
}

fn guessAttachmentLanguageFromBody(
    att: sessions_panel.AttachmentOpen,
    body: []const u8,
) []const u8 {
    if (isJsonAttachment(att, body)) return "json";
    return guessAttachmentLanguage(att);
}
