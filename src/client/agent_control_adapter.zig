const std = @import("std");
const client_state = @import("state.zig");

pub const AgentFileKind = enum {
    soul,
    config,
    personality,
};

pub const AgentFileOpenAction = struct {
    agent_id: []const u8,
    kind: AgentFileKind,
    path: ?[]const u8 = null,
};

pub const RpcSpec = struct {
    method: []const u8,
    params: RpcParams,
};

pub const RpcParams = union(enum) {
    legacy_file_open: AgentFileParams,
    agents_files_get: AgentFilesGetParams,
};

pub const AgentFileParams = struct {
    action: []const u8 = "open_file",
    agentId: []const u8,
    kind: []const u8,
    file: []const u8,
    path: ?[]const u8 = null,
};

pub const AgentFilesGetParams = struct {
    agentId: []const u8,
    name: []const u8,
};

pub const ResolveResult = union(enum) {
    open_url: []const u8,
    rpc: RpcSpec,
    unsupported: []const u8,
};

pub const OpenResult = struct {
    url: ?[]const u8 = null,
    content: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

const files_get_method_candidates = [_][]const u8{
    "agents.files.get",
};

const legacy_method_candidates = [_][]const u8{
    "agent.control",
    "agent.file.open",
    "agent.files.open",
};

pub fn resolveRequest(
    ctx: *const client_state.ClientContext,
    action: AgentFileOpenAction,
) ResolveResult {
    if (action.path) |path| {
        if (isOpenableUrl(path)) return .{ .open_url = path };
    }

    for (files_get_method_candidates) |candidate| {
        if (!ctx.supportsGatewayMethod(candidate)) continue;
        return .{
            .rpc = .{
                .method = candidate,
                .params = .{
                    .agents_files_get = .{
                        .agentId = action.agent_id,
                        .name = fileNameForKind(action.kind),
                    },
                },
            },
        };
    }

    for (legacy_method_candidates) |candidate| {
        if (!ctx.supportsGatewayMethod(candidate)) continue;
        const kind = kindLabel(action.kind);
        return .{
            .rpc = .{
                .method = candidate,
                .params = .{
                    .legacy_file_open = .{
                        .agentId = action.agent_id,
                        .kind = kind,
                        .file = kind,
                        .path = action.path,
                    },
                },
            },
        };
    }

    return .{ .unsupported = "Gateway does not advertise an agent file control method." };
}

pub fn extractOpenResult(payload: std.json.Value) OpenResult {
    if (payload != .object) return .{};
    const root = payload.object;

    const nested = if (root.get("result")) |value|
        if (value == .object) value.object else null
    else
        null;

    const obj = nested orelse root;
    const file_obj = if (obj.get("file")) |file_value|
        if (file_value == .object) file_value.object else null
    else
        null;

    if (file_obj) |file| {
        return .{
            .url = pickString(file, &.{ "url", "openUrl", "link" }),
            .content = pickString(file, &.{ "content", "text", "body" }),
            .file_name = pickString(file, &.{ "name", "path", "fileName", "file" }),
            .language = pickString(file, &.{ "language", "lang", "mime", "mimeType" }),
        };
    }

    return .{
        .url = pickString(obj, &.{ "url", "openUrl", "link" }),
        .content = pickString(obj, &.{ "content", "text", "body" }),
        .file_name = pickString(obj, &.{ "fileName", "name", "path", "file" }),
        .language = pickString(obj, &.{ "language", "lang", "mime", "mimeType" }),
    };
}

pub fn kindLabel(kind: AgentFileKind) []const u8 {
    return switch (kind) {
        .soul => "soul",
        .config => "config",
        .personality => "personality",
    };
}

fn pickString(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (obj.get(key)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}

fn fileNameForKind(kind: AgentFileKind) []const u8 {
    return switch (kind) {
        .soul => "SOUL.md",
        .config => "AGENTS.md",
        .personality => "IDENTITY.md",
    };
}

fn isOpenableUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "file://");
}
