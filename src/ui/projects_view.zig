const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
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

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext) ProjectsViewAction {
    var action = ProjectsViewAction{};
    const opened = zgui.beginChild("ProjectsView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        if (components.layout.header_bar.begin(.{
            .title = "Projects Overview",
            .subtitle = "ZiggyStarClaw",
            .show_traffic_lights = true,
            .show_search = true,
            .search_buffer = search_buf[0.. :0],
            .show_notifications = true,
            .notification_count = ctx.approvals.items.len,
        })) {
            if (components.core.button.draw("Refresh", .{ .variant = .secondary, .size = .small })) {
                action.refresh_sessions = true;
            }
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            if (components.core.button.draw("New Project", .{ .variant = .primary, .size = .small })) {
                action.new_session = true;
            }
            components.layout.header_bar.end();
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

        const avail = zgui.getContentRegionAvail();
        const sidebar_width = @min(260.0, avail[0] * 0.3);

        if (components.layout.sidebar.begin(.{ .id = "projects", .width = sidebar_width })) {
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
                    zgui.pushIntId(@intCast(idx));
                    defer zgui.popId();
                    const name = displayName(session);
                    const is_active = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key);
                    var label_buf: [256]u8 = undefined;
                    const label = if (is_active)
                        std.fmt.bufPrint(&label_buf, "{s} (active)", .{name}) catch name
                    else
                        name;
                    const selected = active_index != null and active_index.? == idx;
                    if (components.data.list_item.draw(.{
                        .label = label,
                        .selected = selected,
                        .id = session.key,
                    })) {
                        selected_project_index = idx;
                        action.select_session = allocator.dupe(u8, session.key) catch null;
                    }
                }
            }
            components.layout.scroll_area.end();
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
    var previews_buf: [12]sessions_panel.AttachmentOpen = undefined;
    const previews = collectAttachmentPreviews(ctx.messages.items, &previews_buf);
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
        zgui.text("Marketing Analysis", .{});
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        components.core.badge.draw("active", .{ .variant = .primary, .filled = false, .size = .small });
        zgui.text("Design Concepts", .{});
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        components.core.badge.draw("draft", .{ .variant = .neutral, .filled = false, .size = .small });
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
