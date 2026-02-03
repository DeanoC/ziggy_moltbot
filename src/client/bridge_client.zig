const std = @import("std");
const logger = @import("../utils/logger.zig");

/// OpenClaw node bridge TCP transport.
///
/// Assumptions (based on current OpenClaw gateway behavior):
/// - Messages are JSON objects separated by newlines (\n).
/// - Client sends a hello frame immediately after connecting.
/// - Server responds with hello-ok (either as {type:"hello-ok"} or wrapped).
/// - Subsequent messages may be {type:"req" ...}, {type:"event" ...}, etc.
///
/// We keep this small and tolerant: accept both direct and wrapped hello-ok.
pub const BridgeClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,

    node_id: []const u8,
    node_token: []const u8,
    display_name: []const u8,
    caps: []const []const u8,
    commands: []const []const u8,

    stream: ?std.net.Stream = null,
    is_connected: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        node_id: []const u8,
        node_token: []const u8,
        display_name: []const u8,
        caps: []const []const u8,
        commands: []const []const u8,
    ) BridgeClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .node_id = node_id,
            .node_token = node_token,
            .display_name = display_name,
            .caps = caps,
            .commands = commands,
        };
    }

    pub fn deinit(self: *BridgeClient) void {
        self.disconnect();
    }

    pub fn disconnect(self: *BridgeClient) void {
        if (self.stream) |s| {
            s.close();
        }
        self.stream = null;
        self.is_connected = false;
    }

    pub fn connect(self: *BridgeClient) !void {
        if (self.is_connected) return;
        var s = try std.net.tcpConnectToHost(self.allocator, self.host, self.port);
        errdefer s.close();

        self.stream = s;
        self.is_connected = true;

        // Send hello immediately.
        try self.sendHello();
    }

    pub fn send(self: *BridgeClient, message: []const u8) !void {
        if (!self.is_connected or self.stream == null) return error.NotConnected;
        // Ensure newline delimiter.
        if (message.len > 0 and message[message.len - 1] == '\n') {
            try self.stream.?.writeAll(message);
        } else {
            try self.stream.?.writeAll(message);
            try self.stream.?.writeAll("\n");
        }
    }

    pub fn receive(self: *BridgeClient) !?[]u8 {
        if (!self.is_connected or self.stream == null) return error.NotConnected;

        // Manual line reader (Zig 0.15 std Io refactor removed BufferedReader).
        // Messages are newline-delimited JSON, max 1MB.
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);

        while (true) {
            var b: [1]u8 = undefined;
            const n = self.stream.?.read(&b) catch |err| {
                self.disconnect();
                return err;
            };
            if (n == 0) {
                self.disconnect();
                if (list.items.len == 0) return null;
                break;
            }
            if (b[0] == '\n') break;
            if (b[0] == '\r') continue;
            try list.append(self.allocator, b[0]);
            if (list.items.len > 1024 * 1024) return error.MessageTooLarge;
        }

        if (list.items.len == 0) {
            list.deinit(self.allocator);
            return null;
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn waitForHelloOk(self: *BridgeClient, timeout_ms: u64) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (self.is_connected and std.time.milliTimestamp() < deadline) {
            const msg = try self.receive();
            if (msg) |payload| {
                defer self.allocator.free(payload);
                if (isHelloOk(payload)) return;
                // ignore other frames during startup
            } else {
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
        }
        return error.Timeout;
    }

    fn sendHello(self: *BridgeClient) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        // Keep schema-safe and minimal.
        const Hello = struct {
            type: []const u8 = "hello",
            nodeId: []const u8,
            token: []const u8,
            displayName: []const u8,
            platform: []const u8,
            caps: []const []const u8,
            commands: []const []const u8,
        };

        const hello: Hello = .{
            .nodeId = self.node_id,
            .token = self.node_token,
            .displayName = self.display_name,
            .platform = @tagName(@import("builtin").target.os.tag),
            .caps = self.caps,
            .commands = self.commands,
        };

        try std.json.Stringify.value(hello, .{ .emit_null_optional_fields = false }, &out.writer);
        const s = try out.toOwnedSlice();
        defer self.allocator.free(s);

        logger.debug("bridge: sending hello len={d}", .{s.len});
        try self.send(s);
    }

    fn isHelloOk(payload: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch return false;
        defer parsed.deinit();

        if (parsed.value != .object) return false;
        const root = parsed.value.object;

        // Direct {type:"hello-ok"}
        if (root.get("type")) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "hello-ok")) return true;
        }

        // Wrapped {type:"res", ok:true, payload:{type:"hello-ok"}}
        if (root.get("payload")) |pv| {
            if (pv == .object) {
                if (pv.object.get("type")) |pt| {
                    if (pt == .string and std.mem.eql(u8, pt.string, "hello-ok")) return true;
                }
            }
        }

        return false;
    }
};
