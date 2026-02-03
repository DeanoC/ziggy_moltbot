const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const theme = @import("theme.zig");
const panel_manager = @import("panel_manager.zig");
const text_buffer = @import("text_buffer.zig");
const workspace = @import("workspace.zig");
const data_uri = @import("data_uri.zig");
const attachment_cache = @import("attachment_cache.zig");
const dock_layout = @import("dock_layout.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const imgui_bridge = @import("imgui_bridge.zig");
const image_cache = @import("image_cache.zig");
const chat_panel = @import("panels/chat_panel.zig");
const code_editor_panel = @import("panels/code_editor_panel.zig");
const tool_output_panel = @import("panels/tool_output_panel.zig");
const control_panel = @import("panels/control_panel.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const status_bar = @import("status_bar.zig");

pub const UiAction = struct {
    send_message: ?[]u8 = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    new_session: bool = false,
    select_session: ?[]u8 = null,
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

var safe_insets: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
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
    is_connected: bool,
    app_version: []const u8,
    manager: *panel_manager.PanelManager,
    inbox: *ui_command_inbox.UiCommandInbox,
    dock_state: *dock_layout.DockState,
) UiAction {
    var action = UiAction{};
    var pending_attachment: ?sessions_panel.AttachmentOpen = null;
    image_cache.beginFrame();

    inbox.collectFromMessages(allocator, ctx.messages.items, manager);

    var menu_height: f32 = 0.0;
    const t = theme.activeTheme();
    const status_padding_y = t.spacing.xs;
    const status_height = zgui.getFrameHeightWithSpacing() + status_padding_y * 2.0;
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ t.spacing.sm, t.spacing.xs } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ t.spacing.sm, t.spacing.xs } });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ t.spacing.sm, t.spacing.xs } });
    if (zgui.beginMainMenuBar()) {
        if (zgui.beginMenu("Window", true)) {
            const has_control = manager.hasPanel(.Control);
            const has_chat = manager.hasPanel(.Chat);
            const has_tool = manager.hasPanel(.ToolOutput);
            const has_editor = manager.hasPanel(.CodeEditor);

            if (zgui.menuItem("Workspace", .{ .selected = has_control })) {
                manager.ensurePanel(.Control);
            }
            if (zgui.menuItem("Chat", .{ .selected = has_chat })) {
                manager.ensurePanel(.Chat);
            }
            if (zgui.menuItem("Tool Output", .{ .selected = has_tool })) {
                manager.ensurePanel(.ToolOutput);
            }
            if (zgui.menuItem("Code Editor", .{ .selected = has_editor })) {
                manager.ensurePanel(.CodeEditor);
            }
            zgui.separator();
            if (zgui.menuItem("Reset Layout", .{})) {
                dock_layout.resetDockLayout(allocator, dock_state, &manager.workspace);
            }
            zgui.endMenu();
        }
        menu_height = zgui.getWindowSize()[1];
        zgui.endMainMenuBar();
    }
    zgui.popStyleVar(.{ .count = 3 });

    const display = zgui.io.getDisplaySize();
    if (display[0] > 0.0 and display[1] > 0.0) {
        const left = safe_insets[0];
        const top = safe_insets[1] + menu_height;
        const right = safe_insets[2];
        const bottom = safe_insets[3];
        const width = @max(1.0, display[0] - left - right);
        const extra_bottom: f32 = if (builtin.abi == .android) 24.0 else 0.0;
        const height = @max(1.0, display[1] - top - bottom - extra_bottom);
        zgui.setNextWindowPos(.{ .x = left, .y = top, .cond = .always });
        zgui.setNextWindowSize(.{ .w = width, .h = height, .cond = .always });
    }

    const host_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_bring_to_front_on_focus = true,
        .no_saved_settings = true,
        .no_nav_focus = true,
    };

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 0.0 });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 0.0 });
    if (zgui.begin("WorkspaceHost", .{ .flags = host_flags })) {
        const avail = zgui.getContentRegionAvail();
        const dock_height = @max(1.0, avail[1] - status_height);
        const dock_size = .{ avail[0], dock_height };
        const dock_pos = zgui.getCursorScreenPos();
        const dockspace_id = zgui.dockSpace("MainDockSpace", dock_size, .{});
        dock_layout.ensureDockLayout(dock_state, &manager.workspace, dockspace_id, dock_pos, dock_size);

        var index: usize = 0;
        while (index < manager.workspace.panels.items.len) {
            var panel = &manager.workspace.panels.items[index];
            if (panel.state.dock_node == 0 and dock_state.dockspace_id != 0) {
                imgui_bridge.setNextWindowDockId(
                    dock_layout.defaultDockForKind(dock_state, panel.kind),
                    .first_use_ever,
                );
            }
            if (manager.focus_request_id != null and manager.focus_request_id.? == panel.id) {
                zgui.setNextWindowFocus();
                manager.focus_request_id = null;
            }

            var open = true;
            const label = zgui.formatZ("{s}##panel_{d}", .{ panel.title, panel.id });
            if (zgui.begin(label, .{ .popen = &open })) {
                switch (panel.kind) {
                    .Chat => {
                        const chat_action = chat_panel.draw(allocator, ctx, inbox);
                        action.send_message = chat_action.send_message;
                        action.refresh_sessions = chat_action.refresh_sessions;
                        action.new_session = chat_action.new_session;
                        action.select_session = chat_action.select_session;
                    },
                    .CodeEditor => {
                        if (code_editor_panel.draw(panel, allocator)) {
                            manager.workspace.markDirty();
                        }
                    },
                    .ToolOutput => {
                        tool_output_panel.draw(panel, allocator);
                    },
                    .Control => {
                        const control_action = control_panel.draw(
                            allocator,
                            ctx,
                            cfg,
                            is_connected,
                            app_version,
                            &panel.data.Control,
                        );
                        action.connect = control_action.connect;
                        action.disconnect = control_action.disconnect;
                        action.save_config = control_action.save_config;
                        action.clear_saved = control_action.clear_saved;
                        action.config_updated = control_action.config_updated;
                        action.refresh_sessions = control_action.refresh_sessions;
                        action.new_session = control_action.new_session;
                        action.select_session = control_action.select_session;
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
                            pending_attachment = attachment;
                        }
                        action.open_url = control_action.open_url;
                    },
                }
            }

            const dock_id = imgui_bridge.getWindowDockId();
            if (dock_id != 0 and dock_id != panel.state.dock_node) {
                panel.state.dock_node = dock_id;
                manager.workspace.markDirty();
            } else {
                panel.state.dock_node = dock_id;
            }
            panel.state.is_focused = zgui.isWindowFocused(zgui.FocusedFlags.root_and_child_windows);
            if (panel.state.is_focused) {
                if (manager.workspace.focused_panel_id == null or manager.workspace.focused_panel_id.? != panel.id) {
                    manager.workspace.focused_panel_id = panel.id;
                    manager.workspace.markDirty();
                }
            }

            zgui.end();

            if (!open) {
                _ = manager.closePanel(panel.id);
                continue;
            }

            index += 1;
        }

        if (pending_attachment) |attachment| {
            openAttachmentInEditor(allocator, manager, attachment);
        }

        syncAttachmentFetches(allocator, manager);

        zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 0.0 });
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ t.spacing.sm, status_padding_y } });
        zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ t.spacing.sm, 0.0 } });
        if (zgui.beginChild("StatusBar", .{ .h = status_height, .child_flags = .{ .border = false } })) {
            theme.push(.body);
            status_bar.draw(ctx.state, is_connected, ctx.current_session, ctx.messages.items.len, ctx.last_error);
            theme.pop();
        }
        zgui.endChild();
        zgui.popStyleVar(.{ .count = 3 });
    }
    zgui.end();
    zgui.popStyleVar(.{ .count = 3 });

    if (imgui_bridge.wantSaveIniSettings()) {
        action.save_workspace = true;
        imgui_bridge.clearWantSaveIniSettings();
    }
    if (manager.workspace.dirty) action.save_workspace = true;

    return action;
}

pub fn syncSettings(cfg: config.Config) void {
    @import("settings_view.zig").syncFromConfig(cfg);
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
