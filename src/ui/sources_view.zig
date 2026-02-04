const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");
const sessions_panel = @import("panels/sessions_panel.zig");

pub const SourcesViewAction = struct {
    select_session: ?[]u8 = null,
    open_attachment: ?sessions_panel.AttachmentOpen = null,
    open_url: ?[]u8 = null,
};

var selected_source_index: ?usize = null;
var selected_file_index: ?usize = null;
var split_state = components.layout.split_pane.SplitState{ .size = 240.0 };
var search_buf: [128:0]u8 = [_:0]u8{0} ** 128;
var expand_research = true;
var expand_drive = true;
var expand_repo = true;

pub fn draw(allocator: std.mem.Allocator, ctx: *state.ClientContext) SourcesViewAction {
    var action = SourcesViewAction{};
    const opened = zgui.beginChild("SourcesView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        const header_open = components.layout.header_bar.begin(.{
            .title = "Sources",
            .subtitle = "Indexed Content",
            .show_search = true,
            .search_buffer = search_buf[0.. :0],
            .show_notifications = true,
            .notification_count = ctx.approvals.items.len,
        });
        if (header_open) {
            if (components.core.button.draw("Add Source", .{ .variant = .secondary, .size = .small })) {
                // Placeholder for future action.
            }
        }
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        var sources_buf: [24]components.composite.source_browser.Source = undefined;
        var sources_map: [24]?usize = undefined;
        var sources_len: usize = 0;

        addSource(&sources_buf, &sources_map, &sources_len, .{
            .name = "Local Files",
            .source_type = .local,
            .connected = true,
        }, null);

        for (ctx.sessions.items, 0..) |session, idx| {
            if (sources_len >= sources_buf.len) break;
            const name = displayName(session);
            addSource(&sources_buf, &sources_map, &sources_len, .{
                .name = name,
                .source_type = .local,
                .connected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, session.key),
            }, idx);
        }

        addSource(&sources_buf, &sources_map, &sources_len, .{
            .name = "Cloud Drives",
            .source_type = .cloud,
            .connected = false,
        }, null);
        addSource(&sources_buf, &sources_map, &sources_len, .{
            .name = "Code Repos",
            .source_type = .git,
            .connected = false,
        }, null);

        const active_index = resolveSelectedIndex(ctx, sources_map[0..sources_len]);

        var files_buf: [16]components.composite.source_browser.FileEntry = undefined;
        var fallback = fallbackFiles();
        const messages = messagesForActiveSession(ctx, active_index, sources_map[0..sources_len]);
        var files = collectFiles(messages, &files_buf);
        var previews_buf: [16]sessions_panel.AttachmentOpen = undefined;
        var previews = collectAttachmentPreviews(messages, &previews_buf);
        var sections_buf: [3]components.composite.source_browser.Section = undefined;
        var sections_len: usize = 0;
        if (active_index == null or sources_map[active_index.?] == null) {
            files = fallback[0..];
            previews = &[_]sessions_panel.AttachmentOpen{};
        } else {
            sections_len = buildSections(files, &sections_buf);
        }

        const current_path = if (active_index != null) blk: {
            if (sources_map[active_index.?]) |session_index| {
                break :blk ctx.sessions.items[session_index].key;
            }
            break :blk sources_buf[active_index.?].name;
        } else "";

        const source_action = components.composite.source_browser.draw(.{
            .id = "sources_browser",
            .sources = sources_buf[0..sources_len],
            .selected_source = active_index,
            .current_path = current_path,
            .files = files,
            .selected_file = selected_file_index,
            .sections = sections_buf[0..sections_len],
            .split_state = &split_state,
            .show_add_source = true,
        });

        if (source_action.select_source) |idx| {
            if (idx < sources_len) {
                selected_source_index = idx;
                selected_file_index = null;
                if (sources_map[idx]) |session_index| {
                    const session_key = ctx.sessions.items[session_index].key;
                    action.select_session = allocator.dupe(u8, session_key) catch null;
                }
            }
        }

        if (source_action.select_file) |idx| {
            selected_file_index = idx;
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
        if (components.layout.card.begin(.{ .title = "Selected File", .id = "sources_selected_file" })) {
            if (selected_file_index == null or selected_file_index.? >= previews.len) {
                zgui.textDisabled("Select a file to see details and actions.", .{});
            } else {
                const preview = previews[selected_file_index.?];
                zgui.textWrapped("Name: {s}", .{preview.name});
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
                zgui.textWrapped("Type: {s}", .{preview.kind});
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
                zgui.textWrapped("Role: {s}", .{preview.role});
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
                if (components.core.button.draw("Open in Editor", .{ .variant = .secondary, .size = .small })) {
                    action.open_attachment = preview;
                }
                if (isHttpUrl(preview.url)) {
                    zgui.sameLine(.{ .spacing = t.spacing.sm });
                    if (components.core.button.draw("Open URL", .{ .variant = .ghost, .size = .small })) {
                        action.open_url = allocator.dupe(u8, preview.url) catch null;
                    }
                }
            }
        }
        components.layout.card.end();
    }
    zgui.endChild();
    return action;
}

