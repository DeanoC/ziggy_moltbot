const std = @import("std");
const config_mod = @import("config.zig");
const Config = config_mod.Config;

/// Profile represents a single gateway configuration
pub const Profile = struct {
    name: []const u8,
    server_url: []const u8,
    token: []const u8,
    insecure_tls: bool = false,
    connect_host_override: ?[]const u8 = null,
    default_session: ?[]const u8 = null,
    default_node: ?[]const u8 = null,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.server_url);
        allocator.free(self.token);
        if (self.connect_host_override) |v| allocator.free(v);
        if (self.default_session) |v| allocator.free(v);
        if (self.default_node) |v| allocator.free(v);
    }

    pub fn toConfig(self: Profile, allocator: std.mem.Allocator) !Config {
        return .{
            .server_url = try allocator.dupe(u8, self.server_url),
            .token = try allocator.dupe(u8, self.token),
            .insecure_tls = self.insecure_tls,
            .auto_connect_on_launch = true,
            .connect_host_override = if (self.connect_host_override) |v|
                try allocator.dupe(u8, v)
            else
                null,
            .update_manifest_url = try allocator.dupe(u8, "https://github.com/DeanoC/ZiggyStarClaw/releases/latest/download/update.json"),
            .default_session = if (self.default_session) |v|
                try allocator.dupe(u8, v)
            else
                null,
            .default_node = if (self.default_node) |v|
                try allocator.dupe(u8, v)
            else
                null,
            .ui_theme = null,
            .ui_theme_pack = null,
            .ui_watch_theme_pack = false,
            .ui_theme_pack_recent = null,
            .ui_profile = try allocator.dupe(u8, self.name),

            .enable_node_host = false,
            .node_host_token = null,
            .node_host_display_name = null,
            .node_host_device_identity_path = null,
            .node_host_exec_approvals_path = null,
            .node_host_heartbeat_interval_ms = null,
        };
    }
};

/// Profiles manages multiple gateway configurations
pub const Profiles = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(Profile),
    active: ?[]const u8, // name of active profile

    pub fn init(allocator: std.mem.Allocator) Profiles {
        return .{
            .allocator = allocator,
            .profiles = .empty,
            .active = null,
        };
    }

    pub fn deinit(self: *Profiles) void {
        for (self.profiles.items) |*profile| {
            profile.deinit(self.allocator);
        }
        self.profiles.deinit(self.allocator);
        if (self.active) |name| {
            self.allocator.free(name);
        }
    }

    pub fn load(self: *Profiles, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Create default profiles
                try self.addDefaultProfiles();
                return;
            },
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        var parsed = try std.json.parseFromSlice(JsonProfiles, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Load active profile
        if (parsed.value.active) |active_name| {
            self.active = try self.allocator.dupe(u8, active_name);
        }

        // Load profiles
        if (parsed.value.profiles) |json_profiles| {
            for (json_profiles) |jp| {
                const profile = Profile{
                    .name = try self.allocator.dupe(u8, jp.name),
                    .server_url = try self.allocator.dupe(u8, jp.server_url),
                    .token = try self.allocator.dupe(u8, jp.token),
                    .insecure_tls = jp.insecure_tls,
                    .connect_host_override = if (jp.connect_host_override) |v|
                        try self.allocator.dupe(u8, v)
                    else
                        null,
                    .default_session = if (jp.default_session) |v|
                        try self.allocator.dupe(u8, v)
                    else
                        null,
                    .default_node = if (jp.default_node) |v|
                        try self.allocator.dupe(u8, v)
                    else
                        null,
                };
                try self.profiles.append(self.allocator, profile);
            }
        }
    }

    pub fn save(self: Profiles, path: []const u8) !void {
        // Ensure directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makeDir(dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        // Build JSON struct
        var json_profiles = try self.allocator.alloc(JsonProfile, self.profiles.items.len);
        defer self.allocator.free(json_profiles);

        for (self.profiles.items, 0..) |profile, i| {
            json_profiles[i] = .{
                .name = profile.name,
                .server_url = profile.server_url,
                .token = profile.token,
                .insecure_tls = profile.insecure_tls,
                .connect_host_override = profile.connect_host_override,
                .default_session = profile.default_session,
                .default_node = profile.default_node,
            };
        }

        const json_data = JsonProfiles{
            .active = self.active,
            .profiles = json_profiles,
        };

        const json = try std.json.Stringify.valueAlloc(self.allocator, json_data, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
        defer self.allocator.free(json);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        try file.writeAll(json);
    }

    pub fn add(self: *Profiles, name: []const u8, server_url: []const u8, token: []const u8) !void {
        // Remove existing profile with same name
        self.remove(name);

        const profile = Profile{
            .name = try self.allocator.dupe(u8, name),
            .server_url = try self.allocator.dupe(u8, server_url),
            .token = try self.allocator.dupe(u8, token),
            .insecure_tls = false,
            .connect_host_override = null,
            .default_session = null,
            .default_node = null,
        };
        try self.profiles.append(self.allocator, profile);
    }

    pub fn remove(self: *Profiles, name: []const u8) void {
        for (self.profiles.items, 0..) |profile, i| {
            if (std.mem.eql(u8, profile.name, name)) {
                var p = self.profiles.orderedRemove(i);
                p.deinit(self.allocator);
                break;
            }
        }
    }

    pub fn get(self: Profiles, name: []const u8) ?Profile {
        for (self.profiles.items) |profile| {
            if (std.mem.eql(u8, profile.name, name)) {
                return profile;
            }
        }
        return null;
    }

    pub fn setActive(self: *Profiles, name: []const u8) !void {
        // Verify profile exists
        if (self.get(name) == null) return error.ProfileNotFound;

        if (self.active) |old| {
            self.allocator.free(old);
        }
        self.active = try self.allocator.dupe(u8, name);
    }

    pub fn getActiveProfile(self: Profiles) ?Profile {
        const name = self.active orelse return null;
        return self.get(name);
    }

    pub fn listNames(self: Profiles, allocator: std.mem.Allocator) ![][]const u8 {
        var names = try allocator.alloc([]const u8, self.profiles.items.len);
        for (self.profiles.items, 0..) |profile, i| {
            names[i] = try allocator.dupe(u8, profile.name);
        }
        return names;
    }

    fn addDefaultProfiles(self: *Profiles) !void {
        // Spiderweb (local dev gateway)
        try self.add("spiderweb", "ws://127.0.0.1:18790", "");
        try self.setActive("spiderweb");
    }

    // JSON serialization structs
    const JsonProfile = struct {
        name: []const u8,
        server_url: []const u8,
        token: []const u8,
        insecure_tls: bool = false,
        connect_host_override: ?[]const u8 = null,
        default_session: ?[]const u8 = null,
        default_node: ?[]const u8 = null,
    };

    const JsonProfiles = struct {
        active: ?[]const u8 = null,
        profiles: ?[]JsonProfile = null,
    };
};

