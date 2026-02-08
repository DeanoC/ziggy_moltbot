const std = @import("std");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");
const custom_layout = @import("layout/custom_layout.zig");
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
const agent_registry = @import("../client/agent_registry.zig");
const session_keys = @import("../client/session_keys.zig");
const types = @import("../protocol/types.zig");
const chat_panel = @import("panels/chat_panel.zig");
const code_editor_panel = @import("panels/code_editor_panel.zig");
const tool_output_panel = @import("panels/tool_output_panel.zig");
const control_panel = @import("panels/control_panel.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const showcase_panel = @import("panels/showcase_panel.zig");
const status_bar = @import("status_bar.zig");
const widgets = @import("widgets/widgets.zig");
const text_input_backend = @import("input/text_input_backend.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const profiler = @import("../utils/profiler.zig");
const panel_chrome = @import("panel_chrome.zig");

pub const SendMessageAction = struct {
    session_key: []u8,
    message: []u8,
};

pub const WindowUiState = struct {
    custom_split_dragging: bool = false,
    custom_window_menu_open: bool = false,
    nav: nav.NavState = .{},

    fullscreen_page: FullscreenPage = .home,

    pub fn deinit(self: *WindowUiState, allocator: std.mem.Allocator) void {
        self.nav.deinit(allocator);
        self.* = undefined;
    }
};

const FullscreenPage = enum {
    home,
    agents,
    settings,
    chat,
    showcase,
};

pub const UiAction = struct {
    send_message: ?SendMessageAction = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    reload_theme_pack: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    spawn_window: bool = false,
    spawn_window_template: ?u32 = null,
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?@import("panels/agents_panel.zig").AgentSessionAction = null,
    set_default_session: ?@import("panels/agents_panel.zig").AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    add_agent: ?@import("panels/agents_panel.zig").AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
    focus_session: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?@import("operator_view.zig").NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?@import("operator_view.zig").ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
    save_workspace: bool = false,
    open_url: ?[]u8 = null,
};

const PanelDrawResult = struct {
    session_key: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

const PanelFrameResult = struct {
    content_rect: draw_context.Rect,
    close_clicked: bool,
    clicked: bool,
};

fn customMenuHeight(line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs * 2.0;
}

fn statusBarHeight(line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs * 2.0;
}

fn drawCustomMenuBar(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    manager: *panel_manager.PanelManager,
    action: *UiAction,
    win_state: *WindowUiState,
) void {
    const t = dc.theme;
    dc.drawRect(rect, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });

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

    const menu_width: f32 = 240.0;
    const menu_padding = t.spacing.xs;
    const item_height = dc.lineHeight() + t.spacing.xs * 2.0;
    // Multi-window is a platform capability (desktop native), not a UI profile feature.
    // Even if the user is running the Phone/Tablet profile on desktop, they may still want
    // detachable/multi-window UI (Winamp-style use case).
    const allow_multi_window = (builtin.cpu.arch != .wasm32) and !builtin.abi.isAndroid();
    const templates_all = theme_runtime.getWindowTemplates();
    const max_templates: usize = 8;
    const templates = templates_all[0..@min(templates_all.len, max_templates)];
    const item_count: f32 = 3.0 + (if (allow_multi_window) (1.0 + @as(f32, @floatFromInt(templates.len))) else 0.0);
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

    const has_control = manager.hasPanel(.Control);
    const has_chat = manager.hasPanel(.Chat);
    const has_showcase = manager.hasPanel(.Showcase);
    var cursor_y = menu_rect.min[1] + menu_padding;
    if (drawMenuItem(dc, queue, draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }), "Workspace", has_control)) {
        if (has_control) {
            _ = manager.closePanelByKind(.Control);
        } else {
            manager.ensurePanel(.Control);
        }
        win_state.custom_window_menu_open = false;
    }
    cursor_y += item_height;
    if (drawMenuItem(dc, queue, draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }), "Chat", has_chat)) {
        if (has_chat) {
            _ = manager.closePanelByKind(.Chat);
        } else {
            manager.ensurePanel(.Chat);
        }
        win_state.custom_window_menu_open = false;
    }
    cursor_y += item_height;
    if (drawMenuItem(dc, queue, draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }), "Showcase", has_showcase)) {
        if (has_showcase) {
            _ = manager.closePanelByKind(.Showcase);
        } else {
            manager.ensurePanel(.Showcase);
        }
        win_state.custom_window_menu_open = false;
    }
    if (allow_multi_window) {
        cursor_y += item_height;
        if (drawMenuItem(
            dc,
            queue,
            draw_context.Rect.fromMinSize(.{ menu_rect.min[0], cursor_y }, .{ menu_rect.size()[0], item_height }),
            "New Window",
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

fn drawMenuItem(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    label: []const u8,
    selected: bool,
) bool {
    const t = dc.theme;
    const hovered = rect.contains(queue.state.mouse_pos);
    if (hovered) {
        dc.drawRect(rect, .{ .fill = colors.withAlpha(t.colors.primary, 0.08) });
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
    const box_fill = if (selected) t.colors.primary else t.colors.surface;
    const box_border = if (selected)
        colors.blend(t.colors.primary, colors.rgba(255, 255, 255, 255), 0.1)
    else
        t.colors.border;
    dc.drawRoundedRect(box_rect, t.radius.sm, .{
        .fill = box_fill,
        .stroke = box_border,
        .thickness = 1.0,
    });
    if (selected) {
        const inset = box_size * 0.2;
        const x0 = box_rect.min[0] + inset;
        const y0 = box_rect.min[1] + box_size * 0.55;
        const x1 = box_rect.min[0] + box_size * 0.45;
        const y1 = box_rect.min[1] + box_size * 0.75;
        const x2 = box_rect.min[0] + box_size * 0.8;
        const y2 = box_rect.min[1] + box_size * 0.3;
        const thickness = @max(1.5, box_size * 0.12);
        const check_color = colors.rgba(255, 255, 255, 255);
        dc.drawLine(.{ x0, y0 }, .{ x1, y1 }, thickness, check_color);
        dc.drawLine(.{ x1, y1 }, .{ x2, y2 }, thickness, check_color);
    }

    const label_x = box_rect.max[0] + t.spacing.xs;
    dc.drawText(label, .{ label_x, text_y }, .{ .color = t.colors.text_primary });

    var clicked = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_up => |mu| {
                if (mu.button == .left and rect.contains(mu.pos)) {
                    clicked = true;
                }
            },
            else => {},
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
    const zone = profiler.zone("ui.draw");
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
    const zone = profiler.zone("ui.workspace");
    defer zone.end();
    _ = command_queue.beginFrame(allocator);
    defer command_queue.endFrame();

    cursor.set(.arrow);
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, host_rect);
    defer dc.deinit();

    dc.drawRect(host_rect, .{ .fill = t.colors.background });

    if (theme_runtime.getProfile().id == .fullscreen) {
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

    const line_height = dc.lineHeight();
    const menu_height = customMenuHeight(line_height, t);
    const status_height = statusBarHeight(line_height, t);
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

    const gap = t.spacing.sm;
    const left_kind: ?workspace.PanelKind = if (manager.hasPanel(.Chat)) .Chat else null;
    var right_buf: [3]workspace.PanelKind = undefined;
    var right_len: usize = 0;
    if (manager.hasPanel(.Control)) {
        right_buf[right_len] = .Control;
        right_len += 1;
    }
    if (manager.hasPanel(.Showcase) and right_len < right_buf.len) {
        right_buf[right_len] = .Showcase;
        right_len += 1;
    }

    var ratio = manager.workspace.custom_layout.left_ratio;
    if (left_kind != null and right_len > 0 and content_rect.size()[0] > 0.0) {
        const width = content_rect.size()[0];
        const min_left = @min(manager.workspace.custom_layout.min_left_width, width);
        const max_left = @max(min_left, width - manager.workspace.custom_layout.min_right_width);
        var left_width = std.math.clamp(width * ratio, min_left, max_left);
        ratio = if (width > 0.0) left_width / width else ratio;
        const divider_width = @max(6.0, gap);
        const divider_rect = draw_context.Rect.fromMinSize(
            .{ content_rect.min[0] + left_width - divider_width * 0.5, content_rect.min[1] },
            .{ divider_width, content_rect.size()[1] },
        );
        const hovered = divider_rect.contains(queue.state.mouse_pos);
        if (hovered or win_state.custom_split_dragging) {
            cursor.set(.resize_ew);
        }
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left and hovered) {
                        win_state.custom_split_dragging = true;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) {
                        win_state.custom_split_dragging = false;
                    }
                },
                .focus_lost => {
                    win_state.custom_split_dragging = false;
                },
                else => {},
            }
        }
        if (win_state.custom_split_dragging) {
            const mouse_x = queue.state.mouse_pos[0];
            const clamped_left = std.math.clamp(mouse_x - content_rect.min[0], min_left, max_left);
            ratio = if (width > 0.0) clamped_left / width else ratio;
            left_width = clamped_left;
        }
        if (ratio != manager.workspace.custom_layout.left_ratio) {
            manager.workspace.custom_layout.left_ratio = ratio;
            manager.workspace.markDirty();
        }
    }

    var tree = custom_layout.LayoutTree{};
    tree.root = custom_layout.buildTwoColumnStacked(
        &tree,
        left_kind,
        right_buf[0..right_len],
        ratio,
        gap,
    );
    const layout_result = custom_layout.computeRects(&tree, content_rect);

    var focus_panel_id: ?workspace.PanelId = null;
    var close_panel_id: ?workspace.PanelId = null;
    var active_session_key: ?[]const u8 = null;
    var active_agent_id: ?[]const u8 = null;

    for (layout_result.slice()) |panel_slot| {
        if (selectPanelForKind(manager, panel_slot.kind)) |panel| {
            // Namespace controller-nav ids to the panel, so identical labels in different panels don't collide.
            nav_router.pushScope(panel.id);
            defer nav_router.popScope();

            const focused = if (manager.workspace.focused_panel_id) |id| id == panel.id else false;
            panel.state.is_focused = focused;
            const frame = drawPanelFrame(&dc, panel_slot.rect, panel.title, queue, focused);
            if (frame.clicked) {
                focus_panel_id = panel.id;
            }
            if (frame.close_clicked) {
                close_panel_id = panel.id;
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
            );
            if (panel.kind == .Chat and draw_result.session_key != null) {
                if (focused or active_session_key == null) {
                    active_session_key = draw_result.session_key;
                    active_agent_id = draw_result.agent_id;
                }
            }
        }
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

    drawCustomMenuBar(&dc, menu_rect, queue, manager, action, win_state);

    var agent_name: ?[]const u8 = null;
    var session_label: ?[]const u8 = null;
    var message_count: usize = 0;
    if (active_session_key) |session_key| {
        session_label = resolveSessionLabel(ctx.sessions.items, session_key);
        if (ctx.findSessionState(session_key)) |session_state| {
            message_count = session_state.messages.items.len;
        }
        const info = resolveAgentInfo(registry, active_agent_id);
        agent_name = info.name;
    }

    status_bar.drawCustom(
        &dc,
        status_rect,
        ctx.state,
        is_connected,
        agent_name,
        session_label,
        message_count,
        ctx.last_error,
    );

    drawControllerFocusOverlay(&dc, queue, host_rect);

    ui_systems.endFrame(&dc);
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
        widgets.focus_ring.draw(dc, it.rect, dc.theme.radius.sm);
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

    // Header chrome.
    dc.drawRect(header_rect, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
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
            ensureOnlyPanelKind(manager, .Control);
            if (selectPanelForKind(manager, .Control)) |panel| {
                panel.data.Control.active_tab = .Agents;
            }
            if (selectPanelForKind(manager, .Control)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment);
            }
            nav_router.popScope();
        },
        .settings => {
            nav_router.pushScope(3);
            ensureOnlyPanelKind(manager, .Control);
            if (selectPanelForKind(manager, .Control)) |panel| {
                panel.data.Control.active_tab = .Settings;
            }
            if (selectPanelForKind(manager, .Control)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment);
            }
            nav_router.popScope();
        },
        .chat => {
            nav_router.pushScope(4);
            ensureOnlyPanelKind(manager, .Chat);
            if (selectPanelForKind(manager, .Chat)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment);
            }
            nav_router.popScope();
        },
        .showcase => {
            nav_router.pushScope(5);
            ensureOnlyPanelKind(manager, .Showcase);
            if (selectPanelForKind(manager, .Showcase)) |panel| {
                _ = drawPanelContents(allocator, ctx, cfg, registry, is_connected, app_version, panel, content_main_rect, inbox, manager, action, pending_attachment);
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
    _ = drawHintPill(dc, .{ cursor_x, y }, pill_h, "LB/RB Tabs");
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
    const cols: usize = 2;
    const rows: usize = 2;
    const card_w = @max(1.0, (rect.size()[0] - gap * (@as(f32, @floatFromInt(cols - 1)))) / @as(f32, @floatFromInt(cols)));
    const card_h = @max(1.0, (rect.size()[1] - gap * (@as(f32, @floatFromInt(rows - 1)))) / @as(f32, @floatFromInt(rows)));

    const start_x = rect.min[0] + (rect.size()[0] - (card_w * @as(f32, @floatFromInt(cols)) + gap * @as(f32, @floatFromInt(cols - 1)))) * 0.5;
    const start_y = rect.min[1] + (rect.size()[1] - (card_h * @as(f32, @floatFromInt(rows)) + gap * @as(f32, @floatFromInt(rows - 1)))) * 0.5;

    const cards = [_]struct { label: []const u8, page: FullscreenPage }{
        .{ .label = "Agents", .page = .agents },
        .{ .label = "Settings", .page = .settings },
        .{ .label = "Chat", .page = .chat },
        .{ .label = "Showcase", .page = .showcase },
    };

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
) PanelDrawResult {
    var result: PanelDrawResult = .{};
    const zone = profiler.zone("ui.panel");
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
            const session_label = if (resolved_session_key) |session_key|
                resolveSessionLabel(ctx.sessions.items, session_key)
            else
                null;

            const session_state = if (resolved_session_key) |session_key|
                ctx.getOrCreateSessionState(session_key) catch null
            else
                null;

            const chat_action = chat_panel.draw(
                allocator,
                &panel.data.Chat,
                resolved_session_key,
                session_state,
                agent_info.icon,
                agent_info.name,
                session_label,
                inbox,
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
            );
            action.connect = control_action.connect;
            action.disconnect = control_action.disconnect;
            action.save_config = control_action.save_config;
            action.reload_theme_pack = control_action.reload_theme_pack;
            action.clear_saved = control_action.clear_saved;
            action.config_updated = control_action.config_updated;
            action.refresh_sessions = control_action.refresh_sessions;
            action.new_session = control_action.new_session;
            action.new_chat_agent_id = control_action.new_chat_agent_id;
            action.open_session = control_action.open_session;
            action.set_default_session = control_action.set_default_session;
            action.delete_session = control_action.delete_session;
            action.add_agent = control_action.add_agent;
            action.remove_agent_id = control_action.remove_agent_id;
            action.check_updates = control_action.check_updates;
            action.open_release = control_action.open_release;
            action.download_update = control_action.download_update;
            action.open_download = control_action.open_download;
            action.install_update = control_action.install_update;
            action.refresh_nodes = control_action.refresh_nodes;
            action.select_node = control_action.select_node;
            action.invoke_node = control_action.invoke_node;
            action.describe_node = control_action.describe_node;
            action.resolve_approval = control_action.resolve_approval;
            action.clear_node_describe = control_action.clear_node_describe;
            action.clear_node_result = control_action.clear_node_result;
            action.clear_operator_notice = control_action.clear_operator_notice;
            if (control_action.open_attachment) |attachment| {
                pending_attachment.* = attachment;
            }
            replaceOwnedSlice(allocator, &action.select_session, control_action.select_session);
            replaceOwnedSlice(allocator, &action.open_url, control_action.open_url);
        },
        .Showcase => {
            showcase_panel.draw(allocator, panel_rect);
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

fn resolveSessionLabel(sessions: []const types.Session, key: []const u8) ?[]const u8 {
    for (sessions) |session| {
        if (std.mem.eql(u8, session.key, key)) {
            return session.display_name orelse session.label orelse session.key;
        }
    }
    return null;
}

fn drawPanelFrame(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    title: []const u8,
    queue: *input_state.InputQueue,
    focused: bool,
) PanelFrameResult {
    const t = dc.theme;
    const size = rect.size();
    if (size[0] <= 0.0 or size[1] <= 0.0) {
        return .{
            .content_rect = rect,
            .close_clicked = false,
            .clicked = false,
        };
    }

    const title_height = dc.lineHeight();
    const pad_y = t.spacing.xs;
    const header_height = @min(size[1], title_height + pad_y * 2.0);
    const header_rect = draw_context.Rect.fromMinSize(rect.min, .{ size[0], header_height });

    const border_color = if (focused) t.colors.primary else t.colors.border;
    dc.drawRect(rect, .{ .fill = t.colors.background, .stroke = border_color, .thickness = 1.0 });
    dc.drawRect(header_rect, .{ .fill = t.colors.surface });

    const close_size = @min(header_height, @max(12.0, header_height - pad_y * 2.0));
    const close_rect = draw_context.Rect.fromMinSize(
        .{ rect.max[0] - t.spacing.xs - close_size, rect.min[1] + (header_height - close_size) * 0.5 },
        .{ close_size, close_size },
    );
    const close_clicked = widgets.button.draw(dc, close_rect, "x", queue, .{
        .variant = .ghost,
        .radius = t.radius.sm,
    });

    const title_x = rect.min[0] + t.spacing.sm;
    const title_y = rect.min[1] + (header_height - title_height) * 0.5;
    theme.pushFor(t, .title);
    dc.drawText(title, .{ title_x, title_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    const divider_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0], header_rect.max[1] - 1.0 },
        .{ rect.size()[0], 1.0 },
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

    const content_height = @max(0.0, size[1] - header_height);
    const content_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0], rect.min[1] + header_height },
        .{ size[0], content_height },
    );
    return .{
        .content_rect = content_rect,
        .close_clicked = close_clicked,
        .clicked = clicked,
    };
}

pub fn syncSettings(cfg: config.Config) void {
    @import("settings_view.zig").syncFromConfig(cfg);
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
