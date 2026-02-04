const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const components = @import("components/components.zig");
const sessions_panel = @import("panels/sessions_panel.zig");

pub const ProjectsViewAction = struct {
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

var selected_project_index: ?usize = null;
var search_buf: [128:0]u8 = [_:0]u8{0} ** 128;
var sidebar_collapsed = false;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext) ProjectsViewAction {
    var action = ProjectsViewAction{};
    const opened = zgui.beginChild("ProjectsView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        const header_open = components.layout.header_bar.begin(.{
            .title = "Projects Overview",
            .subtitle = "ZiggyStarClaw",
            .show_traffic_lights = true,
            .show_search = true,
            .search_buffer = search_buf[0.. :0],
            .show_notifications = true,
            .notification_count = ctx.approvals.items.len,
        });
        if (header_open) {
            if (components.core.button.draw("Refresh", .{ .variant = .secondary, .size = .small })) {
                action.refresh_sessions = true;
            }
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            if (components.core.button.draw("New Project", .{ .variant = .primary, .size = .small })) {
                action.new_session = true;
            }
        }
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

        const avail = zgui.getContentRegionAvail();
        const sidebar_width = @min(260.0, avail[0] * 0.3);

        if (components.layout.sidebar.begin(.{
            .id = "projects",
            .width = sidebar_width,
            .collapsible = true,
            .collapsed = &sidebar_collapsed,
            .collapsed_label = "Projects",
        })) {
            if (!sidebar_collapsed) {
                theme.push(.heading);
                zgui.text("My Projects", .{});
                theme.pop();
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });

                zgui.beginDisabled(.{ .disabled = ctx.sessions_loading });
                if (components.core.button.draw("+ New Project", .{ .variant = .primary, .size = .small })) {
                    action.new_session = true;
                }
                zgui.endDisabled();

                if (ctx.sessions_loading) {
                    zgui.sameLine(.{ .spacing = t.spacing.sm });
                    components.core.badge.draw("Loading", .{ .variant = .primary, .filled = false, .size = .small });
                }

                zgui.separator();
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
                if (components.layout.scroll_area.begin(.{ .id = "ProjectsList", .border = true })) {
                    if (ctx.sessions.items.len == 0) {
                        zgui.textDisabled("No projects available.", .{});
                    }
                    const active_index = resolveSelectedIndex(ctx);
                    for (ctx.sessions.items, 0..) |session, idx| {
                        const name = displayName(session);
                        const is_active = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key);
                        const selected = active_index != null and active_index.? == idx;
                        if (drawProjectRow(.{
                            .id = session.key,
                            .label = name,
                            .active = is_active,
                            .selected = selected,
                            .t = t,
                        })) {
                            selected_project_index = idx;
                            action.select_session = allocator.dupe(u8, session.key) catch null;
                        }
                    }
                }
                components.layout.scroll_area.end();
            }
        }
        components.layout.sidebar.end();

        zgui.sameLine(.{ .spacing = t.spacing.md });
        if (components.layout.scroll_area.begin(.{ .id = "ProjectsMain", .border = false })) {
            drawMainContent(allocator, ctx, t, &action);
        }
        components.layout.scroll_area.end();
    }
    zgui.endChild();
    return action;
}

