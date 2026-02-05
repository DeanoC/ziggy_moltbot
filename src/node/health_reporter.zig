const std = @import("std");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
const websocket_client = @import("../client/websocket_client.zig");
const messages = @import("../protocol/messages.zig");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

/// Health reporter for node status updates
pub const HealthReporter = struct {
    // NOTE: This struct runs on a background thread. Do not use a non-thread-safe
    // allocator from the main thread here.
    node_ctx: *NodeContext,
    ws_client: *websocket_client.WebSocketClient,
    ws_mutex: ?*std.Thread.Mutex = null,
    running: bool = false,
    thread: ?std.Thread = null,
    interval_ms: i64 = 10000, // 10 seconds (gateway liveness is fairly aggressive)

    pub fn init(
        allocator: std.mem.Allocator,
        node_ctx: *NodeContext,
        ws_client: *websocket_client.WebSocketClient,
    ) HealthReporter {
        _ = allocator;
        return .{
            .node_ctx = node_ctx,
            .ws_client = ws_client,
            .interval_ms = 10000,
        };
    }

    pub fn setMutex(self: *HealthReporter, m: ?*std.Thread.Mutex) void {
        self.ws_mutex = m;
    }

    pub fn start(self: *HealthReporter) !void {
        if (self.running) return;
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, healthReporterThread, .{self});
    }

    pub fn stop(self: *HealthReporter) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn healthReporterThread(self: *HealthReporter) void {
        while (self.running) {
            // Send heartbeat
            self.sendHeartbeat() catch |err| {
                logger.err("Failed to send heartbeat: {s}", .{@errorName(err)});
            };

            // Cleanup old processes
            self.node_ctx.process_manager.cleanup(3600000); // 1 hour

            // Sleep
            node_platform.sleepMs(@intCast(self.interval_ms));
        }
    }

    fn sendHeartbeat(self: *HealthReporter) !void {
        // IMPORTANT: The gateway requires the *first* request on a fresh WS connection
        // to be `connect`. Do not emit `node.heartbeat` until the node is fully
        // registered (hello-ok received).
        switch (self.node_ctx.state) {
            .idle, .executing, .error_state => {},
            else => return,
        }

        // Avoid sharing the main thread allocator: use a per-heartbeat arena backed by
        // the global page allocator (thread-safe).
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const request_id = try makeRequestId(a);

        // Build health payload
        var health_data = std.json.ObjectMap.init(a);

        // Node state
        try health_data.put("state", std.json.Value{ .string = @tagName(self.node_ctx.state) });

        // Stats
        try health_data.put("commandsExecuted", std.json.Value{ .integer = @intCast(self.node_ctx.commands_executed) });
        try health_data.put("commandsFailed", std.json.Value{ .integer = @intCast(self.node_ctx.commands_failed) });

        // System metrics
        const mem_info = try getMemoryInfo(a);
        try health_data.put("memoryTotal", std.json.Value{ .string = mem_info.total });
        try health_data.put("memoryAvailable", std.json.Value{ .string = mem_info.available });

        const load = try getLoadAverage(a);
        try health_data.put("loadAverage", std.json.Value{ .string = load });

        // Active processes count
        const process_list = try self.node_ctx.process_manager.listProcesses(a);
        try health_data.put("activeProcesses", std.json.Value{ .integer = @intCast(process_list.array.items.len) });

        // Build heartbeat frame
        const frame = .{
            .type = "req",
            .id = request_id,
            .method = "node.heartbeat",
            .params = .{
                .status = "healthy",
                .data = std.json.Value{ .object = health_data },
            },
        };

        const payload = try messages.serializeMessage(a, frame);

        if (self.ws_mutex) |m| m.lock();
        defer if (self.ws_mutex) |m| m.unlock();

        try self.ws_client.send(payload);
        logger.debug("Heartbeat sent", .{});
    }
};

fn makeRequestId(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = node_platform.nowMs();
    const random = std.crypto.random.int(u32);
    return try std.fmt.allocPrint(allocator, "req_{d}_{x}", .{ timestamp, random });
}

const MemoryInfo = struct {
    total: []const u8,
    available: []const u8,
};

fn getMemoryInfo(allocator: std.mem.Allocator) !MemoryInfo {
    var total: []const u8 = try allocator.dupe(u8, "unknown");
    var available: []const u8 = try allocator.dupe(u8, "unknown");
    errdefer {
        allocator.free(total);
        allocator.free(available);
    }

    const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return MemoryInfo{
        .total = total,
        .available = available,
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            allocator.free(total);
            total = try allocator.dupe(u8, std.mem.trim(u8, line["MemTotal:".len..], " \t"));
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            allocator.free(available);
            available = try allocator.dupe(u8, std.mem.trim(u8, line["MemAvailable:".len..], " \t"));
        }
    }

    return MemoryInfo{
        .total = total,
        .available = available,
    };
}

fn getLoadAverage(allocator: std.mem.Allocator) ![]const u8 {
    const file = std.fs.cwd().openFile("/proc/loadavg", .{}) catch {
        return try allocator.dupe(u8, "0.00 0.00 0.00");
    };
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = std.mem.trim(u8, buf[0..n], " \t\n");

    return try allocator.dupe(u8, content);
}
