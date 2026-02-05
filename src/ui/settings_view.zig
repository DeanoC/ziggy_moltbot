const std = @import("std");
const builtin = @import("builtin");
const config = @import("../client/config.zig");
const state = @import("../client/state.zig");
const update_checker = @import("../client/update_checker.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const draw_context = @import("draw_context.zig");
const input_router = @import("input/input_router.zig");
const input_state = @import("input/input_state.zig");
const widgets = @import("widgets/widgets.zig");
const text_editor = @import("widgets/text_editor.zig");

pub const SettingsAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,
};

var server_editor: ?text_editor.TextEditor = null;
var token_editor: ?text_editor.TextEditor = null;
var connect_host_editor: ?text_editor.TextEditor = null;
var update_url_editor: ?text_editor.TextEditor = null;
var insecure_tls_value = false;
var auto_connect_value = true;
var theme_is_light = true;
var initialized = false;
var download_popup_opened = false;
var scroll_y: f32 = 0.0;
var scroll_max: f32 = 0.0;

const BadgeVariant = enum {
    primary,
    success,
    warning,
    danger,
    neutral,
};

pub fn deinit(allocator: std.mem.Allocator) void {
    if (server_editor) |*editor| editor.deinit(allocator);
    if (token_editor) |*editor| editor.deinit(allocator);
    if (connect_host_editor) |*editor| editor.deinit(allocator);
    if (update_url_editor) |*editor| editor.deinit(allocator);
    server_editor = null;
    token_editor = null;
    connect_host_editor = null;
    update_url_editor = null;
    initialized = false;
    download_popup_opened = false;
}


pub fn draw(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    client_state: state.ClientState,
    is_connected: bool,
    update_state: *update_checker.UpdateState,
    app_version: []const u8,
    rect_override: ?draw_context.Rect,
) SettingsAction {
    var action = SettingsAction{};
    const t = theme.activeTheme();
    const show_insecure_tls = builtin.target.os.tag != .emscripten;

    if (!initialized) {
        syncBuffers(allocator, cfg.*);
    }

    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(allocator, .{ .direct = .{} }, t, panel_rect);
    defer dc.deinit();
    dc.drawRect(panel_rect, .{ .fill = t.colors.background });

    const queue = input_router.getQueue();
    const header = drawHeader(&dc, panel_rect);

    const content_top = panel_rect.min[1] + header.height + t.spacing.xs;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0], content_top },
        .{ panel_rect.size()[0], panel_rect.max[1] - content_top },
    );
    if (content_rect.size()[1] <= 0.0) return action;

    handleWheelScroll(queue, content_rect, &scroll_y, scroll_max, 32.0);
    dc.pushClip(content_rect);
    defer dc.popClip();

    const card_width = content_rect.size()[0] - t.spacing.md * 2.0;
    var cursor_y = content_rect.min[1] + t.spacing.md - scroll_y;
    const start_y = cursor_y;
    const card_x = content_rect.min[0] + t.spacing.md;

    cursor_y += drawAppearanceCard(&dc, queue, card_x, cursor_y, card_width);
    cursor_y += t.spacing.md;

    const server_text = editorText(server_editor);
    const connect_host_text = editorText(connect_host_editor);
    const token_text = editorText(token_editor);
    const update_url_text = editorText(update_url_editor);
    const theme_default_light = theme.modeFromLabel(cfg.ui_theme) == .light;
    const dirty = !std.mem.eql(u8, server_text, cfg.server_url) or
        !std.mem.eql(u8, token_text, cfg.token) or
        !std.mem.eql(u8, connect_host_text, cfg.connect_host_override orelse "") or
        !std.mem.eql(u8, update_url_text, cfg.update_manifest_url orelse "") or
        theme_is_light != theme_default_light or
        (show_insecure_tls and insecure_tls_value != cfg.insecure_tls) or
        auto_connect_value != cfg.auto_connect_on_launch;

    cursor_y += drawConnectionCard(
        &dc,
        queue,
        allocator,
        cfg,
        card_x,
        cursor_y,
        card_width,
        client_state,
        is_connected,
        show_insecure_tls,
        dirty,
        &action,
    );
    cursor_y += t.spacing.md;

    const snapshot = update_state.snapshot();
    cursor_y += drawUpdatesCard(
        &dc,
        queue,
        allocator,
        cfg,
        card_x,
        cursor_y,
        card_width,
        snapshot,
        app_version,
        &action,
    );

    const content_height = cursor_y + scroll_y - start_y;
    scroll_max = @max(0.0, content_height - content_rect.size()[1] + t.spacing.md);
    if (scroll_y > scroll_max) scroll_y = scroll_max;

    drawDownloadOverlay(&dc, panel_rect, queue, snapshot);
    return action;
}

