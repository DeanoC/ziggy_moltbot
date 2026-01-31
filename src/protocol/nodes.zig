const std = @import("std");

pub const NodeListParams = struct {};

pub const NodeInfo = struct {
    nodeId: []const u8,
    displayName: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    version: ?[]const u8 = null,
    coreVersion: ?[]const u8 = null,
    uiVersion: ?[]const u8 = null,
    deviceFamily: ?[]const u8 = null,
    modelIdentifier: ?[]const u8 = null,
    remoteIp: ?[]const u8 = null,
    caps: ?[]const []const u8 = null,
    commands: ?[]const []const u8 = null,
    pathEnv: ?[]const u8 = null,
    permissions: ?std.json.Value = null,
    connectedAtMs: ?i64 = null,
    connected: ?bool = null,
    paired: ?bool = null,
};

pub const NodeListResult = struct {
    ts: ?i64 = null,
    nodes: ?[]NodeInfo = null,
};

pub const NodeDescribeParams = struct {
    nodeId: []const u8,
};

pub const NodeInvokeParams = struct {
    nodeId: []const u8,
    command: []const u8,
    params: ?std.json.Value = null,
    timeoutMs: ?u32 = null,
    idempotencyKey: []const u8,
};
