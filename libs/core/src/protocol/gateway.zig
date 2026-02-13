const std = @import("std");

pub const PROTOCOL_VERSION: u32 = 3;

pub const ConnectAuth = struct {
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const ConnectClient = struct {
    id: []const u8,
    displayName: ?[]const u8 = null,
    version: []const u8,
    platform: []const u8,
    mode: []const u8,
    instanceId: ?[]const u8 = null,
};

pub const DeviceAuth = struct {
    id: []const u8,
    publicKey: []const u8,
    signature: []const u8,
    signedAt: i64,
    nonce: ?[]const u8 = null,
};

pub const ConnectParams = struct {
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

pub const ConnectRequestFrame = struct {
    type: []const u8 = "req",
    id: []const u8,
    method: []const u8 = "connect",
    params: ConnectParams,
};

pub const GatewayError = struct {
    code: []const u8,
    message: []const u8,
    details: ?std.json.Value = null,
};

pub const GatewayResponseFrame = struct {
    type: []const u8,
    id: []const u8,
    ok: bool,
    payload: ?std.json.Value = null,
    @"error": ?GatewayError = null,
};

pub const GatewayEventFrame = struct {
    type: []const u8,
    event: []const u8,
    payload: ?std.json.Value = null,
};
