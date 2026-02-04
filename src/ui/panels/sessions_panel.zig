const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const types = @import("../../protocol/types.zig");
const components = @import("../components/components.zig");
const session_list = @import("../session_list.zig");
const theme = @import("../theme.zig");
const markdown_basic = @import("../markdown_basic.zig");
const image_cache = @import("../image_cache.zig");
const data_uri = @import("../data_uri.zig");
const attachment_cache = @import("../attachment_cache.zig");

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
    open_url: ?[]u8 = null,
};

var split_state = components.layout.split_pane.SplitState{ .size = 260.0 };
var selected_file_index: ?usize = null;
const attachment_preview_limit: usize = 256 * 1024;
const text_preview_limit: usize = 12 * 1024;
const json_preview_limit: usize = 32 * 1024;
const log_preview_lines: usize = 80;

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
    const messages = messagesForSession(ctx, session.key);

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
    const artifacts = collectArtifacts(messages, &artifacts_buf);

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
    const files = collectFiles(messages, &files_buf);
    var previews_buf: [12]AttachmentOpen = undefined;
    const previews = collectAttachmentPreviews(messages, &previews_buf);

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
            drawAttachmentPreview(allocator, preview, t);
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
            if (components.core.button.draw("Open in Editor", .{ .variant = .secondary, .size = .small })) {
                action.open_attachment = preview;
            }
            if (isHttpUrl(preview.url)) {
                zgui.sameLine(.{ .spacing = t.spacing.sm });
                if (components.core.button.draw("Open URL", .{ .variant = .secondary, .size = .small })) {
                    action.open_url = allocator.dupe(u8, preview.url) catch null;
                }
                zgui.sameLine(.{ .spacing = t.spacing.xs });
                if (components.core.button.draw("Copy URL", .{ .variant = .ghost, .size = .small })) {
                    const url_z = zgui.formatZ("{s}", .{preview.url});
                    zgui.setClipboardText(url_z);
                }
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

fn messagesForSession(ctx: *state.ClientContext, session_key: []const u8) []const types.ChatMessage {
    if (ctx.findSessionState(session_key)) |session_state| {
        return session_state.messages.items;
    }
    return &[_]types.ChatMessage{};
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

fn drawAttachmentPreview(
    allocator: std.mem.Allocator,
    preview: AttachmentOpen,
    t: *const theme.Theme,
) void {
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

    var content: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var size_bytes: ?usize = null;
    var truncated = false;

    if (std.mem.startsWith(u8, preview.url, "data:")) {
        if (preview.url.len > attachment_preview_limit) {
            status = "Data attachment too large to preview.";
        } else if (data_uri.decodeDataUriBytes(allocator, preview.url)) |bytes| {
            defer allocator.free(bytes);
            size_bytes = bytes.len;
            if (!std.unicode.utf8ValidateSlice(bytes)) {
                status = "Binary data attachment.";
            } else {
                const trimmed = trimPreview(bytes, text_preview_limit);
                content = trimmed.body;
                truncated = trimmed.truncated;
            }
        } else |_| {
            status = "Failed to decode attachment.";
        }
    } else if (isHttpUrl(preview.url)) {
        attachment_cache.request(preview.url, attachment_preview_limit);
        if (attachment_cache.get(preview.url)) |entry| {
            switch (entry.state) {
                .loading => status = "Fetching remote attachment...",
                .failed => {
                    status = if (entry.error_message) |err| err else "Attachment fetch failed.";
                },
                .ready => if (entry.data) |data| {
                    size_bytes = data.len;
                    const trimmed = trimPreview(data, text_preview_limit);
                    content = trimmed.body;
                    truncated = trimmed.truncated;
                } else {
                    status = "Attachment content unavailable.";
                },
            }
        } else {
            status = "Fetching remote attachment...";
        }
    }

    drawPreviewMeta(t, status, size_bytes, truncated);

    if (content) |body| {
        const format = detectPreviewFormat(preview, body);
        var display = body;
        var owns_display = false;
        if (format == .json and body.len <= json_preview_limit) {
            if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
                defer parsed.deinit();
                if (std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 })) |pretty| {
                    display = pretty;
                    owns_display = true;
                } else |_| {}
            } else |_| {}
        }
        defer if (owns_display) allocator.free(display);

        var format_buf: [32]u8 = undefined;
        const format_label = switch (format) {
            .json => "json",
            .markdown => "markdown",
            .log => "log",
            .text => "text",
        };
        const format_text = if (owns_display and format == .json)
            std.fmt.bufPrint(&format_buf, "Format: {s} (formatted)", .{format_label}) catch "Format: json"
        else
            std.fmt.bufPrint(&format_buf, "Format: {s}", .{format_label}) catch "Format: text";
        zgui.textDisabled("{s}", .{format_text});
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (components.core.button.draw("Copy Preview", .{ .variant = .ghost, .size = .small })) {
            const copy_z = zgui.formatZ("{s}", .{display});
            zgui.setClipboardText(copy_z);
        }
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        drawTextPreview(preview, display, format, t);
        return;
    }

    if (status == null) {
        zgui.textDisabled("Preview unavailable.", .{});
    }
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

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
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

