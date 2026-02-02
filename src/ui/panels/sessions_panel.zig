const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");
const components = @import("../components/components.zig");
const session_list = @import("../session_list.zig");
const theme = @import("../theme.zig");
const image_cache = @import("../image_cache.zig");
const data_uri = @import("../data_uri.zig");

pub const AttachmentOpen = struct {
    name: []const u8,
    kind: []const u8,
    url: []const u8,
    role: []const u8,
    timestamp: i64,
};

pub const SessionPanelAction = struct {
    refresh: bool = false,
    new_session: bool = false,
    selected_key: ?[]u8 = null,
    open_attachment: ?AttachmentOpen = null,
};

var split_state = components.layout.split_pane.SplitState{ .size = 260.0 };
var selected_file_index: ?usize = null;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
) SessionPanelAction {
    var action = SessionPanelAction{};
    const t = theme.activeTheme();
    const avail = zgui.getContentRegionAvail();
    if (split_state.size == 0.0) {
        split_state.size = @min(280.0, avail[0] * 0.35);
    }

    const split_args = components.layout.split_pane.Args{
        .id = "sessions_panel",
        .axis = .vertical,
        .primary_size = split_state.size,
        .min_primary = 220.0,
        .min_secondary = 260.0,
        .border = false,
        .padded = false,
    };

    components.layout.split_pane.begin(split_args, &split_state);
    if (components.layout.split_pane.beginPrimary(split_args, &split_state)) {
        const list_action = session_list.draw(
            allocator,
            ctx.sessions.items,
            ctx.current_session,
            ctx.sessions_loading,
        );
        action.refresh = list_action.refresh;
        action.new_session = list_action.new_session;
        action.selected_key = list_action.selected_key;
        if (action.selected_key != null) {
            selected_file_index = null;
        }
    }
    components.layout.split_pane.endPrimary();
    components.layout.split_pane.handleSplitter(split_args, &split_state);
    if (components.layout.split_pane.beginSecondary(split_args, &split_state)) {
        if (components.layout.scroll_area.begin(.{ .id = "SessionDetails", .border = false })) {
            drawSessionDetails(allocator, ctx, t, &action);
        }
        components.layout.scroll_area.end();
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();

    return action;
}

fn drawSessionDetails(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    t: *const theme.Theme,
    action: *SessionPanelAction,
) void {
    const selected_index = resolveSelectedSessionIndex(ctx);
    if (selected_index == null) {
        zgui.textDisabled("Select a session to see details.", .{});
        return;
    }

    const session = ctx.sessions.items[selected_index.?];
    const name = displayName(session);
    const description = session.label orelse session.kind;

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

    var artifacts_buf: [6]components.composite.project_card.Artifact = undefined;
    const artifacts = collectArtifacts(ctx.messages.items, &artifacts_buf);

    components.composite.project_card.draw(.{
        .id = "session_project_card",
        .name = name,
        .description = description,
        .categories = categories_buf[0..categories_len],
        .recent_artifacts = artifacts,
    });

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    var sources_buf: [16]components.composite.source_browser.Source = undefined;
    var source_map: [16]usize = undefined;
    var sources_len: usize = 0;
    var selected_source: ?usize = null;
    for (ctx.sessions.items, 0..) |entry, idx| {
        if (sources_len >= sources_buf.len) break;
        sources_buf[sources_len] = .{
            .name = displayName(entry),
            .source_type = .local,
            .connected = ctx.current_session != null and std.mem.eql(u8, ctx.current_session.?, entry.key),
        };
        source_map[sources_len] = idx;
        if (selected_index.? == idx) {
            selected_source = sources_len;
        }
        sources_len += 1;
    }
    if (selected_source == null and sources_len > 0) {
        selected_source = 0;
    }

    var files_buf: [12]components.composite.source_browser.FileEntry = undefined;
    const files = collectFiles(ctx.messages.items, &files_buf);
    var previews_buf: [12]AttachmentOpen = undefined;
    const previews = collectAttachmentPreviews(ctx.messages.items, &previews_buf);

    const source_action = components.composite.source_browser.draw(.{
        .id = "session_source_browser",
        .sources = sources_buf[0..sources_len],
        .selected_source = selected_source,
        .current_path = session.key,
        .files = files,
        .selected_file = selected_file_index,
    });
    if (source_action.select_source) |src_index| {
        if (src_index < sources_len) {
            const session_index = source_map[src_index];
            action.selected_key = allocator.dupe(u8, ctx.sessions.items[session_index].key) catch null;
            selected_file_index = null;
        }
    }
    if (source_action.select_file) |file_index| {
        if (file_index < files.len) {
            selected_file_index = file_index;
        }
    }

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
    if (components.layout.card.begin(.{ .title = "Attachment Preview", .id = "attachment_preview" })) {
        if (selected_file_index == null or selected_file_index.? >= previews.len) {
            zgui.textDisabled("Select a file to preview its details.", .{});
        } else {
            const preview = previews[selected_file_index.?];
            zgui.textWrapped("Name: {s}", .{preview.name});
            zgui.textWrapped("Type: {s}", .{preview.kind});
            zgui.textWrapped("Source: {s}", .{preview.url});
            zgui.textWrapped("Role: {s}", .{preview.role});
            zgui.textWrapped("Timestamp: {d}", .{preview.timestamp});
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            drawAttachmentPreview(allocator, preview);
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            if (components.core.button.draw("Open in Editor", .{ .variant = .secondary, .size = .small })) {
                action.open_attachment = preview;
            }
        }
    }
    components.layout.card.end();
}

fn resolveSelectedSessionIndex(ctx: *state.ClientContext) ?usize {
    if (ctx.sessions.items.len == 0) return null;
    if (ctx.current_session) |key| {
        if (findSessionIndex(ctx.sessions.items, key)) |index| return index;
    }
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

fn collectArtifacts(
    messages: []const types.ChatMessage,
    buf: []components.composite.project_card.Artifact,
) []components.composite.project_card.Artifact {
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
                    .file_type = attachment.kind,
                    .status = message.role,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
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
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                const name = attachment.name orelse attachment.url;
                buf[len] = .{
                    .name = name,
                    .language = attachment.kind,
                    .status = message.role,
                    .dirty = false,
                };
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn collectAttachmentPreviews(
    messages: []const types.ChatMessage,
    buf: []AttachmentOpen,
) []AttachmentOpen {
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

fn drawAttachmentPreview(allocator: std.mem.Allocator, preview: AttachmentOpen) void {
    if (isImageAttachment(preview)) {
        if (preview.url.len == 0) {
            zgui.textDisabled("Image preview unavailable.", .{});
            return;
        }
        image_cache.request(preview.url);
        const avail = zgui.getContentRegionAvail();
        const max_width = @max(160.0, @min(360.0, avail[0]));
        const max_height: f32 = 220.0;
        if (image_cache.get(preview.url)) |entry| {
            switch (entry.state) {
                .ready => {
                    const tex_id: zgui.TextureIdent = @enumFromInt(@as(u64, entry.texture_id));
                    const tex_ref = zgui.TextureRef{ .tex_data = null, .tex_id = tex_id };
                    const w = @as(f32, @floatFromInt(entry.width));
                    const h = @as(f32, @floatFromInt(entry.height));
                    const aspect = if (h > 0) w / h else 1.0;
                    var draw_w = @min(max_width, w);
                    var draw_h = draw_w / aspect;
                    if (draw_h > max_height) {
                        draw_h = max_height;
                        draw_w = draw_h * aspect;
                    }
                    zgui.image(tex_ref, .{ .w = draw_w, .h = draw_h });
                },
                .loading => {
                    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Loading image preview...", .{});
                    zgui.dummy(.{ .w = max_width, .h = 120.0 });
                },
                .failed => {
                    zgui.textColored(.{ 0.9, 0.4, 0.4, 1.0 }, "Image failed to load", .{});
                    if (entry.error_message) |err| {
                        zgui.sameLine(.{});
                        zgui.textDisabled("{s}", .{err});
                    }
                },
            }
        } else {
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Loading image preview...", .{});
            zgui.dummy(.{ .w = max_width, .h = 120.0 });
        }
        return;
    }

    if (std.mem.startsWith(u8, preview.url, "data:")) {
        const max_uri_len: usize = 256 * 1024;
        if (preview.url.len > max_uri_len) {
            zgui.textDisabled("Data attachment too large to preview.", .{});
            return;
        }
        if (data_uri.decodeDataUriBytes(allocator, preview.url)) |bytes| {
            defer allocator.free(bytes);
            if (!std.unicode.utf8ValidateSlice(bytes)) {
                zgui.textDisabled("Binary data attachment.", .{});
                return;
            }
            const max_preview: usize = 320;
            const preview_len = @min(bytes.len, max_preview);
            zgui.textWrapped("{s}", .{bytes[0..preview_len]});
            if (bytes.len > preview_len) {
                zgui.textDisabled("Preview truncated.", .{});
            }
            return;
        } else |_| {}
    }

    zgui.textDisabled("Preview unavailable.", .{});
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

fn isImageAttachment(att: AttachmentOpen) bool {
    if (std.mem.indexOf(u8, att.kind, "image") != null) return true;
    if (std.mem.startsWith(u8, att.url, "data:image/")) return true;
    return endsWithIgnoreCase(att.url, ".png") or
        endsWithIgnoreCase(att.url, ".jpg") or
        endsWithIgnoreCase(att.url, ".jpeg") or
        endsWithIgnoreCase(att.url, ".gif") or
        endsWithIgnoreCase(att.url, ".webp");
}