pub fn syncFromConfig(cfg: config.Config) void {
    syncBuffers(std.heap.page_allocator, cfg);
}

fn syncBuffers(allocator: std.mem.Allocator, cfg: config.Config) void {
    initialized = true;
    ensureEditor(&server_editor, allocator).setText(allocator, cfg.server_url);
    ensureEditor(&connect_host_editor, allocator).setText(allocator, cfg.connect_host_override orelse "");
    ensureEditor(&token_editor, allocator).setText(allocator, cfg.token);
    ensureEditor(&update_url_editor, allocator).setText(allocator, cfg.update_manifest_url orelse "");
    insecure_tls_value = cfg.insecure_tls;
    auto_connect_value = cfg.auto_connect_on_launch;
    theme_is_light = theme.modeFromLabel(cfg.ui_theme) == .light;
}

fn ensureEditor(
    slot: *?text_editor.TextEditor,
    allocator: std.mem.Allocator,
) *text_editor.TextEditor {
    if (slot.* == null) {
        slot.* = text_editor.TextEditor.init(allocator) catch unreachable;
    }
    return &slot.*.?;
}

fn editorText(editor: ?text_editor.TextEditor) []const u8 {
    if (editor) |value| {
        return value.slice();
    }
    return "";
}


fn drawHeader(dc: *draw_context.DrawContext, rect: draw_context.Rect) struct { height: f32 } {
    const t = theme.activeTheme();
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.push(.title);
    const title_height = dc.lineHeight();
    dc.drawText("Settings", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
    theme.pop();

    cursor_y += title_height + gap;
    const subtitle_height = dc.lineHeight();
    dc.drawText("Connection, appearance, updates", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    const height = top_pad + title_height + gap + subtitle_height + top_pad;
    return .{ .height = height };
}

fn drawAppearanceCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    x: f32,
    y: f32,
    width: f32,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const checkbox_height = line_height + t.spacing.xs * 2.0;
    const height = padding + line_height + t.spacing.xs + checkbox_height + padding;
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });

    const content_y = drawCardBase(dc, rect, "Appearance");
    var use_light = theme_is_light;
    const checkbox_rect = draw_context.Rect.fromMinSize(
        .{ rect.min[0] + padding, content_y },
        .{ width - padding * 2.0, checkbox_height },
    );
    if (widgets.checkbox.draw(dc, checkbox_rect, "Light theme", &use_light, queue, .{})) {
        theme_is_light = use_light;
        theme.setMode(if (theme_is_light) .light else .dark);
        theme.apply();
    }

    return height;
}

