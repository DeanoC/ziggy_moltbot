const std = @import("std");
const gateway = @import("gateway.zig");
const messages = @import("messages.zig");
const requests = @import("requests.zig");

/// Mirror of OpenClaw gateway WS auth + pairing field docs for client-side use.
///
/// OpenClaw source-of-truth pointers:
/// - docs/gateway/protocol.md
/// - docs/gateway/pairing.md
/// - src/gateway/protocol/schema/frames.ts (ConnectParamsSchema)
/// - src/gateway/protocol/schema/devices.ts
/// - src/gateway/protocol/schema/nodes.ts
/// - src/gateway/device-auth.ts (buildDeviceAuthPayload)
///
/// ZiggyStarClaw code pointers:
/// - src/client/websocket_client.zig (sendConnectRequest + challenge handling)
/// - src/client/event_handler.zig (hello-ok auth token extraction)
/// - src/main_node.zig (pairing request/resolution handlers)
/// - src/cli/operator_chunk.zig + src/main_operator.zig (device.pair approve/reject/list)
pub const ConnectParams = struct {
    minProtocol: u32,
    maxProtocol: u32,
    client: gateway.ConnectClient,
    /// Node capability families ("camera", "canvas", ...).
    caps: []const []const u8 = &.{},
    /// Node invoke allowlist ("camera.snap", "canvas.navigate", ...).
    commands: []const []const u8 = &.{},
    /// Optional granular permission toggles advertised by node clients.
    permissions: ?std.json.Value = null,
    /// Optional PATH override used by some node hosts.
    pathEnv: ?[]const u8 = null,
    role: []const u8,
    scopes: []const []const u8 = &.{},
    auth: ?gateway.ConnectAuth = null,
    device: ?gateway.DeviceAuth = null,
    locale: ?[]const u8 = null,
    userAgent: ?[]const u8 = null,
};

pub const ConnectRequestFrame = struct {
    type: []const u8 = "req",
    id: []const u8,
    method: []const u8 = "connect",
    params: ConnectParams,
};

pub const PairingRequestIdParams = struct {
    requestId: []const u8,
};

pub const NodePairRequestParams = struct {
    nodeId: []const u8,
    displayName: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    version: ?[]const u8 = null,
    coreVersion: ?[]const u8 = null,
    uiVersion: ?[]const u8 = null,
    deviceFamily: ?[]const u8 = null,
    modelIdentifier: ?[]const u8 = null,
    caps: ?[]const []const u8 = null,
    commands: ?[]const []const u8 = null,
    remoteIp: ?[]const u8 = null,
    silent: ?bool = null,
};

pub const NodePairVerifyParams = struct {
    nodeId: []const u8,
    token: []const u8,
};

pub const DevicePairRequestedEvent = struct {
    requestId: []const u8,
    deviceId: []const u8,
    publicKey: []const u8,
    displayName: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    clientId: ?[]const u8 = null,
    clientMode: ?[]const u8 = null,
    role: ?[]const u8 = null,
    roles: ?[]const []const u8 = null,
    scopes: ?[]const []const u8 = null,
    remoteIp: ?[]const u8 = null,
    silent: ?bool = null,
    isRepair: ?bool = null,
    ts: i64,
};

pub const DevicePairResolvedEvent = struct {
    requestId: []const u8,
    deviceId: []const u8,
    decision: []const u8,
    ts: i64,
};

pub const DeviceAuthPayloadParams = struct {
    device_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    signed_at_ms: i64,
    token: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
};

/// Build the exact payload string used by OpenClaw's gateway for device signature verification.
///
/// Shape (v1):
///   v1|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
/// Shape (v2 + nonce):
///   v2|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token|nonce
pub fn buildDeviceAuthPayload(allocator: std.mem.Allocator, params: DeviceAuthPayloadParams) ![]u8 {
    const scopes_joined = try std.mem.join(allocator, ",", params.scopes);
    defer allocator.free(scopes_joined);

    const version: []const u8 = if (params.nonce != null) "v2" else "v1";
    const token = params.token orelse "";

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
                token,
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
            token,
        },
    );
}

