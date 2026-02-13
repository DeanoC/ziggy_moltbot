const std = @import("std");

pub const WorkboardListParams = struct {
    includeDone: ?bool = true,
    limit: ?u32 = null,
};

pub const WorkboardItemRow = struct {
    id: []const u8,
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    agentId: ?[]const u8 = null,
    parentId: ?[]const u8 = null,
    cronKey: ?[]const u8 = null,
    createdAtMs: ?i64 = null,
    updatedAtMs: ?i64 = null,
    dueAtMs: ?i64 = null,
    payload: ?std.json.Value = null,
};

pub const WorkboardListResult = struct {
    ts: ?i64 = null,
    count: ?u32 = null,
    items: ?[]WorkboardItemRow = null,
    rows: ?[]WorkboardItemRow = null,
    work: ?[]WorkboardItemRow = null,
};