fn drawConnectionCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    x: f32,
    y: f32,
    width: f32,
    client_state: state.ClientState,
    is_connected: bool,
    show_insecure_tls: bool,
    dirty: bool,
    action: *SettingsAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(line_height);
    const checkbox_height = line_height + t.spacing.xs * 2.0;
    const button_height = line_height + t.spacing.xs * 2.0;

    var height = padding + line_height + t.spacing.sm;
    height += labeledInputHeight(input_height, line_height, t) * 3.0;
    height += line_height + t.spacing.sm; // helper text
    if (show_insecure_tls) {
        height += checkbox_height + t.spacing.xs;
    }
    height += checkbox_height + t.spacing.sm;
    height += button_height + t.spacing.sm;
    height += button_height + t.spacing.sm;
    height += line_height + padding;

    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });
    var cursor_y = drawCardBase(dc, rect, "Connection");
    const content_x = rect.min[0] + padding;
    const content_w = width - padding * 2.0;

    cursor_y += drawLabeledInput(dc, queue, allocator, content_x, cursor_y, content_w, "Server URL", ensureEditor(&server_editor, allocator), .{ .placeholder = "ws://host:port" });
    cursor_y += drawLabeledInput(dc, queue, allocator, content_x, cursor_y, content_w, "Connect Host (override)", ensureEditor(&connect_host_editor, allocator), .{});

    dc.drawText(
        "Override can include :port (e.g. 100.108.141.120:18789).",
        .{ content_x, cursor_y },
        .{ .color = t.colors.text_secondary },
    );
    cursor_y += line_height + t.spacing.sm;

    cursor_y += drawLabeledInput(dc, queue, allocator, content_x, cursor_y, content_w, "Token", ensureEditor(&token_editor, allocator), .{
        .placeholder = "token",
        .mask_char = '*',
    });

    if (show_insecure_tls) {
        cursor_y += drawCheckboxRow(dc, queue, content_x, cursor_y, content_w, "Insecure TLS (skip cert verification)", &insecure_tls_value, false);
    }
    cursor_y += drawCheckboxRow(dc, queue, content_x, cursor_y, content_w, "Auto-connect on launch", &auto_connect_value, false);

    var cursor_x = content_x;
    const apply_w = buttonWidth(dc, "Apply", t);
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ apply_w, button_height }), "Apply", queue, .{ .variant = .primary, .disabled = !dirty })) {
        if (applyConfig(allocator, cfg, editorText(server_editor), editorText(connect_host_editor), editorText(token_editor), editorText(update_url_editor))) {
            action.config_updated = true;
        }
    }
    cursor_x += apply_w + t.spacing.sm;
    const save_w = buttonWidth(dc, "Save", t);
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ save_w, button_height }), "Save", queue, .{ .variant = .secondary })) {
        action.save = true;
    }
    cursor_x += save_w + t.spacing.sm;
    const clear_w = buttonWidth(dc, "Clear Saved", t);
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ clear_w, button_height }), "Clear Saved", queue, .{ .variant = .ghost })) {
        action.clear_saved = true;
    }
    cursor_y += button_height + t.spacing.sm;

    if (is_connected) {
        const disc_w = buttonWidth(dc, "Disconnect", t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ disc_w, button_height }), "Disconnect", queue, .{ .variant = .secondary })) {
            action.disconnect = true;
        }
    } else {
        const conn_w = buttonWidth(dc, "Connect", t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ conn_w, button_height }), "Connect", queue, .{ .variant = .primary })) {
            if (dirty and applyConfig(allocator, cfg, editorText(server_editor), editorText(connect_host_editor), editorText(token_editor), editorText(update_url_editor))) {
                action.config_updated = true;
            }
            action.connect = true;
        }
    }
    cursor_y += button_height + t.spacing.sm;

    dc.drawText("State:", .{ content_x, cursor_y }, .{ .color = t.colors.text_primary });
    const state_label = @tagName(client_state);
    const state_variant: BadgeVariant = switch (client_state) {
        .connected => .success,
        .connecting, .authenticating => .warning,
        .error_state => .danger,
        .disconnected => if (is_connected) .success else .neutral,
    };
    const badge_size = badgeSize(dc, state_label, t);
    const badge_rect = draw_context.Rect.fromMinSize(
        .{ content_x + dc.measureText("State:", 0.0)[0] + t.spacing.sm, cursor_y + (line_height - badge_size[1]) * 0.5 },
        badge_size,
    );
    drawBadge(dc, badge_rect, state_label, state_variant);

    return height;
}

