const std = @import("std");
const websocket_client = @import("../client/websocket_client.zig");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

/// Reconnection strategy with exponential backoff
pub const ReconnectStrategy = struct {
    /// Initial delay in milliseconds
    initial_delay_ms: u64 = 1000,
    /// Maximum delay in milliseconds
    max_delay_ms: u64 = 60000,
    /// Backoff multiplier
    multiplier: f64 = 2.0,
    /// Random jitter factor (0-1)
    jitter: f64 = 0.1,
    /// Maximum number of reconnection attempts (0 = unlimited)
    max_attempts: u32 = 0,

    /// Calculate delay for a given attempt
    pub fn getDelay(self: ReconnectStrategy, attempt: u32) u64 {
        if (self.max_attempts > 0 and attempt >= self.max_attempts) {
            return 0; // No more retries
        }

        // Exponential backoff
        const exponential = @as(f64, @floatFromInt(self.initial_delay_ms)) *
            std.math.pow(f64, self.multiplier, @floatFromInt(attempt));

        // Cap at max delay
        const capped = @min(exponential, @as(f64, @floatFromInt(self.max_delay_ms)));

        // Add jitter (±jitter%)
        const jitter_range = capped * self.jitter;
        const jitter_amount = (std.crypto.random.float(f64) * 2.0 - 1.0) * jitter_range;
        const with_jitter = capped + jitter_amount;

        return @intFromFloat(@max(with_jitter, 0));
    }
};

/// Connection state machine
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    authenticating,
    authenticated,
    reconnecting,
    failed,
};