pub const ExamplePayloadBundle = struct {
    connect: []u8,
    node_pair_request: []u8,
    device_pair_approve: []u8,
    device_pair_reject: []u8,

    pub fn deinit(self: *ExamplePayloadBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.connect);
        allocator.free(self.node_pair_request);
        allocator.free(self.device_pair_approve);
        allocator.free(self.device_pair_reject);
    }
};

/// Build copy-pasteable JSON examples for WS auth + pairing messages.
pub fn buildExamplePayloadBundle(allocator: std.mem.Allocator) !ExamplePayloadBundle {
    const connect = try buildExampleConnectPayload(allocator);
    errdefer allocator.free(connect);

    const node_pair_request = try buildExampleNodePairRequestPayload(allocator);
    errdefer allocator.free(node_pair_request);

    const device_pair_approve = try buildExampleDevicePairApprovePayload(allocator, "pair_req_123");
    errdefer allocator.free(device_pair_approve);

    const device_pair_reject = try buildExampleDevicePairRejectPayload(allocator, "pair_req_123");
    errdefer allocator.free(device_pair_reject);

    return .{
        .connect = connect,
        .node_pair_request = node_pair_request,
        .device_pair_approve = device_pair_approve,
        .device_pair_reject = device_pair_reject,
    };
}

pub fn buildExampleConnectPayload(allocator: std.mem.Allocator) ![]u8 {
    const frame = ConnectRequestFrame{
        .id = "connect_example_1",
        .params = .{
            .minProtocol = gateway.PROTOCOL_VERSION,
            .maxProtocol = gateway.PROTOCOL_VERSION,
            .client = .{
                .id = "zsc-cli",
                .displayName = "ZiggyStarClaw CLI",
                .version = "0.0.0-example",
                .platform = "linux",
                .mode = "cli",
            },
            .role = "operator",
            .scopes = &.{ "operator.read", "operator.write", "operator.pairing" },
            .caps = &.{},
            .commands = &.{},
            .auth = .{ .token = "example-gateway-token" },
            .device = .{
                .id = "device_fingerprint",
                .publicKey = "base64url-public-key",
                .signature = "base64url-signature",
                .signedAt = 1737264000000,
                .nonce = "connect-challenge-nonce",
            },
            .locale = "en-US",
            .userAgent = "ziggystarclaw/0.0.0-example",
        },
    };
    return messages.serializeMessage(allocator, frame);
}

pub fn buildExampleNodePairRequestPayload(allocator: std.mem.Allocator) ![]u8 {
    const frame = requests.RequestFrame(NodePairRequestParams){
        .id = "node_pair_request_example_1",
        .method = "node.pair.request",
        .params = .{
            .nodeId = "node-android-01",
            .displayName = "Android Companion",
            .platform = "android",
            .version = "0.0.0-example",
            .deviceFamily = "phone",
            .modelIdentifier = "pixel-9",
            .caps = &.{ "camera", "canvas", "screen" },
            .commands = &.{ "camera.snap", "canvas.navigate", "screen.record" },
            .remoteIp = "100.101.102.103",
            .silent = false,
        },
    };
    return messages.serializeMessage(allocator, frame);
}

pub fn buildExampleDevicePairApprovePayload(allocator: std.mem.Allocator, request_id: []const u8) ![]u8 {
    const frame = requests.RequestFrame(PairingRequestIdParams){
        .id = "device_pair_approve_example_1",
        .method = "device.pair.approve",
        .params = .{ .requestId = request_id },
    };
    return messages.serializeMessage(allocator, frame);
}

pub fn buildExampleDevicePairRejectPayload(allocator: std.mem.Allocator, request_id: []const u8) ![]u8 {
    const frame = requests.RequestFrame(PairingRequestIdParams){
        .id = "device_pair_reject_example_1",
        .method = "device.pair.reject",
        .params = .{ .requestId = request_id },
    };
    return messages.serializeMessage(allocator, frame);
}