/// Get the default profiles file path
pub fn defaultProfilesPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return allocator.dupe(u8, ".zsc-profiles.json");
    };
    defer allocator.free(home);

    return try std.fs.path.join(allocator, &.{ home, ".config", "ziggystarclaw", "profiles.json" });
}

test "Profiles add and get" {
    const allocator = std.testing.allocator;
    var profiles = Profiles.init(allocator);
    defer profiles.deinit();

    try profiles.add("test", "ws://test.com", "token123");

    const p = profiles.get("test").?;
    try std.testing.expectEqualStrings("test", p.name);
    try std.testing.expectEqualStrings("ws://test.com", p.server_url);
}

test "Profiles active" {
    const allocator = std.testing.allocator;
    var profiles = Profiles.init(allocator);
    defer profiles.deinit();

    try profiles.add("main", "ws://main.com", "");
    try profiles.add("dev", "ws://dev.com", "");

    try profiles.setActive("dev");
    const active = profiles.getActiveProfile().?;
    try std.testing.expectEqualStrings("dev", active.name);
}

test "Profiles save preserves profile-owned optional fields" {
    const allocator = std.testing.allocator;

    var profiles = Profiles.init(allocator);
    defer profiles.deinit();

    try profiles.add("main", "ws://main.com", "token");

    profiles.profiles.items[0].connect_host_override = try allocator.dupe(u8, "gateway.local");
    profiles.profiles.items[0].default_session = try allocator.dupe(u8, "session-1");
    profiles.profiles.items[0].default_node = try allocator.dupe(u8, "node-1");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const tmp_root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(tmp_root);

    const profiles_path = try std.fs.path.join(allocator, &.{ tmp_root, "profiles.json" });
    defer allocator.free(profiles_path);

    try profiles.save(profiles_path);

    const saved = profiles.get("main").?;
    try std.testing.expectEqualStrings("gateway.local", saved.connect_host_override.?);
    try std.testing.expectEqualStrings("session-1", saved.default_session.?);
    try std.testing.expectEqualStrings("node-1", saved.default_node.?);
}
