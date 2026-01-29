const std = @import("std");
const ws = @import("websocket");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    is_connected: bool = false,
    client: ?ws.Client = null,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) WebSocketClient {
        return .{
            .allocator = allocator,
            .url = url,
            .token = token,
        };
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.is_connected) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed = try parseServerUrl(aa, self.url);
        var client = try ws.Client.init(self.allocator, .{
            .port = parsed.port,
            .host = parsed.host,
            .tls = parsed.tls,
            .max_size = 256 * 1024,
            .buffer_size = 8 * 1024,
        });
        errdefer client.deinit();

        const headers = try buildHeaders(aa, parsed.host_header, self.token);
        try client.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = if (headers.len > 0) headers else null,
        });

        self.client = client;
        self.is_connected = true;
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

    pub fn receive(self: *WebSocketClient) !?[]u8 {
        if (!self.is_connected) return error.NotConnected;
        if (self.client) |*client| {
            const message = try client.read() orelse return null;
            defer client.done(message);

            return switch (message.type) {
                .text, .binary => try self.allocator.dupe(u8, message.data),
                .ping => blk: {
                    try client.writePong(message.data);
                    break :blk null;
                },
                .pong => null,
                .close => blk: {
                    try client.close(.{});
                    self.is_connected = false;
                    break :blk null;
                },
            };
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
    }

    pub fn deinit(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.deinit();
            self.client = null;
        }
    }
};

const ParsedUrl = struct {
    host: []const u8,
    host_header: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,
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

    return .{
        .host = host,
        .host_header = host_header,
        .port = port,
        .path = path,
        .tls = tls,
    };
}

fn buildHeaders(allocator: std.mem.Allocator, host_header: []const u8, token: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    const writer = list.writer();
    try writer.print("Host: {s}", .{host_header});
    if (token.len > 0) {
        try writer.print("\r\nAuthorization: Bearer {s}", .{token});
    }
    return list.toOwnedSlice();
}
