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
const nav_router = @import("input/nav_router.zig");
const text_editor = @import("widgets/text_editor.zig");
const theme_runtime = @import("theme_engine/runtime.zig");
const panel_chrome = @import("panel_chrome.zig");
const surface_chrome = @import("surface_chrome.zig");

pub const SettingsAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save: bool = false,
    reload_theme_pack: bool = false,
    browse_theme_pack: bool = false,
    browse_theme_pack_override: bool = false,
    clear_theme_pack_override: bool = false,
    reload_theme_pack_override: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,

    // Windows install profile helpers
    node_profile_apply_client: bool = false,
    node_profile_apply_service: bool = false,
    node_profile_apply_session: bool = false,

    // Windows node runner helpers (advanced/manual)
    node_service_install_onlogon: bool = false,
    node_service_start: bool = false,
    node_service_stop: bool = false,
    node_service_status: bool = false,
    node_service_uninstall: bool = false,
    open_node_logs: bool = false,
};

var server_editor: ?text_editor.TextEditor = null;
var token_editor: ?text_editor.TextEditor = null;
var connect_host_editor: ?text_editor.TextEditor = null;
var update_url_editor: ?text_editor.TextEditor = null;
var theme_pack_editor: ?text_editor.TextEditor = null;
var insecure_tls_value = false;
var auto_connect_value = true;
var theme_is_light = true;
var watch_theme_pack_value = false;
const ProfileChoice = enum { auto, desktop, phone, tablet, fullscreen };
var profile_choice: ProfileChoice = .auto;
var initialized = false;
var download_popup_opened = false;
var scroll_y: f32 = 0.0;
var scroll_max: f32 = 0.0;
var config_cwd: ?[]u8 = null;
var appearance_changed: bool = false;

const ThemePackEntry = struct {
    name: []u8,
};
var theme_pack_entries: std.ArrayListUnmanaged(ThemePackEntry) = .{};
var theme_pack_entries_loaded: bool = false;

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
    if (theme_pack_editor) |*editor| editor.deinit(allocator);
    if (config_cwd) |value| allocator.free(value);
    clearThemePackEntries(allocator);
    server_editor = null;
    token_editor = null;
    connect_host_editor = null;
    update_url_editor = null;
    theme_pack_editor = null;
    config_cwd = null;
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
    window_theme_pack_override: ?[]const u8,
    install_profile_only_mode: bool,
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
    surface_chrome.drawBackground(&dc, panel_rect);

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

    if (!install_profile_only_mode) {
        cursor_y += drawAppearanceCard(&dc, queue, allocator, cfg, window_theme_pack_override, card_x, cursor_y, card_width, &action);
        cursor_y += t.spacing.md;
    }

    const server_text = editorText(server_editor);
    const connect_host_text = editorText(connect_host_editor);
    const token_text = editorText(token_editor);
    const update_url_text = editorText(update_url_editor);
    const theme_pack_text = editorText(theme_pack_editor);
    const pack_default_mode = theme_runtime.getPackDefaultMode() orelse .light;
    const effective_mode: theme.Mode = if (theme_runtime.getPackModeLockToDefault())
        pack_default_mode
    else if (cfg.ui_theme) |label|
        theme.modeFromLabel(label)
    else
        pack_default_mode;
    const theme_default_light = effective_mode == .light;
    const cfg_profile = cfg.ui_profile orelse "";
    const desired_profile = profileLabel(profile_choice) orelse "";
    const dirty = !std.mem.eql(u8, server_text, cfg.server_url) or
        !std.mem.eql(u8, token_text, cfg.token) or
        !std.mem.eql(u8, connect_host_text, cfg.connect_host_override orelse "") or
        !std.mem.eql(u8, update_url_text, cfg.update_manifest_url orelse "") or
        !std.mem.eql(u8, theme_pack_text, cfg.ui_theme_pack orelse "") or
        !std.mem.eql(u8, desired_profile, cfg_profile) or
        theme_is_light != theme_default_light or
        (show_insecure_tls and insecure_tls_value != cfg.insecure_tls) or
        auto_connect_value != cfg.auto_connect_on_launch;

    // Appearance toggles (theme mode / quick pack buttons / profile buttons) should feel persistent.
    // If they changed, apply + request save immediately.
    if (!install_profile_only_mode and appearance_changed) {
        appearance_changed = false;
        if (applyAppearanceConfig(allocator, cfg, theme_pack_text, profileLabel(profile_choice))) {
            action.config_updated = true;
            action.save = true;
        }
    }

    const snapshot = update_state.snapshot();

    if (!install_profile_only_mode) {
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
    }

    if (builtin.os.tag == .windows) {
        cursor_y += drawWindowsNodeServiceCard(&dc, queue, allocator, cfg, card_x, cursor_y, card_width, &action, install_profile_only_mode);
        if (!install_profile_only_mode) cursor_y += t.spacing.md;
    }

    if (!install_profile_only_mode) {
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
    }

    const content_height = cursor_y + scroll_y - start_y;
    scroll_max = @max(0.0, content_height - content_rect.size()[1] + t.spacing.md);
    if (scroll_y > scroll_max) scroll_y = scroll_max;

    drawDownloadOverlay(&dc, panel_rect, queue, snapshot);
    return action;
}

