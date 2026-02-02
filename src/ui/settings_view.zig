const std = @import("std");
const builtin = @import("builtin");
const zgui = @import("zgui");
const config = @import("../client/config.zig");
const state = @import("../client/state.zig");
const update_checker = @import("../client/update_checker.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

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

var server_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var token_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var connect_host_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var update_url_buf: [512:0]u8 = [_:0]u8{0} ** 512;
var insecure_tls_value = false;
var auto_connect_value = true;
var theme_is_light = true;
var initialized = false;
var download_popup_opened = false;

pub fn draw(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    client_state: state.ClientState,
    is_connected: bool,
    update_state: *update_checker.UpdateState,
    app_version: []const u8,
) SettingsAction {
    var action = SettingsAction{};
    const show_insecure_tls = builtin.target.os.tag != .emscripten;

    if (!initialized) {
        syncBuffers(cfg.*);
    }

    if (zgui.beginChild("Settings", .{ .h = 0.0, .child_flags = .{ .border = true } })) {
        const spacing = theme.activeTheme().spacing.md;

        if (components.layout.card.begin(.{ .title = "Appearance", .id = "appearance" })) {
            var use_light_theme = theme_is_light;
            if (zgui.checkbox("Light theme", .{ .v = &use_light_theme })) {
                theme_is_light = use_light_theme;
                theme.setMode(if (theme_is_light) .light else .dark);
                theme.apply();
            }
        }
        components.layout.card.end();
        zgui.dummy(.{ .w = 0.0, .h = spacing });

        if (components.layout.card.begin(.{ .title = "Connection", .id = "connection" })) {
            _ = zgui.inputText("Server URL", .{ .buf = server_buf[0.. :0] });
            _ = zgui.inputText("Connect Host (override)", .{ .buf = connect_host_buf[0.. :0] });
            zgui.textWrapped("Override can include :port (e.g. 100.108.141.120:18789).", .{});
            _ = zgui.inputText("Token", .{ .buf = token_buf[0.. :0], .flags = .{ .password = true } });
            if (show_insecure_tls) {
                _ = zgui.checkbox(
                    "Insecure TLS (skip cert verification)",
                    .{ .v = &insecure_tls_value },
                );
            }
            _ = zgui.checkbox("Auto-connect on launch", .{ .v = &auto_connect_value });

            const server_text = std.mem.sliceTo(&server_buf, 0);
            const connect_host_text = std.mem.sliceTo(&connect_host_buf, 0);
            const token_text = std.mem.sliceTo(&token_buf, 0);
            const update_url_text = std.mem.sliceTo(&update_url_buf, 0);
            const theme_default_light = theme.modeFromLabel(cfg.ui_theme) == .light;
            const dirty = !std.mem.eql(u8, server_text, cfg.server_url) or
                !std.mem.eql(u8, token_text, cfg.token) or
                !std.mem.eql(u8, connect_host_text, cfg.connect_host_override orelse "") or
                !std.mem.eql(u8, update_url_text, cfg.update_manifest_url orelse "") or
                theme_is_light != theme_default_light or
                (show_insecure_tls and insecure_tls_value != cfg.insecure_tls) or
                auto_connect_value != cfg.auto_connect_on_launch;

            if (components.core.button.draw("Apply", .{ .disabled = !dirty, .variant = .primary })) {
                if (applyConfig(allocator, cfg, server_text, connect_host_text, token_text, update_url_text)) {
                    action.config_updated = true;
                }
            }

            zgui.sameLine(.{});
            if (components.core.button.draw("Save", .{ .variant = .secondary })) {
                action.save = true;
            }
            zgui.sameLine(.{});
            if (components.core.button.draw("Clear Saved", .{ .variant = .ghost })) {
                action.clear_saved = true;
            }

            zgui.separator();

            if (is_connected) {
                if (components.core.button.draw("Disconnect", .{ .variant = .danger })) {
                    action.disconnect = true;
                }
            } else {
                if (components.core.button.draw("Connect", .{ .variant = .primary })) {
                    if (dirty and applyConfig(allocator, cfg, server_text, connect_host_text, token_text, update_url_text)) {
                        action.config_updated = true;
                    }
                    action.connect = true;
                }
            }
            zgui.text("State:", .{});
            zgui.sameLine(.{ .spacing = theme.activeTheme().spacing.sm });
            const state_variant: components.core.badge.Variant = switch (client_state) {
                .connected => .success,
                .connecting, .authenticating => .warning,
                .error_state => .danger,
                .disconnected => if (is_connected) .success else .neutral,
            };
            components.core.badge.draw(@tagName(client_state), .{
                .variant = state_variant,
                .filled = true,
                .size = .small,
            });
        }
        components.layout.card.end();
        zgui.dummy(.{ .w = 0.0, .h = spacing });

        const snapshot = update_state.snapshot();
        if (components.layout.card.begin(.{ .title = "Updates", .id = "updates" })) {
            _ = zgui.inputText("Update Manifest URL", .{ .buf = update_url_buf[0.. :0] });
            zgui.textWrapped("Current version: {s}", .{app_version});
            const check_state: components.data.progress_step.State = switch (snapshot.status) {
                .checking => .active,
                .up_to_date, .update_available => .complete,
                .failed, .unsupported => .failed,
                .idle => .pending,
            };
            const download_state: components.data.progress_step.State = switch (snapshot.download_status) {
                .downloading => .active,
                .complete => .complete,
                .failed, .unsupported => .failed,
                .idle => .pending,
            };
            var detail_buf: [256]u8 = undefined;
            const progress_detail: ?[]const u8 = switch (snapshot.status) {
                .checking => "Checking for updates...",
                .up_to_date => "Up to date.",
                .update_available => switch (snapshot.download_status) {
                    .downloading => "Downloading update...",
                    .complete => "Update downloaded.",
                    .failed => "Download failed.",
                    .unsupported => "Download unsupported.",
                    .idle => "Update available.",
                },
                .failed => std.fmt.bufPrint(
                    &detail_buf,
                    "Error: {s}",
                    .{snapshot.error_message orelse "unknown"},
                ) catch "Error: unknown",
                .unsupported => std.fmt.bufPrint(
                    &detail_buf,
                    "Unsupported: {s}",
                    .{snapshot.error_message orelse "not supported"},
                ) catch "Unsupported",
                .idle => null,
            };
            _ = components.composite.task_progress.draw(.{
                .title = "Update Progress",
                .steps = &[_]components.composite.task_progress.Step{
                    .{ .label = "Check", .state = check_state },
                    .{ .label = "Download", .state = download_state },
                },
                .detail = progress_detail,
                .show_logs_button = false,
            });
            zgui.dummy(.{ .w = 0.0, .h = spacing });

            const update_url_text = std.mem.sliceTo(&update_url_buf, 0);
            if (components.core.button.draw("Check Updates", .{ .disabled = snapshot.in_flight or update_url_text.len == 0, .variant = .secondary })) {
                const server_text = std.mem.sliceTo(&server_buf, 0);
                const connect_host_text = std.mem.sliceTo(&connect_host_buf, 0);
                const token_text = std.mem.sliceTo(&token_buf, 0);
                if (applyConfig(allocator, cfg, server_text, connect_host_text, token_text, update_url_text)) {
                    action.config_updated = true;
                }
                action.check_updates = true;
            }
            zgui.text("Status:", .{});
            zgui.sameLine(.{ .spacing = theme.activeTheme().spacing.sm });
            const update_variant: components.core.badge.Variant = switch (snapshot.status) {
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
            components.core.badge.draw(update_label, .{
                .variant = update_variant,
                .filled = true,
                .size = .small,
            });
            if (snapshot.status == .update_available) {
                if (snapshot.latest_version) |ver| {
                    zgui.textWrapped("Latest: {s}", .{ver});
                }
            }

            if (snapshot.status == .update_available) {
                const fallback_release = "https://github.com/DeanoC/ZiggyStarClaw/releases/latest";
                const release_url = snapshot.release_url orelse fallback_release;
                zgui.textWrapped("Release: {s}", .{release_url});
                if (components.core.button.draw("Open Release Page", .{ .variant = .secondary })) {
                    action.open_release = true;
                }
                if (snapshot.download_sha256) |sha| {
                    zgui.textWrapped("SHA256: {s}", .{sha});
                }
                if (snapshot.download_url != null and snapshot.download_status == .idle) {
                    zgui.sameLine(.{});
                    if (components.core.button.draw("Download Update", .{ .variant = .primary })) {
                        action.download_update = true;
                    }
                }
                if (snapshot.download_status == .failed) {
                    zgui.textWrapped("Download failed: {s}", .{snapshot.download_error_message orelse "unknown"});
                }
                if (snapshot.download_status == .unsupported) {
                    zgui.textWrapped(
                        "Download unsupported: {s}",
                        .{snapshot.download_error_message orelse "not supported"},
                    );
                }
                if (snapshot.download_status == .complete) {
                    if (snapshot.download_sha256 != null) {
                        const verify_status = if (snapshot.download_verified) "verified" else "not verified";
                        zgui.textWrapped("Download complete ({s}).", .{verify_status});
                    } else {
                        zgui.textWrapped("Download complete.", .{});
                    }
                    if (snapshot.download_path != null) {
                        if (components.core.button.draw("Open Downloaded File", .{ .variant = .secondary })) {
                            action.open_download = true;
                        }
                        if (builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .macos) {
                            zgui.sameLine(.{});
                            if (components.core.button.draw("Install Update", .{ .variant = .primary })) {
                                action.install_update = true;
                            }
                        }
                    }
                }
            }
        }
        components.layout.card.end();

        if (snapshot.download_status == .downloading) {
            if (!download_popup_opened) {
                zgui.openPopup("Downloading Update", .{});
                download_popup_opened = true;
            }
        } else {
            download_popup_opened = false;
        }

        if (zgui.beginPopupModal(
            "Downloading Update",
            .{ .popen = &download_popup_opened, .flags = .{ .always_auto_resize = true } },
        )) {
            zgui.text("Downloading update...", .{});
            const total = snapshot.download_total orelse 0;
            const progress = if (total > 0)
                @as(f32, @floatFromInt(snapshot.download_bytes)) / @as(f32, @floatFromInt(total))
            else
                0.0;
            var overlay_buf: [64:0]u8 = [_:0]u8{0} ** 64;
            const overlay = if (total > 0)
                std.fmt.bufPrintZ(&overlay_buf, "{d}/{d} bytes", .{
                    snapshot.download_bytes,
                    total,
                }) catch null
            else
                std.fmt.bufPrintZ(&overlay_buf, "{d} bytes", .{snapshot.download_bytes}) catch null;
            zgui.progressBar(.{ .fraction = progress, .overlay = overlay });
            if (snapshot.download_status != .downloading) {
                if (zgui.button("Close", .{})) {
                    zgui.closeCurrentPopup();
                }
            }
            zgui.endPopup();
        }
    }
    zgui.endChild();

    return action;
}

pub fn syncFromConfig(cfg: config.Config) void {
    syncBuffers(cfg);
}

fn syncBuffers(cfg: config.Config) void {
    initialized = true;
    fillBuffer(server_buf[0..], cfg.server_url);
    fillBuffer(connect_host_buf[0..], cfg.connect_host_override orelse "");
    fillBuffer(token_buf[0..], cfg.token);
    fillBuffer(update_url_buf[0..], cfg.update_manifest_url orelse "");
    insecure_tls_value = cfg.insecure_tls;
    auto_connect_value = cfg.auto_connect_on_launch;
    theme_is_light = theme.modeFromLabel(cfg.ui_theme) == .light;
}

fn fillBuffer(buf: []u8, value: []const u8) void {
    if (buf.len == 0) return;
    @memset(buf, 0);
    const len = @min(value.len, buf.len - 1);
    @memcpy(buf[0..len], value[0..len]);
    buf[len] = 0;
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
