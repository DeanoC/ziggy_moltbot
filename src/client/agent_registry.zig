const std = @import("std");
const session_keys = @import("session_keys.zig");

pub const AgentProfile = struct {
    id: []const u8,
    display_name: []const u8,
    icon: []const u8,
    soul_path: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    personality_path: ?[]const u8 = null,
    default_session_key: ?[]const u8 = null,
};

const AgentSnapshot = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    soul_path: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    personality_path: ?[]const u8 = null,
    default_session_key: ?[]const u8 = null,
};

const RegistrySnapshot = struct {
    version: u32 = 1,
    agents: []AgentSnapshot = &[_]AgentSnapshot{},
};

pub const AgentRegistry = struct {
    agents: std.ArrayList(AgentProfile),

    pub fn initEmpty(allocator: std.mem.Allocator) AgentRegistry {
        _ = allocator;
        return .{ .agents = std.ArrayList(AgentProfile).empty };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !AgentRegistry {
        var reg = AgentRegistry.initEmpty(allocator);
        try reg.ensureMain(allocator);
        return reg;
    }

    pub fn deinit(self: *AgentRegistry, allocator: std.mem.Allocator) void {
        for (self.agents.items) |*agent| {
            freeAgentProfile(allocator, agent);
        }
        self.agents.deinit(allocator);
    }

    pub fn ensureMain(self: *AgentRegistry, allocator: std.mem.Allocator) !void {
        if (self.find("main") != null) return;
        try self.addOwned(allocator, .{
            .id = try allocator.dupe(u8, "main"),
            .display_name = try allocator.dupe(u8, "Main"),
            .icon = try allocator.dupe(u8, "M"),
            .soul_path = null,
            .config_path = null,
            .personality_path = null,
            .default_session_key = null,
        });
    }

    pub fn find(self: *AgentRegistry, id: []const u8) ?*AgentProfile {
        for (self.agents.items) |*agent| {
            if (std.mem.eql(u8, agent.id, id)) return agent;
        }
        return null;
    }

    pub fn addOwned(self: *AgentRegistry, allocator: std.mem.Allocator, profile: AgentProfile) !void {
        if (!session_keys.isAgentIdValid(profile.id)) {
            freeAgentProfile(allocator, &profile);
            return error.InvalidAgentId;
        }
        if (self.find(profile.id) != null) {
            freeAgentProfile(allocator, &profile);
            return error.AgentAlreadyExists;
        }
        try self.agents.append(allocator, profile);
    }

    pub fn upsertOwned(self: *AgentRegistry, allocator: std.mem.Allocator, profile: AgentProfile) !void {
        if (!session_keys.isAgentIdValid(profile.id)) {
            freeAgentProfile(allocator, &profile);
            return error.InvalidAgentId;
        }
        for (self.agents.items, 0..) |*agent, index| {
            if (std.mem.eql(u8, agent.id, profile.id)) {
                freeAgentProfile(allocator, agent);
                self.agents.items[index] = profile;
                return;
            }
        }
        try self.agents.append(allocator, profile);
    }

    pub fn remove(self: *AgentRegistry, allocator: std.mem.Allocator, id: []const u8) bool {
        var index: usize = 0;
        while (index < self.agents.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.agents.items[index].id, id)) {
                var removed = self.agents.orderedRemove(index);
                freeAgentProfile(allocator, &removed);
                return true;
            }
        }
        return false;
    }

    pub fn setDefaultSession(self: *AgentRegistry, allocator: std.mem.Allocator, id: []const u8, session_key: []const u8) !bool {
        if (self.find(id)) |agent| {
            if (agent.default_session_key) |existing| {
                if (std.mem.eql(u8, existing, session_key)) return false;
                allocator.free(existing);
            }
            agent.default_session_key = try allocator.dupe(u8, session_key);
            return true;
        }
        return false;
    }

    pub fn clearDefaultIfMatches(self: *AgentRegistry, allocator: std.mem.Allocator, session_key: []const u8) bool {
        var changed = false;
        for (self.agents.items) |*agent| {
            if (agent.default_session_key) |existing| {
                if (std.mem.eql(u8, existing, session_key)) {
                    allocator.free(existing);
                    agent.default_session_key = null;
                    changed = true;
                }
            }
        }
        return changed;
    }

    pub fn toJson(self: *const AgentRegistry, allocator: std.mem.Allocator) ![]u8 {
        var list = try allocator.alloc(AgentSnapshot, self.agents.items.len);
        defer allocator.free(list);
        for (self.agents.items, 0..) |agent, index| {
            list[index] = .{
                .id = agent.id,
                .display_name = agent.display_name,
                .icon = agent.icon,
                .soul_path = agent.soul_path,
                .config_path = agent.config_path,
                .personality_path = agent.personality_path,
                .default_session_key = agent.default_session_key,
            };
        }
        const snapshot = RegistrySnapshot{ .version = 1, .agents = list };
        return try std.json.Stringify.valueAlloc(allocator, snapshot, .{ .emit_null_optional_fields = false });
    }

    pub fn fromJson(allocator: std.mem.Allocator, data: []const u8) !AgentRegistry {
        var parsed = try std.json.parseFromSlice(RegistrySnapshot, allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedVersion;

        var reg = AgentRegistry.initEmpty(allocator);
        errdefer reg.deinit(allocator);
        for (parsed.value.agents) |snap| {
            if (snap.id.len == 0) continue;
            if (!session_keys.isAgentIdValid(snap.id)) continue;
            const display = snap.display_name orelse snap.id;
            const icon = snap.icon orelse "?";
            const profile = AgentProfile{
                .id = try allocator.dupe(u8, snap.id),
                .display_name = try allocator.dupe(u8, display),
                .icon = try allocator.dupe(u8, icon),
                .soul_path = if (snap.soul_path) |path| try allocator.dupe(u8, path) else null,
                .config_path = if (snap.config_path) |path| try allocator.dupe(u8, path) else null,
                .personality_path = if (snap.personality_path) |path| try allocator.dupe(u8, path) else null,
                .default_session_key = if (snap.default_session_key) |key| try allocator.dupe(u8, key) else null,
            };
            try reg.agents.append(allocator, profile);
        }
        try reg.ensureMain(allocator);
        return reg;
    }

    pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !AgentRegistry {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return initDefault(allocator),
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(data);

        return AgentRegistry.fromJson(allocator, data) catch {
            return initDefault(allocator);
        };
    }

    pub fn save(allocator: std.mem.Allocator, path: []const u8, registry: AgentRegistry) !void {
        const json = try registry.toJson(allocator);
        defer allocator.free(json);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }
};

fn freeAgentProfile(allocator: std.mem.Allocator, agent: *const AgentProfile) void {
    allocator.free(agent.id);
    allocator.free(agent.display_name);
    allocator.free(agent.icon);
    if (agent.soul_path) |path| allocator.free(path);
    if (agent.config_path) |path| allocator.free(path);
    if (agent.personality_path) |path| allocator.free(path);
    if (agent.default_session_key) |key| allocator.free(key);
}