fn isJsonAttachment(att: AttachmentOpen, body: ?[]const u8) bool {
    if (hasTokenIgnoreCase(att.kind, "json")) return true;
    if (endsWithIgnoreCase(att.url, ".json") or endsWithIgnoreCase(att.url, ".jsonl")) return true;
    if (body) |data| {
        const trimmed = std.mem.trimLeft(u8, data, " \t\r\n");
        if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return true;
    }
    return false;
}

fn isMarkdownAttachment(att: AttachmentOpen, body: ?[]const u8) bool {
    if (hasTokenIgnoreCase(att.kind, "markdown")) return true;
    if (endsWithIgnoreCase(att.url, ".md") or endsWithIgnoreCase(att.url, ".markdown")) return true;
    if (body) |data| {
        return std.mem.indexOf(u8, data, "\n#") != null or std.mem.startsWith(u8, data, "#");
    }
    return false;
}

fn isLogAttachment(att: AttachmentOpen) bool {
    if (hasTokenIgnoreCase(att.kind, "log")) return true;
    if (endsWithIgnoreCase(att.url, ".log")) return true;
    return false;
}

const PreviewFormat = enum {
    json,
    markdown,
    log,
    text,
};

fn detectPreviewFormat(att: AttachmentOpen, body: []const u8) PreviewFormat {
    if (isJsonAttachment(att, body)) return .json;
    if (isMarkdownAttachment(att, body)) return .markdown;
    if (isLogAttachment(att)) return .log;
    return .text;
}

fn trimPreview(data: []const u8, max_len: usize) struct { body: []const u8, truncated: bool } {
    if (data.len <= max_len) return .{ .body = data, .truncated = false };
    return .{ .body = data[0..max_len], .truncated = true };
}

fn drawPreviewMeta(
    t: *const theme.Theme,
    status: ?[]const u8,
    size_bytes: ?usize,
    truncated: bool,
) void {
    if (status) |note| {
        zgui.textDisabled("{s}", .{note});
    }
    if (size_bytes) |size| {
        zgui.textDisabled("Size: {d} bytes", .{size});
    }
    if (truncated) {
        zgui.textDisabled("Preview truncated.", .{});
    }
    if (status != null or size_bytes != null or truncated) {
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
    }
}

fn drawTextPreview(
    preview: AttachmentOpen,
    body: []const u8,
    format: PreviewFormat,
    t: *const theme.Theme,
) void {
    const preview_id = zgui.formatZ("##attachment_preview_{s}", .{preview.name});
    const preview_height: f32 = 180.0;
    if (zgui.beginChild(preview_id, .{ .h = preview_height, .child_flags = .{ .border = true } })) {
        switch (format) {
            .markdown => {
                drawMarkdownPreview(body, t);
            },
            .log => {
                drawLogPreview(body);
            },
            else => {
                zgui.textWrapped("{s}", .{body});
            },
        }
    }
    zgui.endChild();
}

fn drawMarkdownPreview(text: []const u8, t: *const theme.Theme) void {
    _ = t;
    markdown_basic.draw(.{ .text = text, .max_lines = log_preview_lines });
}

fn drawLogPreview(text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    while (it.next()) |line| {
        if (line_count >= log_preview_lines) break;
        if (hasTokenIgnoreCase(line, "error")) {
            zgui.textColored(.{ 0.9, 0.3, 0.3, 1.0 }, "{s}", .{line});
        } else if (hasTokenIgnoreCase(line, "warn")) {
            zgui.textColored(.{ 0.9, 0.6, 0.2, 1.0 }, "{s}", .{line});
        } else if (hasTokenIgnoreCase(line, "info")) {
            zgui.textColored(.{ 0.4, 0.7, 0.9, 1.0 }, "{s}", .{line});
        } else {
            zgui.text("{s}", .{line});
        }
        line_count += 1;
    }
    if (line_count >= log_preview_lines) {
        zgui.textDisabled("Preview truncated.", .{});
    }
}