fn buildSections(
    files: []const components.composite.source_browser.FileEntry,
    buf: []components.composite.source_browser.Section,
) usize {
    if (files.len == 0 or buf.len < 3) return 0;
    const first_count = @min(files.len, 3);
    const second_count = if (files.len > first_count) @min(files.len - first_count, 3) else 0;
    const third_count = if (files.len > first_count + second_count)
        files.len - first_count - second_count
    else
        0;
    var len: usize = 0;
    if (first_count > 0) {
        buf[len] = .{
            .name = "Research Docs",
            .files = files[0..first_count],
            .start_index = 0,
            .expanded = &expand_research,
        };
        len += 1;
    }
    if (second_count > 0) {
        const start = first_count;
        buf[len] = .{
            .name = "Google Drive Team",
            .files = files[start .. start + second_count],
            .start_index = start,
            .expanded = &expand_drive,
        };
        len += 1;
    }
    if (third_count > 0) {
        const start = first_count + second_count;
        buf[len] = .{
            .name = "GitHub Repo",
            .files = files[start .. start + third_count],
            .start_index = start,
            .expanded = &expand_repo,
        };
        len += 1;
    }
    return len;
}

fn addSource(
    buf: []components.composite.source_browser.Source,
    map: []?usize,
    len: *usize,
    source: components.composite.source_browser.Source,
    session_index: ?usize,
) void {
    if (len.* >= buf.len) return;
    buf[len.*] = source;
    map[len.*] = session_index;
    len.* += 1;
}

fn resolveSelectedIndex(ctx: *state.ClientContext, map: []?usize) ?usize {
    if (map.len == 0) {
        selected_source_index = null;
        return null;
    }
    if (selected_source_index) |idx| {
        if (idx < map.len) return idx;
        selected_source_index = null;
    }
    if (ctx.current_session) |key| {
        for (map, 0..) |session_idx, idx| {
            if (session_idx) |value| {
                if (std.mem.eql(u8, ctx.sessions.items[value].key, key)) {
                    selected_source_index = idx;
                    return idx;
                }
            }
        }
    }
    selected_source_index = 0;
    return 0;
}

fn messagesForActiveSession(
    ctx: *state.ClientContext,
    active_index: ?usize,
    map: []?usize,
) []const types.ChatMessage {
    if (active_index) |idx| {
        if (idx < map.len) {
            if (map[idx]) |session_index| {
                const session_key = ctx.sessions.items[session_index].key;
                if (ctx.findSessionState(session_key)) |session_state| {
                    return session_state.messages.items;
                }
            }
        }
    }
    return &[_]types.ChatMessage{};
}

fn displayName(session: types.Session) []const u8 {
    return session.display_name orelse session.label orelse session.key;
}

fn collectFiles(
    messages: []const types.ChatMessage,
    buf: []components.composite.source_browser.FileEntry,
) []components.composite.source_browser.FileEntry {
    var len: usize = 0;
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message = messages[index - 1];
        if (message.attachments) |attachments| {
            const status = statusForRole(message.role);
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{
                    .name = name,
                    .language = attachment.kind,
                    .status = status,
                    .dirty = false,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn statusForRole(role: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "tool")) {
        return "indexed";
    }
    if (std.ascii.eqlIgnoreCase(role, "user")) {
        return "pending";
    }
    return "indexed";
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

fn fallbackFiles() [4]components.composite.source_browser.FileEntry {
    return .{
        .{ .name = "proposal.docx", .language = "docx", .status = "indexed" },
        .{ .name = "data.csv", .language = "csv", .status = "indexed" },
        .{ .name = "image.png", .language = "png", .status = "pending" },
        .{ .name = "notes.md", .language = "md", .status = "indexed" },
    };
}
