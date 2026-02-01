const std = @import("std");

pub const AppState = struct {
    version: u32 = 1,
    last_connected: bool = false,
};

pub fn initDefault() AppState {
    return .{};
}

pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !AppState {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return initDefault(),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(AppState, allocator, data, .{}) catch return initDefault();
    defer parsed.deinit();

    if (parsed.value.version != 1) return initDefault();
    return parsed.value;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, state: AppState) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}
