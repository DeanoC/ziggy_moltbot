const std = @import("std");
const ws = @import("websocket");
const messages = @import("../protocol/messages.zig");
const gateway = @import("../protocol/gateway.zig");
const identity = @import("../client/device_identity.zig");
const requests = @import("../protocol/requests.zig");
const logger = @import("../utils/logger.zig");
const builtin = @import("builtin");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    insecure_tls: bool = false,
    connect_host_override: ?[]const u8 = null,
    connect_timeout_ms: u32 = 10_000,
    is_connected: bool = false,
    client: ?ws.Client = null,
    read_timeout_ms: u32 = 1,
    device_identity: ?identity.DeviceIdentity = null,
    connect_nonce: ?[]u8 = null,
    connect_sent: bool = false,
    use_device_identity: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
        token: []const u8,
        insecure_tls: bool,
        connect_host_override: ?[]const u8,
    ) WebSocketClient {
        return .{
            .allocator = allocator,
            .url = url,
            .token = token,
            .insecure_tls = insecure_tls,
            .connect_host_override = connect_host_override,
        };
    }

    pub fn setReadTimeout(self: *WebSocketClient, ms: u32) void {
        self.read_timeout_ms = ms;
    }

    pub fn storeDeviceToken(
        self: *WebSocketClient,
        token: []const u8,
        role: ?[]const u8,
        scopes: ?[]const []const u8,
        issued_at_ms: ?i64,
    ) !void {
        if (self.device_identity == null) {
            self.device_identity = try identity.loadOrCreate(self.allocator, identity.default_path);
        }
        if (self.device_identity) |*ident| {
            try identity.storeDeviceToken(
                self.allocator,
                identity.default_path,
                ident,
                token,
                role,
                scopes,
                issued_at_ms,
            );
        }
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.is_connected) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = try parseServerUrl(aa, self.url);
        var connect_host: ?[]const u8 = null;
        var connect_port: u16 = parsed.port;
        if (self.connect_host_override) |override| {
            const trimmed = std.mem.trim(u8, override, " \t\r\n");
            if (trimmed.len > 0) {
                const parsed_override = parseConnectOverride(trimmed, parsed.port);
                connect_host = parsed_override.host;
                connect_port = parsed_override.port;
            }
        }
        var client = try ws.Client.init(self.allocator, .{
            .port = connect_port,
            .host = parsed.host,
            .connect_host = connect_host,
            .connect_timeout_ms = self.connect_timeout_ms,
            .tls = parsed.tls,
            .verify_host = !self.insecure_tls,
            .verify_cert = !self.insecure_tls,
            .max_size = 1024 * 1024,
            .buffer_size = 64 * 1024,
        });
        errdefer client.deinit();

        const headers = try buildHeaders(aa, parsed.host_header, parsed.origin, self.token);
        try client.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = if (headers.len > 0) headers else null,
        });
        try client.readTimeout(self.read_timeout_ms);

        self.client = client;
        self.is_connected = true;
        self.connect_sent = false;
        clearConnectNonce(self);

        if (self.use_device_identity) {
            if (self.device_identity == null) {
                self.device_identity = try identity.loadOrCreate(self.allocator, identity.default_path);
            }
        } else {
            try sendConnectRequest(self, null);
        }
    }

    pub fn send(self: *WebSocketClient, message: []const u8) !void {
        if (!self.is_connected) return error.NotConnected;
        if (self.client) |*client| {
            const payload = try self.allocator.dupe(u8, message);
            defer self.allocator.free(payload);
            try client.write(payload);
            return;
        }
        return error.NotConnected;
    }

    pub fn sendPing(self: *WebSocketClient) !void {
        if (!self.is_connected) return error.NotConnected;
        if (self.client) |*client| {
            var ping_buf: [1]u8 = .{0};
            try client.writePing(ping_buf[0..0]);
            return;
        }
        return error.NotConnected;
    }

    pub fn receive(self: *WebSocketClient) !?[]u8 {
        if (!self.is_connected) return error.NotConnected;
        if (self.client) |*client| {
            const message = try client.read() orelse return null;
            defer client.done(message);

            const payload = switch (message.type) {
                .text, .binary => try self.allocator.dupe(u8, message.data),
                .ping => blk: {
                    try client.writePong(message.data);
                    break :blk null;
                },
                .pong => null,
                .close => blk: {
                    if (message.data.len >= 2) {
                        const code = (@as(u16, message.data[0]) << 8) | message.data[1];
                        const reason = message.data[2..];
                        logger.warn("WebSocket closed by server code={} reason={s}", .{ code, reason });
                    } else {
                        logger.warn("WebSocket closed by server (no close payload)", .{});
                    }
                    try client.close(.{});
                    self.is_connected = false;
                    break :blk null;
                },
            };

            if (payload) |text| {
                if (message.type == .text) {
                    logger.debug("WebSocket text frame len={d}", .{text.len});
                } else if (message.type == .binary) {
                    logger.debug("WebSocket binary frame len={d}", .{text.len});
                }
                handleConnectChallenge(self, text) catch {};
                return text;
            }
            return null;
        }
        return error.NotConnected;
    }

    pub fn disconnect(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.close(.{}) catch {};
            client.deinit();
        }
        self.client = null;
        self.is_connected = false;
        self.connect_sent = false;
        clearConnectNonce(self);
    }

    pub fn signalClose(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.stream.close();
        }
        self.is_connected = false;
    }

    pub fn deinit(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.deinit();
            self.client = null;
        }
        if (self.device_identity) |*ident| {
            ident.deinit(self.allocator);
            self.device_identity = null;
        }
        clearConnectNonce(self);
    }
};

