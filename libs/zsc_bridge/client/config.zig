const std = @import("std");

pub const Config = struct {
    server_url: []const u8,
    token: []const u8,
    insecure_tls: bool = false,
    auto_connect_on_launch: bool = true,
    connect_host_override: ?[]const u8 = null,
    update_manifest_url: ?[]const u8 = null,
    default_session: ?[]const u8 = null,
    default_node: ?[]const u8 = null,
    ui_theme: ?[]const u8 = null,
    ui_theme_pack: ?[]const u8 = null,
    /// When enabled, the client will periodically check the active theme pack folder for JSON changes
    /// and auto-reload the pack (native desktop builds only).
    ui_watch_theme_pack: bool = false,
    /// Most-recently-used theme pack paths (portable `themes/<id>` or absolute paths).
    ui_theme_pack_recent: ?[]const []const u8 = null,
    ui_profile: ?[]const u8 = null,

    // Optional: run a local node host alongside the UI client (Android primarily).
    //
    // Token design: for node-mode, WS Authorization + connect.auth.token must match.
    // If node_host_token is not set, we fall back to `token`.
    enable_node_host: bool = false,
    node_host_token: ?[]const u8 = null,
    node_host_display_name: ?[]const u8 = null,
    node_host_device_identity_path: ?[]const u8 = null,
    node_host_exec_approvals_path: ?[]const u8 = null,
    node_host_heartbeat_interval_ms: ?i64 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.server_url);
        allocator.free(self.token);
        if (self.connect_host_override) |value| {
            allocator.free(value);
        }
        if (self.update_manifest_url) |value| {
            allocator.free(value);
        }
        if (self.default_session) |value| {
            allocator.free(value);
        }
        if (self.default_node) |value| {
            allocator.free(value);
        }
        if (self.ui_theme) |value| {
            allocator.free(value);
        }
        if (self.ui_theme_pack) |value| {
            allocator.free(value);
        }
        if (self.ui_theme_pack_recent) |list| {
            for (list) |item| allocator.free(item);
            allocator.free(list);
        }
        if (self.ui_profile) |value| {
            allocator.free(value);
        }
        if (self.node_host_token) |value| {
            allocator.free(value);
        }
        if (self.node_host_display_name) |value| {
            allocator.free(value);
        }
        if (self.node_host_device_identity_path) |value| {
            allocator.free(value);
        }
        if (self.node_host_exec_approvals_path) |value| {
            allocator.free(value);
        }
    }
};

/// Back-compat / UX migration: older configs used a repo-relative docs path for the example pack.
/// New builds install example packs next to the executable at `themes/<id>`.
pub fn migrateThemePackPath(allocator: std.mem.Allocator, cfg: *Config) bool {
    const current = cfg.ui_theme_pack orelse return false;
    const docs_prefix = "docs/theme_engine/examples/";
    if (!std.mem.startsWith(u8, current, docs_prefix)) return false;
    const suffix = current[docs_prefix.len..];
    if (suffix.len == 0) return false;

    const migrated = std.fmt.allocPrint(allocator, "themes/{s}", .{suffix}) catch return false;
    if (cfg.ui_theme_pack) |old| allocator.free(old);
    cfg.ui_theme_pack = migrated;
    return true;
}

pub fn initDefault(allocator: std.mem.Allocator) !Config {
    return .{
        .server_url = try allocator.dupe(u8, ""),
        .token = try allocator.dupe(u8, ""),
        .insecure_tls = false,
        .auto_connect_on_launch = true,
        .connect_host_override = null,
        .update_manifest_url = try allocator.dupe(
            u8,
            "https://github.com/DeanoC/ZiggyStarClaw/releases/latest/download/update.json",
        ),
        .default_session = null,
        .default_node = null,
        .ui_theme = null,
        .ui_theme_pack = null,
        .ui_watch_theme_pack = false,
        .ui_theme_pack_recent = null,
        .ui_profile = null,

        .enable_node_host = false,
        .node_host_token = null,
        .node_host_display_name = null,
        .node_host_device_identity_path = null,
        .node_host_exec_approvals_path = null,
        .node_host_heartbeat_interval_ms = null,
    };
}

pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try initDefault(allocator),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(Config, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return .{
        .server_url = try allocator.dupe(u8, parsed.value.server_url),
        .token = try allocator.dupe(u8, parsed.value.token),
        .insecure_tls = parsed.value.insecure_tls,
        .auto_connect_on_launch = parsed.value.auto_connect_on_launch,
        .connect_host_override = if (parsed.value.connect_host_override) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .update_manifest_url = if (parsed.value.update_manifest_url) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .default_session = if (parsed.value.default_session) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .default_node = if (parsed.value.default_node) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .ui_theme = if (parsed.value.ui_theme) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .ui_theme_pack = if (parsed.value.ui_theme_pack) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .ui_watch_theme_pack = parsed.value.ui_watch_theme_pack,
        .ui_theme_pack_recent = if (parsed.value.ui_theme_pack_recent) |list| blk: {
            var out = try allocator.alloc([]const u8, list.len);
            var written: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < written) : (i += 1) allocator.free(out[i]);
                allocator.free(out);
            }
            for (list, 0..) |item, i| {
                out[i] = try allocator.dupe(u8, item);
                written += 1;
            }
            break :blk out;
        } else null,
        .ui_profile = if (parsed.value.ui_profile) |value|
            try allocator.dupe(u8, value)
        else
            null,

        .enable_node_host = parsed.value.enable_node_host,
        .node_host_token = if (parsed.value.node_host_token) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .node_host_display_name = if (parsed.value.node_host_display_name) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .node_host_device_identity_path = if (parsed.value.node_host_device_identity_path) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .node_host_exec_approvals_path = if (parsed.value.node_host_exec_approvals_path) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .node_host_heartbeat_interval_ms = parsed.value.node_host_heartbeat_interval_ms,
    };
}

pub fn pushRecentThemePack(allocator: std.mem.Allocator, cfg: *Config, pack_path: []const u8) bool {
    if (pack_path.len == 0) return false;

    const max_items: usize = 8;
    const current = cfg.ui_theme_pack_recent orelse &[_][]const u8{};

    // Fast path: already top.
    if (current.len > 0 and std.mem.eql(u8, current[0], pack_path)) return false;

    var new_len: usize = 1;
    for (current) |item| {
        if (new_len >= max_items) break;
        if (std.mem.eql(u8, item, pack_path)) continue;
        new_len += 1;
    }

    var out = allocator.alloc([]const u8, new_len) catch return false;
    var written: usize = 0;

    out[written] = allocator.dupe(u8, pack_path) catch {
        allocator.free(out);
        return false;
    };
    written += 1;

    for (current) |item| {
        if (written >= new_len) break;
        if (std.mem.eql(u8, item, pack_path)) continue;
        out[written] = allocator.dupe(u8, item) catch {
            var i: usize = 0;
            while (i < written) : (i += 1) allocator.free(out[i]);
            allocator.free(out);
            return false;
        };
        written += 1;
    }

    // Free previous list.
    if (cfg.ui_theme_pack_recent) |list| {
        for (list) |item| allocator.free(item);
        allocator.free(list);
    }
    cfg.ui_theme_pack_recent = out;
    return true;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, cfg: Config) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, cfg, .{
        .emit_null_optional_fields = false,
        .whitespace = .indent_2,
    });
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}