/// Connection manager with automatic reconnection
pub const ConnectionManager = struct {
    allocator: std.mem.Allocator,

    // Connection config
    ws_url: []const u8,
    device_token: []const u8,
    insecure_tls: bool,

    // State
    state: ConnectionState = .disconnected,
    ws_client: ?*websocket_client.WebSocketClient = null,
    reconnect_attempt: u32 = 0,

    // Strategy
    strategy: ReconnectStrategy,

    // Callbacks
    onConnect: ?*const fn (*ConnectionManager) void = null,
    onDisconnect: ?*const fn (*ConnectionManager) void = null,
    onMessage: ?*const fn (*ConnectionManager, []const u8) void = null,

    // Threads
    reconnect_thread: ?std.Thread = null,
    receive_thread: ?std.Thread = null,
    running: bool = false,

    // Synchronization
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(
        allocator: std.mem.Allocator,
        ws_url: []const u8,
        device_token: []const u8,
        insecure_tls: bool,
    ) !ConnectionManager {
        return .{
            .allocator = allocator,
            .ws_url = try allocator.dupe(u8, ws_url),
            .device_token = try allocator.dupe(u8, device_token),
            .insecure_tls = insecure_tls,
            .strategy = .{},
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        self.stop();
        self.allocator.free(self.ws_url);
        self.allocator.free(self.device_token);
    }

    /// Start connection manager
    pub fn start(self: *ConnectionManager) !void {
        if (self.running) return;
        self.running = true;

        // Start receive thread
        self.receive_thread = try std.Thread.spawn(.{}, receiveLoop, .{self});

        // Initial connection
        try self.connect();
    }

    /// Stop connection manager
    pub fn stop(self: *ConnectionManager) void {
        if (!self.running) return;
        self.running = false;

        // Signal condition
        self.cond.broadcast();

        // Disconnect
        self.disconnect();

        // Wait for threads
        if (self.receive_thread) |t| {
            t.join();
            self.receive_thread = null;
        }
        if (self.reconnect_thread) |t| {
            t.join();
            self.reconnect_thread = null;
        }
    }

    /// Connect to gateway
    fn connect(self: *ConnectionManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .connected or self.state == .connecting) return;

        self.state = .connecting;
        logger.info("Connecting to {s}...", .{self.ws_url});

        // Create new client
        if (self.ws_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.ws_client = null;
        }

        const client = try self.allocator.create(websocket_client.WebSocketClient);
        client.* = websocket_client.WebSocketClient.init(
            self.allocator,
            self.ws_url,
            self.device_token,
            self.insecure_tls,
            null,
        );
        client.setReadTimeout(15000);

        client.connect() catch |err| {
            logger.err("Connection failed: {s}", .{@errorName(err)});
            client.deinit();
            self.allocator.destroy(client);
            self.state = .disconnected;
            self.scheduleReconnect();
            return;
        };

        self.ws_client = client;
        self.state = .connected;
        self.reconnect_attempt = 0;

        logger.info("Connected to gateway", .{});

        if (self.onConnect) |cb| {
            cb(self);
        }
    }

    /// Disconnect from gateway
    fn disconnect(self: *ConnectionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ws_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.ws_client = null;
        }

        const was_connected = self.state == .connected or self.state == .authenticated;
        self.state = .disconnected;

        if (was_connected) {
            logger.info("Disconnected from gateway", .{});
            if (self.onDisconnect) |cb| {
                cb(self);
            }
        }
    }

    /// Schedule reconnection attempt
    fn scheduleReconnect(self: *ConnectionManager) void {
        if (self.reconnect_thread != null) return;

        self.reconnect_thread = std.Thread.spawn(.{}, reconnectLoop, .{self}) catch |err| {
            logger.err("Failed to spawn reconnection thread: {s}", .{@errorName(err)});
            null;
        };
    }

    /// Reconnection loop (runs in separate thread)
    fn reconnectLoop(self: *ConnectionManager) void {
        defer {
            self.mutex.lock();
            self.reconnect_thread = null;
            self.mutex.unlock();
        }

        while (self.running) {
            self.mutex.lock();
            const attempt = self.reconnect_attempt;
            self.reconnect_attempt += 1;
            self.mutex.unlock();

            const delay_ms = self.strategy.getDelay(attempt);
            if (delay_ms == 0) {
                logger.err("Max reconnection attempts reached", .{});
                self.mutex.lock();
                self.state = .failed;
                self.mutex.unlock();
                return;
            }

            logger.info("Reconnecting in {d}ms (attempt {d})...", .{ delay_ms, attempt + 1 });
            node_platform.sleepMs(delay_ms);

            if (!self.running) return;

            self.connect() catch {};

            self.mutex.lock();
            const connected = self.state == .connected;
            self.mutex.unlock();

            if (connected) {
                logger.info("Reconnected successfully", .{});
                return;
            }
        }
    }

    /// Receive loop (runs in separate thread)
    fn receiveLoop(self: *ConnectionManager) void {
        while (self.running) {
            self.mutex.lock();
            const connected = self.state == .connected or self.state == .authenticated;
            const client_opt = self.ws_client;
            if (!connected or client_opt == null) {
                self.mutex.unlock();
                node_platform.sleepMs(100);
                continue;
            }

            // Hold the mutex while receiving to prevent the client from being deinit'd concurrently.
            // The read timeout bounds how long we can block here.
            const client = client_opt.?;
            client.poll() catch {};
            const payload = client.receive() catch |err| {
                self.mutex.unlock();
                logger.err("Receive error: {s}", .{@errorName(err)});
                self.handleDisconnect();
                continue;
            };
            self.mutex.unlock();

            if (payload) |text| {
                defer self.allocator.free(text);
                if (self.onMessage) |cb| {
                    cb(self, text);
                }
            } else {
                node_platform.sleepMs(10);
            }
        }
    }

    /// Handle unexpected disconnect
    fn handleDisconnect(self: *ConnectionManager) void {
        self.disconnect();
        if (self.running) {
            self.scheduleReconnect();
        }
    }

    /// Send message (thread-safe)
    pub fn send(self: *ConnectionManager, payload: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ws_client) |client| {
            try client.send(payload);
        } else {
            return error.NotConnected;
        }
    }

    /// Get current state
    pub fn getState(self: *ConnectionManager) ConnectionState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }

    /// Set authenticated state
    pub fn setAuthenticated(self: *ConnectionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .authenticated;
        self.reconnect_attempt = 0;
    }
};
