const std = @import("std");
const zgui = @import("zgui");
const config = @import("../client/config.zig");
const state = @import("../client/state.zig");

pub const SettingsAction = struct {
    connect: bool = false,
    disconnect: bool = false,
    save: bool = false,
    config_updated: bool = false,
};

var server_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var token_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var insecure_tls_value = false;
var initialized = false;

pub fn draw(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    client_state: state.ClientState,
    is_connected: bool,
) SettingsAction {
    var action = SettingsAction{};

    if (!initialized) {
        syncBuffers(cfg.*);
    }

    if (zgui.beginChild("Settings", .{ .h = 0.0, .child_flags = .{ .border = true } })) {
        zgui.text("Connection", .{});

        _ = zgui.inputText("Server URL", .{ .buf = server_buf[0.. :0] });
        _ = zgui.inputText("Token", .{ .buf = token_buf[0.. :0], .flags = .{ .password = true } });
        _ = zgui.checkbox("Insecure TLS (skip cert verification)", .{ .v = &insecure_tls_value });

        const server_text = std.mem.sliceTo(&server_buf, 0);
        const token_text = std.mem.sliceTo(&token_buf, 0);
        const dirty = !std.mem.eql(u8, server_text, cfg.server_url) or
            !std.mem.eql(u8, token_text, cfg.token) or
            insecure_tls_value != cfg.insecure_tls;

        zgui.beginDisabled(.{ .disabled = !dirty });
        if (zgui.button("Apply", .{})) {
            if (applyConfig(allocator, cfg, server_text, token_text)) {
                action.config_updated = true;
            }
        }
        zgui.endDisabled();

        zgui.sameLine(.{});
        if (zgui.button("Save", .{})) {
            action.save = true;
        }

        zgui.separator();

        if (is_connected) {
            if (zgui.button("Disconnect", .{})) {
                action.disconnect = true;
            }
        } else {
            if (zgui.button("Connect", .{})) {
                if (dirty and applyConfig(allocator, cfg, server_text, token_text)) {
                    action.config_updated = true;
                }
                action.connect = true;
            }
        }
        zgui.textWrapped("State: {s}", .{@tagName(client_state)});
    }
    zgui.endChild();

    return action;
}

fn syncBuffers(cfg: config.Config) void {
    initialized = true;
    fillBuffer(&server_buf, cfg.server_url);
    fillBuffer(&token_buf, cfg.token);
    insecure_tls_value = cfg.insecure_tls;
}

fn fillBuffer(buf: *[256:0]u8, value: []const u8) void {
    @memset(buf, 0);
    const len = @min(value.len, buf.len - 1);
    @memcpy(buf[0..len], value[0..len]);
    buf[len] = 0;
}

fn applyConfig(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    server_text: []const u8,
    token_text: []const u8,
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

    if (cfg.insecure_tls != insecure_tls_value) {
        cfg.insecure_tls = insecure_tls_value;
        changed = true;
    }

    return changed;
}