fn drawMainContent(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    t: *const theme.Theme,
    action: *ProjectsViewAction,
) void {
    const selected_index = resolveSelectedIndex(ctx);
    if (selected_index == null) {
        zgui.textDisabled("Create or select a project to see details.", .{});
        return;
    }

    const session = ctx.sessions.items[selected_index.?];
    const messages = messagesForSession(ctx, session.key);
    var previews_buf: [12]sessions_panel.AttachmentOpen = undefined;
    const previews = collectAttachmentPreviews(messages, &previews_buf);
    var artifacts_buf: [6]components.composite.project_card.Artifact = undefined;
    const artifacts = previewsToArtifacts(previews, &artifacts_buf);
    theme.push(.title);
    zgui.text("Welcome back!", .{});
    theme.pop();
    zgui.textDisabled("Here's a snapshot of your active project workspace.", .{});
    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    var categories_buf: [3]components.composite.project_card.Category = undefined;
    var categories_len: usize = 0;
    if (session.kind) |kind| {
        categories_buf[categories_len] = .{ .name = kind, .variant = .primary };
        categories_len += 1;
    }
    if (ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key)) {
        categories_buf[categories_len] = .{ .name = "active", .variant = .success };
        categories_len += 1;
    }

    components.composite.project_card.draw(.{
        .id = "projects_active_card",
        .name = displayName(session),
        .description = session.label orelse session.kind,
        .categories = categories_buf[0..categories_len],
        .recent_artifacts = artifacts,
    });

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    if (components.layout.card.begin(.{ .title = "Categories", .id = "projects_categories" })) {
        const avail = zgui.getContentRegionAvail();
        const card_width = (avail[0] - t.spacing.sm) / 2.0;
        if (beginMiniCard("category_marketing", card_width, 86.0, t)) {
            theme.push(.heading);
            zgui.text("Marketing Analysis", .{});
            theme.pop();
            components.core.badge.draw("active", .{ .variant = .primary, .filled = false, .size = .small });
        }
        endMiniCard();
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (beginMiniCard("category_design", card_width, 86.0, t)) {
            theme.push(.heading);
            zgui.text("Design Concepts", .{});
            theme.pop();
            components.core.badge.draw("draft", .{ .variant = .neutral, .filled = false, .size = .small });
        }
        endMiniCard();
    }
    components.layout.card.end();

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    if (components.layout.card.begin(.{ .title = "Recent Artifacts", .id = "projects_artifacts" })) {
        if (previews.len == 0) {
            zgui.textDisabled("No artifacts generated yet.", .{});
        } else {
            for (previews, 0..) |preview, idx| {
                zgui.pushIntId(@intCast(idx));
                defer zgui.popId();
                components.composite.artifact_row.draw(.{
                    .name = preview.name,
                    .file_type = preview.kind,
                    .status = preview.role,
                });
                if (components.core.button.draw("Open in Editor", .{ .variant = .secondary, .size = .small })) {
                    action.open_attachment = preview;
                }
                if (isHttpUrl(preview.url)) {
                    zgui.sameLine(.{ .spacing = t.spacing.sm });
                    if (components.core.button.draw("Open URL", .{ .variant = .ghost, .size = .small })) {
                        action.open_url = allocator.dupe(u8, preview.url) catch null;
                    }
                }
                if (idx + 1 < previews.len) {
                    zgui.separator();
                }
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
            }
        }
    }
    components.layout.card.end();
}

const ProjectRowArgs = struct {
    id: []const u8,
    label: []const u8,
    active: bool,
    selected: bool,
    t: *const theme.Theme,
};

fn drawProjectRow(args: ProjectRowArgs) bool {
    const cursor_screen = zgui.getCursorScreenPos();
    const cursor_local = zgui.getCursorPos();
    const avail = zgui.getContentRegionAvail();
    const row_height = zgui.getFrameHeight() + args.t.spacing.xs;
    const id_z = zgui.formatZ("##project_row_{s}", .{args.id});

    _ = zgui.invisibleButton(id_z, .{ .w = avail[0], .h = row_height });
    const hovered = zgui.isItemHovered(.{});
    const clicked = zgui.isItemClicked(.left);

    const draw_list = zgui.getWindowDrawList();
    if (args.selected or hovered) {
        const base = if (args.selected) args.t.colors.primary else args.t.colors.surface;
        const alpha: f32 = if (args.selected) 0.12 else 0.08;
        draw_list.addRectFilled(.{
            .pmin = cursor_screen,
            .pmax = .{ cursor_screen[0] + avail[0], cursor_screen[1] + row_height },
            .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(base, alpha)),
            .rounding = args.t.radius.sm,
        });
    }

    const icon_size = row_height - args.t.spacing.xs * 2.0;
    const icon_pos = .{ cursor_screen[0] + args.t.spacing.xs, cursor_screen[1] + args.t.spacing.xs };
    draw_list.addRectFilled(.{
        .pmin = icon_pos,
        .pmax = .{ icon_pos[0] + icon_size, icon_pos[1] + icon_size },
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(args.t.colors.primary, 0.2)),
        .rounding = 3.0,
    });

    const text_pos = .{ icon_pos[0] + icon_size + args.t.spacing.sm, cursor_screen[1] + args.t.spacing.xs };
    draw_list.addText(text_pos, zgui.colorConvertFloat4ToU32(args.t.colors.text_primary), "{s}", .{args.label});

    if (args.active) {
        drawActiveBadge(draw_list, args.t, "active", cursor_screen, avail[0], row_height);
    }

    zgui.setCursorPos(.{ cursor_local[0], cursor_local[1] + row_height + args.t.spacing.xs });
    zgui.dummy(.{ .w = 0.0, .h = 0.0 });
    return clicked;
}