fn sendConnectRequest(self: *WebSocketClient, nonce: ?[]const u8) !void {
    if (self.client == null) return;
    if (self.connect_sent) return;

    const request_id = try requests.makeRequestId(self.allocator);
    defer self.allocator.free(request_id);

    const scopes = [_][]const u8{ "operator.admin", "operator.approvals", "operator.pairing" };
    const caps = [_][]const u8{};
    const client_id = "cli";
    const client_mode = "cli";
    const auth_token = if (self.device_identity) |ident|
        if (ident.device_token) |token| token else self.token
    else
        self.token;
    const auth = if (auth_token.len > 0) gateway.ConnectAuth{ .token = auth_token } else null;
    var signature_buf: ?[]u8 = null;
    defer if (signature_buf) |sig| self.allocator.free(sig);

    const device = blk: {
        if (!self.use_device_identity) break :blk null;
        const ident = self.device_identity orelse return error.MissingDeviceIdentity;
        if (nonce == null) return error.MissingConnectNonce;
        const signed_at = std.time.milliTimestamp();
        const payload = try buildDeviceAuthPayload(self.allocator, .{
            .device_id = ident.device_id,
            .client_id = client_id,
            .client_mode = client_mode,
            .role = "operator",
            .scopes = &scopes,
            .signed_at_ms = signed_at,
            .token = if (auth_token.len > 0) auth_token else "",
            .nonce = nonce.?,
        });
        defer self.allocator.free(payload);
        signature_buf = try identity.signPayload(self.allocator, ident, payload);
        const signature = signature_buf.?;
        logger.debug(
            "Device signature utf8={} len={} bytes[0..4]={d} {d} {d} {d}",
            .{
                std.unicode.utf8ValidateSlice(signature),
                signature.len,
                signature[0],
                signature[1],
                signature[2],
                signature[3],
            },
        );
        break :blk gateway.DeviceAuth{
            .id = ident.device_id,
            .publicKey = ident.public_key_b64,
            .signature = signature,
            .signedAt = signed_at,
            .nonce = nonce,
        };
    };
    const token_source = if (auth_token.len == 0)
        "none"
    else if (self.device_identity) |ident|
        if (ident.device_token != null and std.mem.eql(u8, auth_token, ident.device_token.?)) "device" else "shared"
    else
        "shared";
    logger.info(
        "Sending connect request id={s} device_id={s} nonce={s} token={s}",
        .{
            request_id,
            if (device) |d| d.id else "(none)",
            if (nonce) |value| value else "(none)",
            token_source,
        },
    );

    const connect_params = gateway.ConnectParams{
        .minProtocol = gateway.PROTOCOL_VERSION,
        .maxProtocol = gateway.PROTOCOL_VERSION,
        .client = .{
            .id = client_id,
            .displayName = "ZiggyStarClaw",
            .version = "0.1.0",
            .platform = @tagName(builtin.os.tag),
            .mode = client_mode,
        },
        .caps = &caps,
        .role = "operator",
        .scopes = &scopes,
        .auth = auth,
        .device = device,
    };

    const request = gateway.ConnectRequestFrame{
        .id = request_id,
        .params = connect_params,
    };

    const payload = try messages.serializeMessage(self.allocator, request);
    defer self.allocator.free(payload);

    if (auth_token.len > 0) {
        const redacted = try std.mem.replaceOwned(u8, self.allocator, payload, auth_token, "<redacted>");
        defer self.allocator.free(redacted);
        logger.debug("Connect request payload: {s}", .{redacted});
    } else {
        logger.debug("Connect request payload: {s}", .{payload});
    }

    if (self.client) |*client| {
        try client.write(payload);
    }
    self.connect_sent = true;
}

