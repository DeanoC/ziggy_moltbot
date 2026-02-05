const std = @import("std");
const websocket_client = @import("../client/websocket_client.zig");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

/// Single-threaded connection manager for node-mode.
///
/// Purpose: provide reconnect/backoff + lifecycle callbacks without background threads,
/// so node-mode can drive everything from its main poll/receive loop safely.
pub const SingleThreadConnectionManager = struct {
    allocator: std.mem.Allocator,

    // Config
    ws_url: []const u8,

    // Token used for the initial WebSocket handshake (Authorization header).
    // This should be the gateway auth token.
    handshake_token: []const u8,

    // Token used for connect auth (params.auth.token).
    // For node-mode this must match the WebSocket handshake Authorization token.
    connect_auth_token: []const u8,

    // Token used inside the device-auth signed payload.
    // For node-mode this should be the paired device token (node.nodeToken) when available.
    device_auth_token: []const u8,

    insecure_tls: bool,

    // State
    ws_client: websocket_client.WebSocketClient,
    is_connected: bool = false,

    reconnect_attempt: u32 = 0,
    next_attempt_at_ms: i64 = 0,

    // Tunables
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30_000,

    // Optional user context for callbacks
    user_ctx: ?*anyopaque = null,

    // Optional mutex to guard ws_client operations when another thread (e.g. HealthReporter)
    // may call send concurrently.
    ws_mutex: ?*std.Thread.Mutex = null,

    // Callbacks (run on caller thread)
    onConfigureClient: ?*const fn (*SingleThreadConnectionManager, *websocket_client.WebSocketClient) void = null,
    onConnected: ?*const fn (*SingleThreadConnectionManager) void = null,
    onDisconnected: ?*const fn (*SingleThreadConnectionManager) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        ws_url: []const u8,
        handshake_token: []const u8,
        connect_auth_token: []const u8,
        device_auth_token: []const u8,
        insecure_tls: bool,
    ) !SingleThreadConnectionManager {
        const url_copy = try allocator.dupe(u8, ws_url);
        errdefer allocator.free(url_copy);

        const hs_copy = try allocator.dupe(u8, handshake_token);
        errdefer allocator.free(hs_copy);

        const ca_copy = try allocator.dupe(u8, connect_auth_token);
        errdefer allocator.free(ca_copy);

        const da_copy = try allocator.dupe(u8, device_auth_token);
        errdefer allocator.free(da_copy);

        var client = websocket_client.WebSocketClient.init(allocator, url_copy, hs_copy, insecure_tls, null);
        client.setReadTimeout(15_000);

        return .{
            .allocator = allocator,
            .ws_url = url_copy,
            .handshake_token = hs_copy,
            .connect_auth_token = ca_copy,
            .device_auth_token = da_copy,
            .insecure_tls = insecure_tls,
            .ws_client = client,
            .next_attempt_at_ms = node_platform.nowMs(),
        };
    }

    pub fn deinit(self: *SingleThreadConnectionManager) void {
        self.ws_client.deinit();
        self.allocator.free(self.ws_url);
        self.allocator.free(self.handshake_token);
        self.allocator.free(self.connect_auth_token);
        self.allocator.free(self.device_auth_token);
    }

    /// Update the token used for connect auth (params.auth.token).
    /// This should match the WS Authorization token.
    /// Update the connect auth token (params.auth.token).
    /// This is typically the paired device token for nodes.
    pub fn setConnectAuthToken(self: *SingleThreadConnectionManager, token: []const u8) !void {
        if (std.mem.eql(u8, self.connect_auth_token, token)) return;

        const tok_copy = try self.allocator.dupe(u8, token);
        self.allocator.free(self.connect_auth_token);
        self.connect_auth_token = tok_copy;
    }

    /// Update the token used inside the device-auth signed payload.
    pub fn setDeviceAuthToken(self: *SingleThreadConnectionManager, token: []const u8) !void {
        if (std.mem.eql(u8, self.device_auth_token, token)) return;

        const tok_copy = try self.allocator.dupe(u8, token);
        self.allocator.free(self.device_auth_token);
        self.device_auth_token = tok_copy;
    }

    fn computeDelayMs(self: *SingleThreadConnectionManager) u64 {
        // Cap exponent to avoid overflow and because we clamp anyway.
        const exp: u32 = @min(self.reconnect_attempt, 15);
        var delay_ms: u64 = self.base_delay_ms * std.math.pow(u64, 2, exp);
        delay_ms = @min(delay_ms, self.max_delay_ms);
        const jitter: u64 = @intFromFloat(std.crypto.random.float(f64) * 250.0);
        return delay_ms + jitter;
    }

    pub fn disconnect(self: *SingleThreadConnectionManager) void {
        if (self.is_connected) {
            self.is_connected = false;
            if (self.onDisconnected) |cb| cb(self);
        }

        if (self.ws_mutex) |m| m.lock();
        defer if (self.ws_mutex) |m| m.unlock();

        self.ws_client.deinit();
        // Re-init client in a clean state (preserves url/token copies).
        self.ws_client = websocket_client.WebSocketClient.init(self.allocator, self.ws_url, self.handshake_token, self.insecure_tls, null);
        self.ws_client.setReadTimeout(15_000);
        self.next_attempt_at_ms = node_platform.nowMs() + @as(i64, @intCast(self.computeDelayMs()));
    }

    pub fn step(self: *SingleThreadConnectionManager) void {
        const now = node_platform.nowMs();

        if (!self.is_connected) {
            if (now < self.next_attempt_at_ms) return;

            if (self.ws_mutex) |m| m.lock();
            defer if (self.ws_mutex) |m| m.unlock();

            if (self.onConfigureClient) |cb| cb(self, &self.ws_client);

            self.ws_client.connect() catch |err| {
                logger.err("Connection failed: {s}", .{@errorName(err)});
                self.reconnect_attempt += 1;
                self.next_attempt_at_ms = now + @as(i64, @intCast(self.computeDelayMs()));
                return;
            };

            self.is_connected = true;
            self.reconnect_attempt = 0;
            if (self.onConnected) |cb| cb(self);
            return;
        }

        // Connected: keep pumping.
        if (self.ws_mutex) |m| m.lock();
        self.ws_client.poll() catch {};
        if (self.ws_mutex) |m| m.unlock();

        if (!self.ws_client.is_connected) {
            self.disconnect();
        }
    }
};