fn drawUpdatesCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    x: f32,
    y: f32,
    width: f32,
    snapshot: update_checker.Snapshot,
    app_version: []const u8,
    action: *SettingsAction,
) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(line_height);
    const button_height = line_height + t.spacing.xs * 2.0;
    const progress_height: f32 = 10.0;

    const height = calcUpdatesHeight(snapshot, t, line_height, input_height, button_height, progress_height);
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });
    var cursor_y = drawCardBase(dc, rect, "Updates");
    const content_x = rect.min[0] + padding;
    const content_w = width - padding * 2.0;

    cursor_y += drawLabeledInput(dc, queue, allocator, content_x, cursor_y, content_w, "Update Manifest URL", ensureEditor(&update_url_editor, allocator), .{});
    dc.drawText("Current version:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
    dc.drawText(app_version, .{ content_x + dc.measureText("Current version:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
    cursor_y += line_height + t.spacing.sm;

    var detail_buf: [256]u8 = undefined;
    const progress_detail: []const u8 = switch (snapshot.status) {
        .checking => "Checking for updates...",
        .up_to_date => "Up to date.",
        .update_available => switch (snapshot.download_status) {
            .downloading => "Downloading update...",
            .complete => "Update downloaded.",
            .failed => "Download failed.",
            .unsupported => "Download unsupported.",
            .idle => "Update available.",
        },
        .failed => std.fmt.bufPrint(&detail_buf, "Error: {s}", .{snapshot.error_message orelse "unknown"}) catch "Error: unknown",
        .unsupported => std.fmt.bufPrint(&detail_buf, "Unsupported: {s}", .{snapshot.error_message orelse "not supported"}) catch "Unsupported",
        .idle => "Idle.",
    };
    dc.drawText(progress_detail, .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.sm;

    if (snapshot.download_status == .downloading) {
        const total = snapshot.download_total orelse 0;
        const progress = if (total > 0)
            @as(f32, @floatFromInt(snapshot.download_bytes)) / @as(f32, @floatFromInt(total))
        else
            0.0;
        const bar_rect = draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ content_w, progress_height });
        drawProgressBar(dc, bar_rect, progress);
        cursor_y += progress_height + t.spacing.sm;
    }

    const update_url_text = editorText(update_url_editor);
    const check_w = buttonWidth(dc, "Check Updates", t);
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ check_w, button_height }), "Check Updates", queue, .{ .variant = .secondary, .disabled = snapshot.in_flight or update_url_text.len == 0 })) {
        if (applyConfig(allocator, cfg, editorText(server_editor), editorText(connect_host_editor), editorText(token_editor), update_url_text)) {
            action.config_updated = true;
        }
        action.check_updates = true;
    }
    cursor_y += button_height + t.spacing.sm;

    dc.drawText("Status:", .{ content_x, cursor_y }, .{ .color = t.colors.text_primary });
    const update_variant: BadgeVariant = switch (snapshot.status) {
        .idle => .neutral,
        .checking => .warning,
        .up_to_date => .success,
        .update_available => .primary,
        .failed => .danger,
        .unsupported => .warning,
    };
    const update_label: []const u8 = switch (snapshot.status) {
        .idle => "idle",
        .checking => "checking",
        .up_to_date => "up to date",
        .update_available => "update available",
        .failed => "error",
        .unsupported => "unsupported",
    };
    const status_badge = badgeSize(dc, update_label, t);
    const status_rect = draw_context.Rect.fromMinSize(
        .{ content_x + dc.measureText("Status:", 0.0)[0] + t.spacing.sm, cursor_y + (line_height - status_badge[1]) * 0.5 },
        status_badge,
    );
    drawBadge(dc, status_rect, update_label, update_variant);
    cursor_y += line_height + t.spacing.sm;

    if (snapshot.status == .update_available) {
        if (snapshot.latest_version) |ver| {
            dc.drawText("Latest:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
            dc.drawText(ver, .{ content_x + dc.measureText("Latest:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
            cursor_y += line_height + t.spacing.xs;
        }

        const fallback_release = "https://github.com/DeanoC/ZiggyStarClaw/releases/latest";
        const release_url = snapshot.release_url orelse fallback_release;
        dc.drawText("Release:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
        dc.drawText(release_url, .{ content_x + dc.measureText("Release:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.sm;

        const open_w = buttonWidth(dc, "Open Release Page", t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ open_w, button_height }), "Open Release Page", queue, .{ .variant = .secondary })) {
            action.open_release = true;
        }
        cursor_y += button_height + t.spacing.sm;

        if (snapshot.download_sha256) |sha| {
            dc.drawText("SHA256:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
            dc.drawText(sha, .{ content_x + dc.measureText("SHA256:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
            cursor_y += line_height + t.spacing.xs;
        }

        if (snapshot.download_url != null and snapshot.download_status == .idle) {
            const dl_w = buttonWidth(dc, "Download Update", t);
            if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ dl_w, button_height }), "Download Update", queue, .{ .variant = .primary })) {
                action.download_update = true;
            }
            cursor_y += button_height + t.spacing.sm;
        }

        if (snapshot.download_status == .failed) {
            dc.drawText("Download failed:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
            dc.drawText(snapshot.download_error_message orelse "unknown", .{ content_x + dc.measureText("Download failed:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
            cursor_y += line_height + t.spacing.xs;
        }

        if (snapshot.download_status == .unsupported) {
            dc.drawText("Download unsupported:", .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
            dc.drawText(snapshot.download_error_message orelse "not supported", .{ content_x + dc.measureText("Download unsupported:", 0.0)[0] + t.spacing.xs, cursor_y }, .{ .color = t.colors.text_primary });
            cursor_y += line_height + t.spacing.xs;
        }

        if (snapshot.download_status == .complete) {
            const verify_status = if (snapshot.download_sha256 != null) (if (snapshot.download_verified) "verified" else "not verified") else "";
            var buf: [64]u8 = undefined;
            const complete_label = if (verify_status.len > 0)
                (std.fmt.bufPrint(&buf, "Download complete ({s}).", .{verify_status}) catch "Download complete.")
            else
                "Download complete.";
            dc.drawText(complete_label, .{ content_x, cursor_y }, .{ .color = t.colors.text_secondary });
            cursor_y += line_height + t.spacing.xs;

            if (snapshot.download_path != null) {
                const open_file_w = buttonWidth(dc, "Open Downloaded File", t);
                const open_rect = draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ open_file_w, button_height });
                if (widgets.button.draw(dc, open_rect, "Open Downloaded File", queue, .{ .variant = .secondary })) {
                    action.open_download = true;
                }

                if (builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .macos) {
                    const install_w = buttonWidth(dc, "Install Update", t);
                    const install_rect = draw_context.Rect.fromMinSize(
                        .{ open_rect.max[0] + t.spacing.sm, cursor_y },
                        .{ install_w, button_height },
                    );
                    if (widgets.button.draw(dc, install_rect, "Install Update", queue, .{ .variant = .primary })) {
                        action.install_update = true;
                    }
                }
                cursor_y += button_height + t.spacing.sm;
            }
        }
    }

    return height;
}

fn calcUpdatesHeight(
    snapshot: update_checker.Snapshot,
    t: *const theme.Theme,
    line_height: f32,
    input_height: f32,
    button_height: f32,
    progress_height: f32,
) f32 {
    const padding = t.spacing.md;
    var height = padding + line_height + t.spacing.sm;
    height += labeledInputHeight(input_height, line_height, t);
    height += line_height + t.spacing.sm; // current version
    height += line_height + t.spacing.sm; // progress detail
    if (snapshot.download_status == .downloading) {
        height += progress_height + t.spacing.sm;
    }
    height += button_height + t.spacing.sm; // check updates button
    height += line_height + t.spacing.sm; // status row

    if (snapshot.status == .update_available) {
        if (snapshot.latest_version != null) {
            height += line_height + t.spacing.xs;
        }
        height += line_height + t.spacing.sm; // release line
        height += button_height + t.spacing.sm; // open release
        if (snapshot.download_sha256 != null) {
            height += line_height + t.spacing.xs;
        }
        if (snapshot.download_url != null and snapshot.download_status == .idle) {
            height += button_height + t.spacing.sm;
        }
        if (snapshot.download_status == .failed or snapshot.download_status == .unsupported) {
            height += line_height + t.spacing.xs;
        }
        if (snapshot.download_status == .complete) {
            height += line_height + t.spacing.xs;
            if (snapshot.download_path != null) {
                height += button_height + t.spacing.sm;
            }
        }
    }

    height += padding;
    return height;
}

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) f32 {
    const t = theme.activeTheme();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    dc.drawRoundedRect(rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
    theme.push(.heading);
    dc.drawText(title, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return rect.min[1] + padding + line_height + t.spacing.xs;
}

fn drawLabeledInput(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    width: f32,
    label: []const u8,
    editor: *text_editor.TextEditor,
    opts: widgets.text_input.Options,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_primary });
    const input_height = widgets.text_input.defaultHeight(line_height);
    const input_rect = draw_context.Rect.fromMinSize(.{ x, y + line_height + t.spacing.xs }, .{ width, input_height });
    _ = widgets.text_input.draw(editor, allocator, dc, input_rect, queue, opts);
    return labeledInputHeight(input_height, line_height, t);
}

fn labeledInputHeight(input_height: f32, line_height: f32, t: *const theme.Theme) f32 {
    return line_height + t.spacing.xs + input_height + t.spacing.sm;
}

fn drawCheckboxRow(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    x: f32,
    y: f32,
    width: f32,
    label: []const u8,
    value: *bool,
    disabled: bool,
) f32 {
    const t = theme.activeTheme();
    const line_height = dc.lineHeight();
    const row_height = line_height + t.spacing.xs * 2.0;
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, row_height });
    _ = widgets.checkbox.draw(dc, rect, label, value, queue, .{ .disabled = disabled });
    return row_height + t.spacing.xs;
}

fn buttonWidth(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return dc.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn badgeSize(dc: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) [2]f32 {
    const text_size = dc.measureText(label, 0.0);
    return .{ text_size[0] + t.spacing.xs * 2.0, text_size[1] + t.spacing.xs };
}

fn drawBadge(dc: *draw_context.DrawContext, rect: draw_context.Rect, label: []const u8, variant: BadgeVariant) void {
    const t = theme.activeTheme();
    const base = badgeColor(t, variant);
    const bg = colors.withAlpha(base, 0.18);
    const border = colors.withAlpha(base, 0.4);
    dc.drawRoundedRect(rect, t.radius.lg, .{ .fill = bg, .stroke = border, .thickness = 1.0 });
    dc.drawText(label, .{ rect.min[0] + t.spacing.xs, rect.min[1] + t.spacing.xs * 0.5 }, .{ .color = base });
}

fn badgeColor(t: *const theme.Theme, variant: BadgeVariant) colors.Color {
    return switch (variant) {
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
        .neutral => t.colors.text_secondary,
    };
}

fn drawProgressBar(dc: *draw_context.DrawContext, rect: draw_context.Rect, fraction: f32) void {
    const t = theme.activeTheme();
    const clamped = std.math.clamp(fraction, 0.0, 1.0);
    dc.drawRoundedRect(rect, t.radius.sm, .{ .fill = colors.withAlpha(t.colors.border, 0.2), .stroke = t.colors.border, .thickness = 1.0 });
    if (clamped > 0.0) {
        const fill_rect = draw_context.Rect.fromMinSize(rect.min, .{ rect.size()[0] * clamped, rect.size()[1] });
        dc.drawRoundedRect(fill_rect, t.radius.sm, .{ .fill = t.colors.primary, .stroke = null, .thickness = 0.0 });
    }
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll: *f32,
    max_scroll: f32,
    step: f32,
) void {
    if (max_scroll <= 0.0) {
        scroll.* = 0.0;
        return;
    }
    if (!rect.contains(queue.state.mouse_pos)) return;
    for (queue.events.items) |evt| {
        if (evt == .mouse_wheel) {
            scroll.* -= evt.mouse_wheel.delta[1] * step;
        }
    }
    if (scroll.* < 0.0) scroll.* = 0.0;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
}

fn drawDownloadOverlay(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    snapshot: update_checker.Snapshot,
) void {
    const t = theme.activeTheme();
    const downloading = snapshot.download_status == .downloading;
    if (downloading) {
        download_popup_opened = true;
    }
    if (!download_popup_opened) return;
    if (!downloading and snapshot.download_status == .idle) {
        download_popup_opened = false;
        return;
    }

    const scrim = colors.withAlpha(t.colors.background, 0.6);
    dc.drawRect(rect, .{ .fill = scrim });

    const line_height = dc.lineHeight();
    const padding = t.spacing.md;
    const progress_height = line_height;
    const button_height = line_height + t.spacing.xs * 2.0;
    const extra_button = if (downloading) 0.0 else button_height + t.spacing.sm;
    const card_height = padding + line_height + t.spacing.xs + progress_height + extra_button + padding;

    const max_width = rect.size()[0] - t.spacing.lg * 2.0;
    const card_width = std.math.clamp(max_width, 240.0, 420.0);
    const card_pos = .{
        rect.min[0] + (rect.size()[0] - card_width) * 0.5,
        rect.min[1] + (rect.size()[1] - card_height) * 0.5,
    };
    const card_rect = draw_context.Rect.fromMinSize(card_pos, .{ card_width, card_height });

    dc.drawRoundedRect(card_rect, t.radius.md, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
    theme.push(.heading);
    dc.drawText("Downloading update...", .{ card_rect.min[0] + padding, card_rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    const progress_rect = draw_context.Rect.fromMinSize(
        .{ card_rect.min[0] + padding, card_rect.min[1] + padding + line_height + t.spacing.xs },
        .{ card_rect.size()[0] - padding * 2.0, progress_height },
    );
    const total = snapshot.download_total orelse 0;
    const progress = if (total > 0)
        @as(f32, @floatFromInt(snapshot.download_bytes)) / @as(f32, @floatFromInt(total))
    else
        0.0;
    drawProgressBar(dc, progress_rect, progress);

    if (total > 0) {
        var overlay_buf: [64]u8 = undefined;
        const overlay = std.fmt.bufPrint(&overlay_buf, "{d} / {d} bytes", .{ snapshot.download_bytes, total }) catch "";
        const overlay_size = dc.measureText(overlay, progress_rect.size()[0]);
        const overlay_pos = .{
            progress_rect.min[0] + (progress_rect.size()[0] - overlay_size[0]) * 0.5,
            progress_rect.min[1] + (progress_rect.size()[1] - overlay_size[1]) * 0.5,
        };
        dc.drawText(overlay, overlay_pos, .{ .color = t.colors.text_primary });
    }

    if (!downloading) {
        const button_rect = draw_context.Rect.fromMinSize(
            .{ card_rect.min[0] + padding, progress_rect.max[1] + t.spacing.sm },
            .{ card_rect.size()[0] - padding * 2.0, button_height },
        );
        if (widgets.button.draw(dc, button_rect, "Close", queue, .{ .variant = .secondary })) {
            download_popup_opened = false;
        }
    }
}

fn applyConfig(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    server_text: []const u8,
    connect_host_text: []const u8,
    token_text: []const u8,
    update_url_text: []const u8,
) bool {
    var changed = false;

    if (!std.mem.eql(u8, cfg.server_url, server_text)) {
        const new_value = allocator.dupe(u8, server_text) catch return changed;
        allocator.free(cfg.server_url);
        cfg.server_url = new_value;
        changed = true;
    }

    if (!std.mem.eql(u8, cfg.token, token_text)) {
        const new_value = allocator.dupe(u8, token_text) catch return changed;
        allocator.free(cfg.token);
        cfg.token = new_value;
        changed = true;
    }

    const current_connect = cfg.connect_host_override orelse "";
    if (!std.mem.eql(u8, current_connect, connect_host_text)) {
        if (cfg.connect_host_override) |value| {
            allocator.free(value);
            cfg.connect_host_override = null;
        }
        if (connect_host_text.len > 0) {
            cfg.connect_host_override = allocator.dupe(u8, connect_host_text) catch return changed;
        }
        changed = true;
    }

    if (cfg.insecure_tls != insecure_tls_value) {
        cfg.insecure_tls = insecure_tls_value;
        changed = true;
    }
    if (cfg.auto_connect_on_launch != auto_connect_value) {
        cfg.auto_connect_on_launch = auto_connect_value;
        changed = true;
    }

    const desired_mode: theme.Mode = if (theme_is_light) .light else .dark;
    const desired_label = theme.labelForMode(desired_mode);
    const current_label = cfg.ui_theme orelse "light";
    if (!std.mem.eql(u8, current_label, desired_label)) {
        if (cfg.ui_theme) |value| allocator.free(value);
        cfg.ui_theme = allocator.dupe(u8, desired_label) catch return changed;
        changed = true;
    }

    const current_update = cfg.update_manifest_url orelse "";
    if (!std.mem.eql(u8, current_update, update_url_text)) {
        if (cfg.update_manifest_url) |value| {
            allocator.free(value);
            cfg.update_manifest_url = null;
        }
        if (update_url_text.len > 0) {
            cfg.update_manifest_url = allocator.dupe(u8, update_url_text) catch return changed;
        }
        changed = true;
    }

    return changed;
}