fn drawActiveBadge(
    draw_list: zgui.DrawList,
    t: *const theme.Theme,
    label: []const u8,
    row_pos: [2]f32,
    row_width: f32,
    row_height: f32,
) void {
    const label_size = zgui.calcTextSize(label, .{});
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const badge_size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const x = row_pos[0] + row_width - badge_size[0] - t.spacing.sm;
    const y = row_pos[1] + (row_height - badge_size[1]) * 0.5;
    const bg = colors.withAlpha(t.colors.success, 0.18);
    const border = colors.withAlpha(t.colors.success, 0.4);
    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + badge_size[0], y + badge_size[1] },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = t.radius.lg,
    });
    draw_list.addRect(.{
        .pmin = .{ x, y },
        .pmax = .{ x + badge_size[0], y + badge_size[1] },
        .col = zgui.colorConvertFloat4ToU32(border),
        .rounding = t.radius.lg,
    });
    draw_list.addText(
        .{ x + padding[0], y + padding[1] },
        zgui.colorConvertFloat4ToU32(t.colors.success),
        "{s}",
        .{label},
    );
}

fn beginMiniCard(id: []const u8, width: f32, height: f32, t: *const theme.Theme) bool {
    const label_z = zgui.formatZ("##mini_{s}", .{id});
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ t.spacing.sm, t.spacing.sm } });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = t.radius.md });
    zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = 1.0 });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = t.colors.surface });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = t.colors.border });
    return zgui.beginChild(label_z, .{ .w = width, .h = height, .child_flags = .{ .border = true } });
}

fn endMiniCard() void {
    zgui.endChild();
    zgui.popStyleColor(.{ .count = 2 });
    zgui.popStyleVar(.{ .count = 3 });
}

fn resolveSelectedIndex(ctx: *state.ClientContext) ?usize {
    if (ctx.sessions.items.len == 0) {
        selected_project_index = null;
        return null;
    }
    if (selected_project_index) |idx| {
        if (idx < ctx.sessions.items.len) return idx;
        selected_project_index = null;
    }
    if (ctx.current_session) |key| {
        if (findSessionIndex(ctx.sessions.items, key)) |index| {
            selected_project_index = index;
            return index;
        }
    }
    selected_project_index = 0;
    return 0;
}

fn findSessionIndex(sessions: []const types.Session, key: []const u8) ?usize {
    for (sessions, 0..) |session, idx| {
        if (std.mem.eql(u8, session.key, key)) return idx;
    }
    return null;
}

fn messagesForSession(ctx: *state.ClientContext, session_key: []const u8) []const types.ChatMessage {
    if (ctx.findSessionState(session_key)) |session_state| {
        return session_state.messages.items;
    }
    return &[_]types.ChatMessage{};
}

fn displayName(session: types.Session) []const u8 {
    return session.display_name orelse session.label orelse session.key;
}

fn previewsToArtifacts(
    previews: []const sessions_panel.AttachmentOpen,
    buf: []components.composite.project_card.Artifact,
) []components.composite.project_card.Artifact {
    const count = @min(previews.len, buf.len);
    for (previews[0..count], 0..) |preview, idx| {
        buf[idx] = .{
            .name = preview.name,
            .file_type = preview.kind,
            .status = preview.role,
        };
    }
    return buf[0..count];
}

fn collectAttachmentPreviews(
    messages: []const types.ChatMessage,
    buf: []sessions_panel.AttachmentOpen,
) []sessions_panel.AttachmentOpen {
    var len: usize = 0;
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message = messages[index - 1];
        if (message.attachments) |attachments| {
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{
                    .name = name,
                    .kind = attachment.kind,
                    .url = attachment.url,
                    .role = message.role,
                    .timestamp = message.timestamp,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}
