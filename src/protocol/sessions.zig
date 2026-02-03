pub const SessionsListParams = struct {
    includeGlobal: ?bool = null,
    includeUnknown: ?bool = null,
    activeMinutes: ?u32 = null,
    limit: ?u32 = null,
};

pub const SessionsResetParams = struct {
    key: []const u8,
};

pub const SessionsDeleteParams = struct {
    key: []const u8,
};

pub const SessionRow = struct {
    key: []const u8,
    kind: ?[]const u8 = null,
    label: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    updatedAt: ?i64 = null,
};

pub const SessionsListResult = struct {
    ts: ?i64 = null,
    path: ?[]const u8 = null,
    count: ?u32 = null,
    sessions: ?[]SessionRow = null,
};
