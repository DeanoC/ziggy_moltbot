const std = @import("std");
const workspace = @import("workspace.zig");

pub fn loadOrDefault(allocator: std.mem.Allocator, path: []const u8) !workspace.Workspace {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return workspace.Workspace.initDefault(allocator),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(workspace.WorkspaceSnapshot, allocator, data, .{}) catch {
        return workspace.Workspace.initDefault(allocator);
    };
    defer parsed.deinit();

    const ws = try workspace.Workspace.fromSnapshot(allocator, parsed.value);
    return ws;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, ws: *const workspace.Workspace) !void {
    var snapshot = try ws.toSnapshot(allocator);
    defer snapshot.deinit(allocator);

    const json = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json);
}