pub fn syncFromConfig(allocator: std.mem.Allocator, cfg: config.Config) void {
    syncBuffers(allocator, cfg);
}

fn clearThemePackEntries(allocator: std.mem.Allocator) void {
    for (theme_pack_entries.items) |entry| {
        allocator.free(entry.name);
    }
    theme_pack_entries.deinit(allocator);
    theme_pack_entries = .{};
    theme_pack_entries_loaded = false;
}

fn refreshThemePackEntries(allocator: std.mem.Allocator) void {
    clearThemePackEntries(allocator);
    theme_pack_entries_loaded = true;

    // std.fs directory iteration isn't available on wasm/wasi builds.
    if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) return;

    var themes_dir = std.fs.cwd().openDir("themes", .{ .iterate = true }) catch return;
    defer themes_dir.close();

    var it = themes_dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0) continue;

        var pack_dir = themes_dir.openDir(entry.name, .{}) catch continue;
        defer pack_dir.close();

        // "manifest.json" is our minimal marker for a theme pack folder.
        var f = pack_dir.openFile("manifest.json", .{}) catch continue;
        f.close();

        const name = allocator.dupe(u8, entry.name) catch continue;
        theme_pack_entries.append(allocator, .{ .name = name }) catch {
            allocator.free(name);
            break;
        };
    }

    if (theme_pack_entries.items.len > 1) {
        const Ctx = struct {};
        std.sort.pdq(ThemePackEntry, theme_pack_entries.items, Ctx{}, struct {
            fn lessThan(_: Ctx, a: ThemePackEntry, b: ThemePackEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }
}

fn syncBuffers(allocator: std.mem.Allocator, cfg: config.Config) void {
    initialized = true;
    ensureEditor(&server_editor, allocator).setText(allocator, cfg.server_url);
    ensureEditor(&connect_host_editor, allocator).setText(allocator, cfg.connect_host_override orelse "");
    ensureEditor(&token_editor, allocator).setText(allocator, cfg.token);
    ensureEditor(&update_url_editor, allocator).setText(allocator, cfg.update_manifest_url orelse "");
    ensureEditor(&theme_pack_editor, allocator).setText(allocator, cfg.ui_theme_pack orelse "");
    insecure_tls_value = cfg.insecure_tls;
    auto_connect_value = cfg.auto_connect_on_launch;
    watch_theme_pack_value = cfg.ui_watch_theme_pack;
    const pack_default = theme_runtime.getPackDefaultMode() orelse .light;
    const effective_mode: theme.Mode = if (theme_runtime.getPackModeLockToDefault())
        pack_default
    else if (cfg.ui_theme) |label|
        theme.modeFromLabel(label)
    else
        pack_default;
    theme_is_light = effective_mode == .light;
    profile_choice = profileChoiceFromLabel(cfg.ui_profile);

    if (config_cwd) |value| allocator.free(value);
    config_cwd = null;
    if (builtin.target.os.tag != .emscripten and builtin.target.os.tag != .wasi) {
        config_cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    }
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
    const t = dc.theme;
    const top_pad = t.spacing.sm;
    const gap = t.spacing.xs;
    const left = rect.min[0] + t.spacing.md;
    var cursor_y = rect.min[1] + top_pad;

    theme.pushFor(t, .title);
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
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    window_theme_pack_override: ?[]const u8,
    x: f32,
    y: f32,
    width: f32,
    action: *SettingsAction,
) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const checkbox_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const button_height = widgets.button.defaultHeight(t, line_height);
    const can_watch_pack = !(builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) and !builtin.target.abi.isAndroid();
    const can_window_override = !(builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) and !builtin.target.abi.isAndroid();

    var height = padding + line_height + t.spacing.xs + checkbox_height + t.spacing.sm;
    if (can_watch_pack) height += checkbox_height + t.spacing.sm;
    height += labeledInputHeight(input_height, line_height, t);
    if (can_window_override) height += (line_height + t.spacing.xs) * 2.0 + button_height + t.spacing.sm;
    // Helper text + config path + status + pack details.
    height += (line_height + t.spacing.xs) * 4.0;
    height += button_height + t.spacing.sm; // pack buttons row
    height += button_height + t.spacing.sm; // recent row
    height += button_height + t.spacing.sm; // pack picker row
    height += button_height + padding; // profile picker row + bottom padding
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });

    const base = drawCardBase(dc, rect, "Appearance");
    const inner = base.inner_rect;
    const content_y = base.cursor_y;
    const pack_default = theme_runtime.getPackDefaultMode() orelse .light;
    const mode_locked = theme_runtime.getPackModeLockToDefault();
    if (mode_locked) {
        // Force the checkbox display to match the pack default.
        theme_is_light = (pack_default == .light);
    }

    var use_light = theme_is_light;
    const checkbox_rect = draw_context.Rect.fromMinSize(
        .{ inner.min[0] + padding, content_y },
        .{ inner.size()[0] - padding * 2.0, checkbox_height },
    );
    const mode_label = if (mode_locked) "Light theme (locked by pack)" else "Light theme";
    if (widgets.checkbox.draw(dc, checkbox_rect, mode_label, &use_light, queue, .{ .disabled = mode_locked })) {
        theme_is_light = use_light;
        theme.setMode(if (theme_is_light) .light else .dark);
        theme.apply();
        appearance_changed = true;
    }

    var cursor_y = content_y + checkbox_height + t.spacing.sm;
    if (can_watch_pack) {
        var watch = watch_theme_pack_value;
        const watch_rect = draw_context.Rect.fromMinSize(
            .{ inner.min[0] + padding, cursor_y },
            .{ inner.size()[0] - padding * 2.0, checkbox_height },
        );
        if (widgets.checkbox.draw(
            dc,
            watch_rect,
            "Watch pack files (auto reload JSON)",
            &watch,
            queue,
            .{},
        )) {
            watch_theme_pack_value = watch;
            appearance_changed = true;
        }
        cursor_y += checkbox_height + t.spacing.sm;
    }

    // Profile picker near the top so it's easy to exit Fullscreen mode (especially when
    // large hit targets make the rest of the card tall).
    {
        const picker_label = "Profile:";
        const picker_x = inner.min[0] + padding;
        dc.drawText(picker_label, .{ picker_x, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_primary });

        var profile_px = picker_x + dc.measureText(picker_label, 0.0)[0] + t.spacing.sm;
        const choices = [_]struct { id: ProfileChoice, label: []const u8 }{
            .{ .id = .auto, .label = "Auto" },
            .{ .id = .desktop, .label = "Desktop" },
            .{ .id = .phone, .label = "Phone" },
            .{ .id = .tablet, .label = "Tablet" },
            .{ .id = .fullscreen, .label = "Fullscreen" },
        };
        for (choices) |c| {
            const w = buttonWidth(dc, c.label, t);
            const r = draw_context.Rect.fromMinSize(.{ profile_px, cursor_y }, .{ w, button_height });
            const is_selected = profile_choice == c.id;
            if (widgets.button.draw(dc, r, c.label, queue, .{ .variant = if (is_selected) .primary else .ghost })) {
                profile_choice = c.id;
                appearance_changed = true;
            }
            profile_px += w + t.spacing.xs;
        }
    }
    cursor_y += button_height + t.spacing.sm;

    cursor_y += drawLabeledInput(
        dc,
        queue,
        allocator,
        inner.min[0] + padding,
        cursor_y,
        inner.size()[0] - padding * 2.0,
        "Theme pack path",
        ensureEditor(&theme_pack_editor, allocator),
        .{ .placeholder = "themes/zsc_showcase" },
    );

    if (can_window_override) {
        const override_text = window_theme_pack_override orelse "";
        const global_text = cfg.ui_theme_pack orelse "";
        const effective_text = if (override_text.len > 0) override_text else global_text;

        var buf0: [640]u8 = undefined;
        const ov_line = if (override_text.len > 0)
            (std.fmt.bufPrint(&buf0, "This window override: {s}", .{override_text}) catch "This window override: (format error)")
        else
            "This window override: (none)";
        dc.drawText(ov_line, .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;

        var buf1: [640]u8 = undefined;
        const eff_line = if (effective_text.len > 0)
            (std.fmt.bufPrint(&buf1, "Effective pack: {s}", .{effective_text}) catch "Effective pack: (format error)")
        else
            "Effective pack: (built-in)";
        dc.drawText(eff_line, .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;

        // Override buttons row.
        const button_y = cursor_y;
        var bx = inner.min[0] + padding;
        const browse_w = buttonWidth(dc, "Browse override...", t);
        const browse_rect = draw_context.Rect.fromMinSize(.{ bx, button_y }, .{ browse_w, button_height });
        if (widgets.button.draw(dc, browse_rect, "Browse override...", queue, .{ .variant = .secondary })) {
            action.browse_theme_pack_override = true;
        }
        bx += browse_w + t.spacing.xs;

        const use_global_w = buttonWidth(dc, "Use global", t);
        const use_global_rect = draw_context.Rect.fromMinSize(.{ bx, button_y }, .{ use_global_w, button_height });
        if (widgets.button.draw(dc, use_global_rect, "Use global", queue, .{ .variant = .ghost, .disabled = override_text.len == 0 })) {
            action.clear_theme_pack_override = true;
        }
        bx += use_global_w + t.spacing.xs;

        const can_reload_override = effective_text.len > 0;
        const reload_w = buttonWidth(dc, "Reload window pack", t);
        const reload_rect = draw_context.Rect.fromMinSize(.{ bx, button_y }, .{ reload_w, button_height });
        if (widgets.button.draw(dc, reload_rect, "Reload window pack", queue, .{ .variant = .ghost, .disabled = !can_reload_override })) {
            action.reload_theme_pack_override = true;
        }
        cursor_y += button_height + t.spacing.sm;
    }

    const helper_line: []const u8 = if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi)
        "Edit path then press Apply or Reload (Reload re-fetches)."
    else
        "Edit path then press Apply or Reload (Reload re-reads JSON).";
    dc.drawText(helper_line, .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) {
        dc.drawText(
            "Config saves to: browser storage",
            .{ inner.min[0] + padding, cursor_y },
            .{ .color = t.colors.text_secondary },
        );
    } else if (config_cwd) |cwd| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Config saves to: {s}/ziggystarclaw_config.json", .{cwd}) catch "Config saves to: (unknown)";
        dc.drawText(line, .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
    }
    cursor_y += line_height + t.spacing.xs;

    // Theme pack status (last load result).
    {
        const status = theme_runtime.getPackStatus();
        const badge_label: []const u8 = switch (status.kind) {
            .none => "Idle",
            .fetching => "Fetching",
            .ok => "OK",
            .failed => "Error",
        };
        const badge_variant: BadgeVariant = switch (status.kind) {
            .fetching => .warning,
            .ok => .success,
            .failed => .danger,
            .none => .neutral,
        };

        const badge_sz = badgeSize(dc, badge_label, t);
        const badge_rect = draw_context.Rect.fromMinSize(.{ inner.min[0] + padding, cursor_y }, badge_sz);
        drawBadge(dc, badge_rect, badge_label, badge_variant);
        const msg = if (status.msg.len > 0) status.msg else "(no status)";
        dc.drawText(
            msg,
            .{ badge_rect.max[0] + t.spacing.sm, cursor_y + t.spacing.xs * 0.5 },
            .{ .color = t.colors.text_secondary },
        );
    }
    cursor_y += line_height + t.spacing.xs;

    // Pack metadata (from manifest.json of the currently loaded pack).
    {
        const meta = theme_runtime.getPackMeta();
        if (meta) |m| {
            var buf: [512]u8 = undefined;
            const name = if (m.name.len > 0) m.name else m.id;
            const author = m.author;
            const variant = if (m.defaults_variant.len > 0) m.defaults_variant else "?";
            const prof = if (m.defaults_profile.len > 0) m.defaults_profile else "?";
            const cap_multi: []const u8 = if (m.requires_multi_window) " multi-window" else "";
            const cap_shaders: []const u8 = if (m.requires_custom_shaders) " shaders" else "";
            const caps_sep: []const u8 = if (cap_multi.len > 0 or cap_shaders.len > 0) " | caps:" else "";
            const by: []const u8 = if (author.len > 0) " by " else "";
            const msg = std.fmt.bufPrint(&buf, "Pack: {s} (id: {s}){s}{s} | defaults: {s}/{s}{s}{s}{s}", .{
                name,
                m.id,
                by,
                author,
                variant,
                prof,
                caps_sep,
                cap_multi,
                cap_shaders,
            }) catch "Pack: (metadata unavailable)";
            dc.drawText(msg, .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        } else {
            dc.drawText("Pack: (built-in)", .{ inner.min[0] + padding, cursor_y }, .{ .color = t.colors.text_secondary });
        }
    }
    cursor_y += line_height + t.spacing.xs;

    // Pack actions row.
    const button_y = cursor_y;
    var button_x = inner.min[0] + padding;

    // In browser builds, we can't scan local folders. Keep a few quick picks.
    if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) {
        const clean_w = buttonWidth(dc, "Clean", t);
        const clean_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ clean_w, button_height });
        if (widgets.button.draw(dc, clean_rect, "Clean", queue, .{ .variant = .secondary })) {
            ensureEditor(&theme_pack_editor, allocator).setText(allocator, "themes/zsc_clean");
            profile_choice = .desktop;
            appearance_changed = true;
        }
        button_x += clean_w + t.spacing.xs;

        const showcase_w = buttonWidth(dc, "Showcase", t);
        const showcase_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ showcase_w, button_height });
        if (widgets.button.draw(dc, showcase_rect, "Showcase", queue, .{ .variant = .secondary })) {
            ensureEditor(&theme_pack_editor, allocator).setText(allocator, "themes/zsc_showcase");
            profile_choice = .desktop;
            appearance_changed = true;
        }
        button_x += showcase_w + t.spacing.xs;

        const winamp_w = buttonWidth(dc, "Winamp", t);
        const winamp_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ winamp_w, button_height });
        if (widgets.button.draw(dc, winamp_rect, "Winamp", queue, .{ .variant = .secondary })) {
            ensureEditor(&theme_pack_editor, allocator).setText(allocator, "themes/zsc_winamp");
            profile_choice = .desktop;
            // The winamp-ish pack is authored with intentionally dark fills in the style sheet.
            // Switching to dark mode by default avoids a "mixed" look where token-driven panels
            // render light while style-driven chrome stays dark.
            theme_is_light = false;
            theme.setMode(.dark);
            theme.apply();
            appearance_changed = true;
        }
        button_x += winamp_w + t.spacing.xs;
    }

    const theme_pack_text = editorText(theme_pack_editor);
    const current_pack = cfg.ui_theme_pack orelse "";
    const pack_dirty = !std.mem.eql(u8, current_pack, theme_pack_text);

    const apply_w = buttonWidth(dc, "Apply", t);
    const apply_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ apply_w, button_height });
    if (widgets.button.draw(dc, apply_rect, "Apply", queue, .{ .variant = .primary, .disabled = !pack_dirty })) {
        appearance_changed = true;
    }
    button_x += apply_w + t.spacing.xs;

    const can_reload = theme_pack_text.len > 0 and !(builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi);
    const reload_w = buttonWidth(dc, "Reload pack", t);
    const reload_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ reload_w, button_height });
    if (widgets.button.draw(dc, reload_rect, "Reload pack", queue, .{ .variant = .ghost, .disabled = !can_reload })) {
        appearance_changed = true;
        action.reload_theme_pack = true;
    }
    button_x += reload_w + t.spacing.xs;

    const disable_w = buttonWidth(dc, "Disable pack", t);
    const disable_rect = draw_context.Rect.fromMinSize(.{ button_x, button_y }, .{ disable_w, button_height });
    if (widgets.button.draw(dc, disable_rect, "Disable pack", queue, .{ .variant = .ghost, .disabled = theme_pack_text.len == 0 })) {
        ensureEditor(&theme_pack_editor, allocator).setText(allocator, "");
        appearance_changed = true;
    }
    cursor_y += button_height + t.spacing.sm;

    // Recent pack shortcuts (persisted in config).
    {
        const recent_label = "Recent:";
        const rx0 = inner.min[0] + padding;
        dc.drawText(recent_label, .{ rx0, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
        var rx = rx0 + dc.measureText(recent_label, 0.0)[0] + t.spacing.sm;
        const max_x = inner.max[0] - padding;

        const recent = cfg.ui_theme_pack_recent orelse &[_][]const u8{};
        if (recent.len == 0) {
            dc.drawText("(none)", .{ rx, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
        } else {
            var shown: usize = 0;
            for (recent) |item| {
                const label = blk: {
                    const themes_prefix = "themes/";
                    if (std.mem.startsWith(u8, item, themes_prefix)) break :blk item[themes_prefix.len..];
                    const idx = std.mem.lastIndexOfAny(u8, item, "/\\") orelse break :blk item;
                    if (idx + 1 < item.len) break :blk item[idx + 1 ..];
                    break :blk item;
                };
                const w = buttonWidth(dc, label, t);
                if (rx + w > max_x) break;
                const r = draw_context.Rect.fromMinSize(.{ rx, cursor_y }, .{ w, button_height });
                if (widgets.button.draw(dc, r, label, queue, .{ .variant = .ghost })) {
                    ensureEditor(&theme_pack_editor, allocator).setText(allocator, item);
                    appearance_changed = true;
                }
                rx += w + t.spacing.xs;
                shown += 1;
            }
            if (shown < recent.len and rx + dc.measureText("...", 0.0)[0] < max_x) {
                dc.drawText("...", .{ rx, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
            }
        }
    }
    cursor_y += button_height + t.spacing.sm;

    // Theme pack picker row.
    if (!(builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi)) {
        if (!theme_pack_entries_loaded) refreshThemePackEntries(allocator);
    }

    const can_refresh = !(builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi);
    const can_browse = builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .macos;

    const row_min_x = inner.min[0] + padding;
    const row_max_x = inner.max[0] - padding;

    // Right-side controls, anchored so they don't get pushed off-screen.
    var right_x = row_max_x;
    {
        const browse_w = buttonWidth(dc, "Browse...", t);
        right_x -= browse_w;
        const browse_rect = draw_context.Rect.fromMinSize(.{ right_x, cursor_y }, .{ browse_w, button_height });
        if (widgets.button.draw(dc, browse_rect, "Browse...", queue, .{ .variant = .secondary, .disabled = !can_browse })) {
            action.browse_theme_pack = true;
        }
        right_x -= t.spacing.xs;
    }

    {
        const refresh_w = buttonWidth(dc, "Refresh", t);
        right_x -= refresh_w;
        const refresh_rect = draw_context.Rect.fromMinSize(.{ right_x, cursor_y }, .{ refresh_w, button_height });
        if (widgets.button.draw(dc, refresh_rect, "Refresh", queue, .{ .variant = .ghost, .disabled = !can_refresh })) {
            refreshThemePackEntries(allocator);
        }
        right_x -= t.spacing.sm;
    }

    const packs_label = "Packs:";
    dc.drawText(packs_label, .{ row_min_x, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
    var px = row_min_x + dc.measureText(packs_label, 0.0)[0] + t.spacing.sm;
    const avail_max_x = @max(px, right_x);

    if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) {
        dc.drawText(
            "(browser build: no local pack scan)",
            .{ px, cursor_y + (button_height - line_height) * 0.5 },
            .{ .color = t.colors.text_secondary },
        );
    } else if (theme_pack_entries.items.len == 0) {
        dc.drawText("(none found in ./themes)", .{ px, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
    } else {
        var shown: usize = 0;
        for (theme_pack_entries.items) |entry| {
            var buf: [256]u8 = undefined;
            const full_path = std.fmt.bufPrint(&buf, "themes/{s}", .{entry.name}) catch entry.name;
            const is_selected = std.mem.eql(u8, full_path, theme_pack_text);
            const w = buttonWidth(dc, entry.name, t);
            if (px + w > avail_max_x) break;
            const r = draw_context.Rect.fromMinSize(.{ px, cursor_y }, .{ w, button_height });
            if (widgets.button.draw(dc, r, entry.name, queue, .{ .variant = if (is_selected) .primary else .secondary })) {
                ensureEditor(&theme_pack_editor, allocator).setText(allocator, full_path);
                appearance_changed = true;
            }
            px += w + t.spacing.xs;
            shown += 1;
        }

        if (shown < theme_pack_entries.items.len and px + dc.measureText("...", 0.0)[0] < avail_max_x) {
            dc.drawText("...", .{ px, cursor_y + (button_height - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
        }
    }

    return height;
}

fn profileChoiceFromLabel(label: ?[]const u8) ProfileChoice {
    if (label == null or label.?.len == 0) return .auto;
    const value = label.?;
    if (std.ascii.eqlIgnoreCase(value, "desktop")) return .desktop;
    if (std.ascii.eqlIgnoreCase(value, "phone")) return .phone;
    if (std.ascii.eqlIgnoreCase(value, "tablet")) return .tablet;
    if (std.ascii.eqlIgnoreCase(value, "fullscreen")) return .fullscreen;
    return .auto;
}

fn profileLabel(choice: ProfileChoice) ?[]const u8 {
    return switch (choice) {
        .auto => null,
        .desktop => "desktop",
        .phone => "phone",
        .tablet => "tablet",
        .fullscreen => "fullscreen",
    };
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
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const checkbox_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const button_height = widgets.button.defaultHeight(t, line_height);

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
    const base = drawCardBase(dc, rect, "Connection");
    const inner = base.inner_rect;
    var cursor_y = base.cursor_y;
    const content_x = inner.min[0] + padding;
    const content_w = inner.size()[0] - padding * 2.0;

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
        if (applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            editorText(update_url_editor),
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
            action.config_updated = true;
        }
    }
    cursor_x += apply_w + t.spacing.sm;
    const save_w = buttonWidth(dc, "Save", t);
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ save_w, button_height }), "Save", queue, .{ .variant = .secondary })) {
        if (dirty and applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            editorText(update_url_editor),
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
            action.config_updated = true;
        }
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
            if (dirty and applyConfig(
                allocator,
                cfg,
                editorText(server_editor),
                editorText(connect_host_editor),
                editorText(token_editor),
                editorText(update_url_editor),
                editorText(theme_pack_editor),
                profileLabel(profile_choice),
            )) {
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

fn drawWindowsNodeServiceCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    x: f32,
    y: f32,
    width: f32,
    action: *SettingsAction,
    profile_only: bool,
) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = line_height + t.spacing.xs * 2.0;
    const input_height = widgets.text_input.defaultHeight(t, line_height);

    var height: f32 = 0.0;
    height += padding + line_height + t.spacing.sm;
    if (profile_only) {
        height += labeledInputHeight(input_height, line_height, t) * 2.0;
        height += button_height + t.spacing.sm;
    }
    height += line_height + t.spacing.xs;
    height += line_height + t.spacing.sm;
    height += button_height + t.spacing.sm;
    if (!profile_only) {
        height += line_height + t.spacing.sm;
        height += button_height + t.spacing.sm;
        height += button_height + padding;
    } else {
        height += padding;
    }

    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });
    const base = drawCardBase(dc, rect, "Windows Install Profile");
    var cursor_y = base.cursor_y;

    const content_x = base.inner_rect.min[0] + padding;
    const server_editor_value = editorText(server_editor);
    const server_text = std.mem.trim(u8, server_editor_value, " \t\r\n");
    const persisted_server_text = std.mem.trim(u8, cfg.server_url, " \t\r\n");
    const server_url_dirty = !std.mem.eql(u8, cfg.server_url, server_editor_value);
    const has_url = if (profile_only)
        server_text.len > 0
    else
        persisted_server_text.len > 0 and !server_url_dirty;

    if (profile_only) {
        const content_w = base.inner_rect.size()[0] - padding * 2.0;
        cursor_y += drawLabeledInput(
            dc,
            queue,
            allocator,
            content_x,
            cursor_y,
            content_w,
            "Server URL",
            ensureEditor(&server_editor, allocator),
            .{ .placeholder = "ws://host:port" },
        );
        cursor_y += drawLabeledInput(
            dc,
            queue,
            allocator,
            content_x,
            cursor_y,
            content_w,
            "Token (optional)",
            ensureEditor(&token_editor, allocator),
            .{
                .placeholder = "token",
                .mask_char = '*',
            },
        );

        const onboarding_dirty = !std.mem.eql(u8, cfg.server_url, editorText(server_editor)) or
            !std.mem.eql(u8, cfg.token, editorText(token_editor));
        const apply_conn_w = buttonWidth(dc, "Apply Connection", t);
        if (widgets.button.draw(
            dc,
            draw_context.Rect.fromMinSize(.{ content_x, cursor_y }, .{ apply_conn_w, button_height }),
            "Apply Connection",
            queue,
            .{ .variant = .secondary, .disabled = !onboarding_dirty },
        )) {
            if (applyConfig(
                allocator,
                cfg,
                editorText(server_editor),
                editorText(connect_host_editor),
                editorText(token_editor),
                editorText(update_url_editor),
                editorText(theme_pack_editor),
                profileLabel(profile_choice),
            )) {
                action.config_updated = true;
                action.save = true;
            }
        }
        cursor_y += button_height + t.spacing.sm;
    }

    dc.drawText(
        "Client is always installed. Choose one profile; the app migrates runner mode automatically.",
        .{ content_x, cursor_y },
        .{ .color = t.colors.text_secondary },
    );
    cursor_y += line_height + t.spacing.xs;

    dc.drawText(
        "Service profile is reliable (limited desktop access). Session profile is interactive (camera/screen/browser).",
        .{ content_x, cursor_y },
        .{ .color = t.colors.text_secondary },
    );
    cursor_y += line_height + t.spacing.sm;

    var cursor_x = content_x;
    const client_label = "Pure Client";
    const client_w = buttonWidth(dc, client_label, t);
    if (widgets.button.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ client_w, button_height }),
        client_label,
        queue,
        .{ .variant = .secondary },
    )) {
        if (profile_only and applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            editorText(update_url_editor),
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
            action.config_updated = true;
            action.save = true;
        }
        action.node_profile_apply_client = true;
    }
    cursor_x += client_w + t.spacing.sm;

    const service_label = "Service Node";
    const service_w = buttonWidth(dc, service_label, t);
    if (widgets.button.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ service_w, button_height }),
        service_label,
        queue,
        .{ .variant = .primary, .disabled = !has_url },
    )) {
        if (profile_only and applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            editorText(update_url_editor),
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
            action.config_updated = true;
            action.save = true;
        }
        action.node_profile_apply_service = true;
    }
    cursor_x += service_w + t.spacing.sm;
    const session_label = "User Session Node";
    const session_w = buttonWidth(dc, session_label, t);
    if (widgets.button.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ session_w, button_height }),
        session_label,
        queue,
        .{ .variant = .primary, .disabled = !has_url },
    )) {
        if (profile_only and applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            editorText(update_url_editor),
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
            action.config_updated = true;
            action.save = true;
        }
        action.node_profile_apply_session = true;
    }
    cursor_y += button_height + t.spacing.sm;

    if (!profile_only) {
        dc.drawText(
            "Advanced manual controls",
            .{ content_x, cursor_y },
            .{ .color = t.colors.text_secondary },
        );
        cursor_y += line_height + t.spacing.sm;

        cursor_x = content_x;
        const install_label = "Install session task";
        const install_w = buttonWidth(dc, install_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ install_w, button_height }), install_label, queue, .{ .variant = .secondary })) {
            action.node_service_install_onlogon = true;
        }
        cursor_x += install_w + t.spacing.sm;

        const open_logs_label = "Open logs";
        const open_logs_w = buttonWidth(dc, open_logs_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ open_logs_w, button_height }), open_logs_label, queue, .{ .variant = .secondary })) {
            action.open_node_logs = true;
        }
        cursor_y += button_height + t.spacing.sm;

        cursor_x = content_x;
        const start_label = "Start";
        const start_w = buttonWidth(dc, start_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ start_w, button_height }), start_label, queue, .{ .variant = .secondary })) {
            action.node_service_start = true;
        }
        cursor_x += start_w + t.spacing.sm;

        const stop_label = "Stop";
        const stop_w = buttonWidth(dc, stop_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ stop_w, button_height }), stop_label, queue, .{ .variant = .secondary })) {
            action.node_service_stop = true;
        }
        cursor_x += stop_w + t.spacing.sm;

        const status_label = "Status";
        const status_w = buttonWidth(dc, status_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ status_w, button_height }), status_label, queue, .{ .variant = .ghost })) {
            action.node_service_status = true;
        }
        cursor_x += status_w + t.spacing.sm;

        const uninstall_label = "Uninstall";
        const uninstall_w = buttonWidth(dc, uninstall_label, t);
        if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ cursor_x, cursor_y }, .{ uninstall_w, button_height }), uninstall_label, queue, .{ .variant = .ghost })) {
            action.node_service_uninstall = true;
        }
    }

    if (!has_url) {
        const hint = if (!profile_only and server_url_dirty)
            "(Apply/Save Server URL changes before applying service/session profiles)"
        else
            "(Set Server URL above before applying service/session profiles)";
        // Tiny hint; keep it subtle.
        dc.drawText(
            hint,
            .{ content_x, cursor_y + button_height + t.spacing.xs },
            .{ .color = t.colors.text_secondary },
        );
    }

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
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const button_height = widgets.button.defaultHeight(t, line_height);
    const progress_height: f32 = 10.0;

    const height = calcUpdatesHeight(snapshot, t, line_height, input_height, button_height, progress_height);
    const rect = draw_context.Rect.fromMinSize(.{ x, y }, .{ width, height });
    const base = drawCardBase(dc, rect, "Updates");
    const inner = base.inner_rect;
    var cursor_y = base.cursor_y;
    const content_x = inner.min[0] + padding;
    const content_w = inner.size()[0] - padding * 2.0;

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
        if (applyConfig(
            allocator,
            cfg,
            editorText(server_editor),
            editorText(connect_host_editor),
            editorText(token_editor),
            update_url_text,
            editorText(theme_pack_editor),
            profileLabel(profile_choice),
        )) {
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

const CardBase = struct {
    inner_rect: draw_context.Rect,
    cursor_y: f32,
};

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) CardBase {
    const t = dc.theme;
    const ss = theme_runtime.getStyleSheet();
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    const radius = ss.panel.radius orelse t.radius.md;
    panel_chrome.draw(dc, rect, .{
        .radius = radius,
        .draw_shadow = true,
        .draw_frame = true,
        .draw_border = true,
    });
    const inner_rect = panel_chrome.contentRect(rect);
    theme.pushFor(t, .heading);
    dc.drawText(title, .{ inner_rect.min[0] + padding, inner_rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return .{
        .inner_rect = inner_rect,
        .cursor_y = inner_rect.min[1] + padding + line_height + t.spacing.xs,
    };
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
    const t = dc.theme;
    const line_height = dc.lineHeight();
    dc.drawText(label, .{ x, y }, .{ .color = t.colors.text_primary });
    const input_height = widgets.text_input.defaultHeight(t, line_height);
    const input_rect = draw_context.Rect.fromMinSize(.{ x, y + line_height + t.spacing.xs }, .{ width, input_height });
    nav_router.pushScope(std.hash.Wyhash.hash(0, label));
    _ = widgets.text_input.draw(editor, allocator, dc, input_rect, queue, opts);
    nav_router.popScope();
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
    const t = dc.theme;
    const line_height = dc.lineHeight();
    const row_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
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
    const t = dc.theme;
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
    const t = dc.theme;
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
    widgets.kinetic_scroll.apply(queue, rect, scroll, max_scroll, step);
}

fn drawDownloadOverlay(
    dc: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    snapshot: update_checker.Snapshot,
) void {
    const t = dc.theme;
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
    const button_height = widgets.button.defaultHeight(t, line_height);
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
    theme.pushFor(t, .heading);
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
    theme_pack_text: []const u8,
    profile_label: ?[]const u8,
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

    if (!theme_runtime.getPackModeLockToDefault()) {
        const desired_mode: theme.Mode = if (theme_is_light) .light else .dark;
        const desired_label = theme.labelForMode(desired_mode);
        const current_mode: theme.Mode = if (cfg.ui_theme) |label|
            theme.modeFromLabel(label)
        else
            theme_runtime.getPackDefaultMode() orelse .light;
        const current_label = theme.labelForMode(current_mode);
        if (!std.mem.eql(u8, current_label, desired_label)) {
            if (cfg.ui_theme) |value| allocator.free(value);
            cfg.ui_theme = allocator.dupe(u8, desired_label) catch return changed;
            changed = true;
        }
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

    const current_theme_pack = cfg.ui_theme_pack orelse "";
    if (!std.mem.eql(u8, current_theme_pack, theme_pack_text)) {
        if (cfg.ui_theme_pack) |value| {
            allocator.free(value);
            cfg.ui_theme_pack = null;
        }
        if (theme_pack_text.len > 0) {
            cfg.ui_theme_pack = allocator.dupe(u8, theme_pack_text) catch return changed;
        }
        changed = true;
    }

    const desired_profile = profile_label orelse "";
    const current_profile = cfg.ui_profile orelse "";
    if (!std.mem.eql(u8, current_profile, desired_profile)) {
        if (cfg.ui_profile) |value| {
            allocator.free(value);
            cfg.ui_profile = null;
        }
        if (profile_label) |label| {
            cfg.ui_profile = allocator.dupe(u8, label) catch return changed;
        }
        changed = true;
    }

    return changed;
}

fn applyAppearanceConfig(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    theme_pack_text: []const u8,
    profile_label: ?[]const u8,
) bool {
    var changed = false;

    if (cfg.ui_watch_theme_pack != watch_theme_pack_value) {
        cfg.ui_watch_theme_pack = watch_theme_pack_value;
        changed = true;
    }

    if (!theme_runtime.getPackModeLockToDefault()) {
        const desired_mode: theme.Mode = if (theme_is_light) .light else .dark;
        const desired_label = theme.labelForMode(desired_mode);
        const current_mode: theme.Mode = if (cfg.ui_theme) |label|
            theme.modeFromLabel(label)
        else
            theme_runtime.getPackDefaultMode() orelse .light;
        const current_label = theme.labelForMode(current_mode);
        if (!std.mem.eql(u8, current_label, desired_label)) {
            if (cfg.ui_theme) |value| allocator.free(value);
            cfg.ui_theme = allocator.dupe(u8, desired_label) catch return changed;
            changed = true;
        }
    }

    const current_theme_pack = cfg.ui_theme_pack orelse "";
    if (!std.mem.eql(u8, current_theme_pack, theme_pack_text)) {
        if (cfg.ui_theme_pack) |value| {
            allocator.free(value);
            cfg.ui_theme_pack = null;
        }
        if (theme_pack_text.len > 0) {
            cfg.ui_theme_pack = allocator.dupe(u8, theme_pack_text) catch return changed;
        }
        changed = true;
    }

    const desired_profile = profile_label orelse "";
    const current_profile = cfg.ui_profile orelse "";
    if (!std.mem.eql(u8, current_profile, desired_profile)) {
        if (cfg.ui_profile) |value| {
            allocator.free(value);
            cfg.ui_profile = null;
        }
        if (profile_label) |label| {
            cfg.ui_profile = allocator.dupe(u8, label) catch return changed;
        }
        changed = true;
    }

    return changed;
}
