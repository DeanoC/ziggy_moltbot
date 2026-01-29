const std = @import("std");

pub const Config = struct {
    server_url: []const u8,
    token: []const u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.server_url);
        allocator.free(self.token);
    }
};

pub fn initDefault(allocator: std.mem.Allocator) !Config {
    return .{
        .server_url = try allocator.dupe(u8, ""),
        .token = try allocator.dupe(u8, ""),
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

    var parsed = try std.json.parseFromSlice(Config, allocator, data, .{});
    defer parsed.deinit();

    return .{
        .server_url = try allocator.dupe(u8, parsed.value.server_url),
        .token = try allocator.dupe(u8, parsed.value.token),
    };
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, cfg: Config) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, cfg, .{});
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}
