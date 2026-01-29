const std = @import("std");
const storage = @import("../platform/wasm_storage.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const default_key: [:0]const u8 = "moltbot_device.json";

pub const DeviceIdentity = struct {
    device_id: []const u8,
    public_key_b64: []const u8,
    key_pair: Ed25519.KeyPair,
    device_token: ?[]const u8 = null,
    token_role: ?[]const u8 = null,
    token_scopes: ?[]const []const u8 = null,
    token_issued_at_ms: ?i64 = null,

    pub fn deinit(self: *DeviceIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.device_id);
        allocator.free(self.public_key_b64);
        if (self.device_token) |token| allocator.free(token);
        if (self.token_role) |role| allocator.free(role);
        if (self.token_scopes) |scopes| freeScopes(allocator, scopes);
    }
};

const StoredIdentity = struct {
    version: u32,
    seed: []const u8,
    device_id: ?[]const u8 = null,
    public_key: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    device_token: ?[]const u8 = null,
    token_role: ?[]const u8 = null,
    token_scopes: ?[]const []const u8 = null,
    token_issued_at_ms: ?i64 = null,
};

pub fn loadOrCreate(allocator: std.mem.Allocator) !DeviceIdentity {
    if (try loadIdentity(allocator)) |identity| {
        return identity;
    }

    const key_pair = Ed25519.KeyPair.generate();
    const pub_bytes = key_pair.public_key.toBytes();
    const device_id = try deriveDeviceId(allocator, &pub_bytes);
    const public_key_b64 = try base64UrlEncode(allocator, &pub_bytes);
    try saveIdentity(allocator, key_pair, device_id, public_key_b64, null, null, null, null);

    return .{
        .device_id = device_id,
        .public_key_b64 = public_key_b64,
        .key_pair = key_pair,
    };
}

pub fn signPayload(
    allocator: std.mem.Allocator,
    identity: DeviceIdentity,
    payload: []const u8,
) ![]u8 {
    const signature = try identity.key_pair.sign(payload, null);
    const sig_bytes = signature.toBytes();
    return base64UrlEncode(allocator, &sig_bytes);
}

pub fn storeDeviceToken(
    allocator: std.mem.Allocator,
    identity: *DeviceIdentity,
    token: []const u8,
    role: ?[]const u8,
    scopes: ?[]const []const u8,
    issued_at_ms: ?i64,
) !void {
    try updateDeviceToken(allocator, identity, token, role, scopes, issued_at_ms);
    try saveIdentity(
        allocator,
        identity.key_pair,
        identity.device_id,
        identity.public_key_b64,
        identity.device_token,
        identity.token_role,
        identity.token_scopes,
        identity.token_issued_at_ms,
    );
}

fn loadIdentity(allocator: std.mem.Allocator) !?DeviceIdentity {
    const json = try storage.get(allocator, default_key) orelse return null;
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(StoredIdentity, allocator, json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value.version != 1) return null;

    const seed_bytes = try base64UrlDecode(allocator, parsed.value.seed);
    defer allocator.free(seed_bytes);
    if (seed_bytes.len != Ed25519.KeyPair.seed_length) return null;

    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    @memcpy(&seed, seed_bytes[0..Ed25519.KeyPair.seed_length]);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const pub_bytes = key_pair.public_key.toBytes();
    const device_id = try deriveDeviceId(allocator, &pub_bytes);
    const public_key_b64 = try base64UrlEncode(allocator, &pub_bytes);
    const device_token = if (parsed.value.device_token) |token| try allocator.dupe(u8, token) else null;
    const token_role = if (parsed.value.token_role) |role| try allocator.dupe(u8, role) else null;
    const token_scopes = if (parsed.value.token_scopes) |scopes| try dupScopes(allocator, scopes) else null;
    const token_issued_at_ms = parsed.value.token_issued_at_ms;

    return .{
        .device_id = device_id,
        .public_key_b64 = public_key_b64,
        .key_pair = key_pair,
        .device_token = device_token,
        .token_role = token_role,
        .token_scopes = token_scopes,
        .token_issued_at_ms = token_issued_at_ms,
    };
}

fn saveIdentity(
    allocator: std.mem.Allocator,
    key_pair: Ed25519.KeyPair,
    device_id: []const u8,
    public_key_b64: []const u8,
    device_token: ?[]const u8,
    token_role: ?[]const u8,
    token_scopes: ?[]const []const u8,
    token_issued_at_ms: ?i64,
) !void {
    const seed = key_pair.secret_key.seed();
    const seed_b64 = try base64UrlEncode(allocator, &seed);
    defer allocator.free(seed_b64);

    const stored = StoredIdentity{
        .version = 1,
        .seed = seed_b64,
        .device_id = device_id,
        .public_key = public_key_b64,
        .created_at_ms = std.time.milliTimestamp(),
        .device_token = device_token,
        .token_role = token_role,
        .token_scopes = token_scopes,
        .token_issued_at_ms = token_issued_at_ms,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, stored, .{});
    defer allocator.free(json);

    try storage.set(allocator, default_key, json);
}

fn updateDeviceToken(
    allocator: std.mem.Allocator,
    identity: *DeviceIdentity,
    token: []const u8,
    role: ?[]const u8,
    scopes: ?[]const []const u8,
    issued_at_ms: ?i64,
) !void {
    if (identity.device_token) |existing| allocator.free(existing);
    identity.device_token = try allocator.dupe(u8, token);

    if (identity.token_role) |existing| allocator.free(existing);
    identity.token_role = if (role) |value| try allocator.dupe(u8, value) else null;

    if (identity.token_scopes) |existing| freeScopes(allocator, existing);
    identity.token_scopes = if (scopes) |values| try dupScopes(allocator, values) else null;
    identity.token_issued_at_ms = issued_at_ms;
}

fn dupScopes(allocator: std.mem.Allocator, scopes: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, scopes.len);
    errdefer {
        for (out) |scope| allocator.free(scope);
        allocator.free(out);
    }
    for (scopes, 0..) |scope, index| {
        out[index] = try allocator.dupe(u8, scope);
    }
    return out;
}

fn freeScopes(allocator: std.mem.Allocator, scopes: []const []const u8) void {
    for (scopes) |scope| allocator.free(scope);
    allocator.free(scopes);
}

fn deriveDeviceId(allocator: std.mem.Allocator, pub_bytes: []const u8) ![]const u8 {
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(pub_bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, &hex);
}

fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = std.base64.url_safe.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, size);
    _ = std.base64.url_safe.Encoder.encode(out, data);
    return out;
}

fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = try std.base64.url_safe.Decoder.calcSizeForSlice(data);
    const out = try allocator.alloc(u8, size);
    _ = try std.base64.url_safe.Decoder.decode(out, data);
    return out;
}
