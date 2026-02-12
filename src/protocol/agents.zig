pub const AgentsCreateParams = struct {
    name: []const u8,
    workspace: []const u8,
    avatar: ?[]const u8 = null,
    emoji: ?[]const u8 = null,
};

pub const AgentsUpdateParams = struct {
    agentId: []const u8,
    name: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    model: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

pub const AgentsDeleteParams = struct {
    agentId: []const u8,
    deleteFiles: ?bool = null,
};
