const std = @import("std");

const PROTOCOL_VERSION: u32 = 3;

const ConnectAuth = struct {
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

const ConnectClient = struct {
    id: []const u8,
    version: []const u8,
    platform: []const u8,
    mode: []const u8,
};

const DeviceAuth = struct {
    id: []const u8,
    publicKey: []const u8,
    signature: []const u8,
    signedAt: i64,
    nonce: ?[]const u8 = null,
};

const ConnectParams = struct {
    minProtocol: u32,
    maxProtocol: u32,
    client: ConnectClient,
    caps: []const []const u8,
    role: []const u8,
    scopes: []const []const u8,
    auth: ?ConnectAuth = null,
    device: ?DeviceAuth = null,
    locale: ?[]const u8 = null,
    userAgent: ?[]const u8 = null,
};

const ConnectRequestFrame = struct {
    type: []const u8 = "req",
    id: []const u8,
    method: []const u8 = "connect",
    params: ConnectParams,
};

pub const DeviceAuthPayloadParams = struct {
    device_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    signed_at_ms: i64,
    token: []const u8,
    nonce: ?[]const u8 = null,
};

/// Mirrors OpenClaw's gateway `buildDeviceAuthPayload` format:
/// v1: version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
/// v2: version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token|nonce
pub fn buildDeviceAuthPayload(allocator: std.mem.Allocator, params: DeviceAuthPayloadParams) ![]u8 {
    const scopes_joined = try std.mem.join(allocator, ",", params.scopes);
    defer allocator.free(scopes_joined);

    const version: []const u8 = if (params.nonce != null) "v2" else "v1";
    if (params.nonce) |nonce| {
        return std.fmt.allocPrint(
            allocator,
            "{s}|{s}|{s}|{s}|{s}|{s}|{d}|{s}|{s}",
            .{
                version,
                params.device_id,
                params.client_id,
                params.client_mode,
                params.role,
                scopes_joined,
                params.signed_at_ms,
                params.token,
                nonce,
            },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}|{s}|{s}|{s}|{d}|{s}",
        .{
            version,
            params.device_id,
            params.client_id,
            params.client_mode,
            params.role,
            scopes_joined,
            params.signed_at_ms,
            params.token,
        },
    );
}

pub const ConnectRequestJsonParams = struct {
    request_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    token: ?[]const u8 = null,
    device_id: []const u8,
    device_public_key: []const u8,
    device_signature: []const u8,
    signed_at_ms: i64,
    nonce: ?[]const u8 = null,
};

/// Builds a `type=req, method=connect` payload with auth + device fields.
pub fn buildConnectRequestJson(
    allocator: std.mem.Allocator,
    params: ConnectRequestJsonParams,
) ![]u8 {
    const auth = if (params.token) |tok| ConnectAuth{ .token = tok } else null;
    const device = DeviceAuth{
        .id = params.device_id,
        .publicKey = params.device_public_key,
        .signature = params.device_signature,
        .signedAt = params.signed_at_ms,
        .nonce = params.nonce,
    };

    const req = ConnectRequestFrame{
        .id = params.request_id,
        .params = .{
            .minProtocol = PROTOCOL_VERSION,
            .maxProtocol = PROTOCOL_VERSION,
            .client = .{
                .id = params.client_id,
                .version = "example",
                .platform = "zig",
                .mode = params.client_mode,
            },
            .caps = &.{},
            .role = params.role,
            .scopes = params.scopes,
            .auth = auth,
            .device = device,
            .locale = "en-US",
            .userAgent = "zsc-example/0.1.0",
        },
    };

    return std.json.Stringify.valueAlloc(
        allocator,
        req,
        .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        },
    );
}

pub fn buildDevicePairApproveParamsJson(allocator: std.mem.Allocator, request_id: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        .{ .requestId = request_id },
        .{ .whitespace = .indent_2 },
    );
}

pub fn buildNodePairRequestParamsJson(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    caps: []const []const u8,
    commands: []const []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        .{
            .nodeId = node_id,
            .displayName = "Example Node",
            .platform = "linux",
            .version = "0.1.0",
            .caps = caps,
            .commands = commands,
            .silent = false,
        },
        .{ .whitespace = .indent_2 },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const payload = try buildDeviceAuthPayload(allocator, .{
        .device_id = "device_abc123",
        .client_id = "ziggystarclaw",
        .client_mode = "operator",
        .role = "operator",
        .scopes = &.{ "operator.read", "operator.write", "operator.pairing" },
        .signed_at_ms = 1737264000000,
        .token = "gateway-or-device-token",
        .nonce = "challenge_nonce",
    });
    defer allocator.free(payload);

    const connect_json = try buildConnectRequestJson(allocator, .{
        .request_id = "req_example",
        .client_id = "ziggystarclaw",
        .client_mode = "operator",
        .role = "operator",
        .scopes = &.{ "operator.read", "operator.write", "operator.pairing" },
        .token = "gateway-or-device-token",
        .device_id = "device_abc123",
        .device_public_key = "base64url_public_key",
        .device_signature = "base64url_signature",
        .signed_at_ms = 1737264000000,
        .nonce = "challenge_nonce",
    });
    defer allocator.free(connect_json);

    const device_approve_json = try buildDevicePairApproveParamsJson(allocator, "req-123");
    defer allocator.free(device_approve_json);

    const node_request_json = try buildNodePairRequestParamsJson(
        allocator,
        "node-abc",
        &.{ "camera", "screen", "location" },
        &.{ "camera.snap", "screen.record", "location.get" },
    );
    defer allocator.free(node_request_json);

    var out = std.fs.File.stdout().deprecatedWriter();
    try out.print("device-auth payload:\n{s}\n\n", .{payload});
    try out.print("connect request json:\n{s}\n\n", .{connect_json});
    try out.print("device.pair.approve params json:\n{s}\n\n", .{device_approve_json});
    try out.print("node.pair.request params json:\n{s}\n", .{node_request_json});
}
