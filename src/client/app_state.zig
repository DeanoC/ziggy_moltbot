const std = @import("std");

pub const AppState = struct {
    version: u32 = 2,
    last_connected: bool = false,
    window_width: ?i32 = null,
    window_height: ?i32 = null,
    window_pos_x: ?i32 = null,
    window_pos_y: ?i32 = null,
    window_maximized: bool = false,
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

    var parsed = std.json.parseFromSlice(
        AppState,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch return initDefault();
    defer parsed.deinit();

    if (parsed.value.version != 1 and parsed.value.version != 2) return initDefault();
    var state = parsed.value;
    if (state.version == 1) {
        state.version = 2;
    }
    return state;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, state: AppState) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}