fn buildDeviceAuthPayload(allocator: std.mem.Allocator, params: struct {
    device_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    signed_at_ms: i64,
    token: []const u8,
    nonce: []const u8,
}) ![]u8 {
    const scopes_joined = try std.mem.join(allocator, ",", params.scopes);
    defer allocator.free(scopes_joined);

    const version = "v2";
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
            params.nonce,
        },
    );
}

fn parseConnectNonce(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return null;
    if (type_val != .string or !std.mem.eql(u8, type_val.string, "event")) return null;
    const event_val = obj.get("event") orelse return null;
    if (event_val != .string or !std.mem.eql(u8, event_val.string, "connect.challenge")) return null;
    const payload_val = obj.get("payload") orelse return null;
    if (payload_val != .object) return null;
    const nonce_val = payload_val.object.get("nonce") orelse return null;
    if (nonce_val != .string or nonce_val.string.len == 0) return null;
    return try allocator.dupe(u8, nonce_val.string);
}

fn clearConnectNonce(self: *WebSocketClient) void {
    if (self.connect_nonce) |nonce| {
        self.allocator.free(nonce);
        self.connect_nonce = null;
    }
}

fn handleConnectChallenge(self: *WebSocketClient, raw: []const u8) !void {
    if (!self.use_device_identity or self.connect_sent) return;
    const nonce = try parseConnectNonce(self.allocator, raw) orelse return;
    clearConnectNonce(self);
    self.connect_nonce = nonce;
    logger.info("Connect challenge nonce received: {s}", .{nonce});
    try sendConnectRequest(self, nonce);
}

const ParsedUrl = struct {
    host: []const u8,
    host_header: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,
    origin: []const u8,
};

fn parseServerUrl(allocator: std.mem.Allocator, raw_url: []const u8) !ParsedUrl {
    const url = if (std.mem.indexOf(u8, raw_url, "://") == null)
        try std.fmt.allocPrint(allocator, "ws://{s}", .{raw_url})
    else
        raw_url;

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const scheme = uri.scheme;
    const tls = std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https");
    if (!tls and !std.mem.eql(u8, scheme, "ws") and !std.mem.eql(u8, scheme, "http")) {
        return error.UnsupportedScheme;
    }

    const host = try uri.getHostAlloc(allocator);
    const default_port: u16 = if (tls) 443 else 80;
    const port: u16 = uri.port orelse default_port;

    const host_header = if (port != default_port)
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port })
    else
        host;

    const path_raw = try uri.path.toRawMaybeAlloc(allocator);
    const base_path = if (path_raw.len == 0) "/" else path_raw;
    const path = if (uri.query) |query| blk: {
        const query_raw = try query.toRawMaybeAlloc(allocator);
        break :blk try std.fmt.allocPrint(allocator, "{s}?{s}", .{ base_path, query_raw });
    } else base_path;

    const origin_scheme = if (tls) "https" else "http";
    const origin = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ origin_scheme, host_header });

    return .{
        .host = host,
        .host_header = host_header,
        .port = port,
        .path = path,
        .tls = tls,
        .origin = origin,
    };
}

fn buildHeaders(allocator: std.mem.Allocator, host_header: []const u8, origin: []const u8, token: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    const writer = list.writer(allocator);
    try writer.print("Host: {s}", .{host_header});
    try writer.print("\r\nOrigin: {s}", .{origin});
    if (token.len > 0) {
        try writer.print("\r\nAuthorization: Bearer {s}", .{token});
    }
    return list.toOwnedSlice(allocator);
}

const ConnectOverride = struct {
    host: []const u8,
    port: u16,
};

fn parseConnectOverride(value: []const u8, default_port: u16) ConnectOverride {
    if (value.len == 0) {
        return .{ .host = value, .port = default_port };
    }

    if (value[0] == '[') {
        if (std.mem.indexOfScalar(u8, value, ']')) |end_idx| {
            const host = value[1..end_idx];
            if (end_idx + 1 < value.len and value[end_idx + 1] == ':') {
                const port_str = value[end_idx + 2 ..];
                const port = std.fmt.parseInt(u16, port_str, 10) catch default_port;
                return .{ .host = host, .port = port };
            }
            return .{ .host = host, .port = default_port };
        }
    }

    if (std.mem.lastIndexOfScalar(u8, value, ':')) |idx| {
        const host_part = value[0..idx];
        const port_part = value[idx + 1 ..];
        if (host_part.len > 0 and port_part.len > 0) {
            const port = std.fmt.parseInt(u16, port_part, 10) catch default_port;
            return .{ .host = host_part, .port = port };
        }
    }

    return .{ .host = value, .port = default_port };
}
