const std = @import("std");
const builtin = @import("builtin");
const ws = @import("websocket");
const logger = @import("../utils/logger.zig");
const node_platform = @import("node_platform.zig");

/// Canvas backend type
pub const CanvasBackend = enum {
    webkitgtk,
    chrome,
    none,
};

/// Canvas configuration
pub const CanvasConfig = struct {
    backend: CanvasBackend = .webkitgtk,
    width: u32 = 1280,
    height: u32 = 720,
    headless: bool = true,
    chrome_path: ?[]const u8 = null,
    chrome_debug_port: u16 = 9222,
};

/// Canvas state
pub const CanvasState = enum {
    hidden,
    visible,
    navigating,
    error_state,
};

/// Canvas instance
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    config: CanvasConfig,
    state: CanvasState = .hidden,
    current_url: ?[]const u8 = null,

    // Backend-specific handles
    webkit_context: ?*WebKitContext = null,
    chrome_process: ?std.process.Child = null,
    chrome_runtime_debug_port: ?u16 = null,
    chrome_user_data_dir: ?[]const u8 = null,

    const WebKitContext = opaque {};

    pub fn init(allocator: std.mem.Allocator, config: CanvasConfig) !Canvas {
        var canvas = Canvas{
            .allocator = allocator,
            .config = config,
        };

        switch (config.backend) {
            .webkitgtk => {
                canvas.webkit_context = try initWebKitGtk(allocator, config);
            },
            .chrome => {
                try canvas.initChrome();
            },
            .none => {
                logger.info("Canvas backend: none (canvas disabled)", .{});
            },
        }

        return canvas;
    }

    pub fn deinit(self: *Canvas) void {
        if (self.current_url) |url| {
            self.allocator.free(url);
        }

        switch (self.config.backend) {
            .webkitgtk => {
                if (self.webkit_context) |ctx| {
                    deinitWebKitGtk(ctx);
                }
            },
            .chrome => {
                if (self.chrome_process) |*proc| {
                    _ = proc.kill() catch {};
                }
                if (self.chrome_user_data_dir) |dir| {
                    std.fs.cwd().deleteTree(dir) catch {};
                    self.allocator.free(dir);
                    self.chrome_user_data_dir = null;
                }
            },
            .none => {},
        }
    }

    /// Present/show the canvas
    pub fn present(self: *Canvas) !void {
        if (self.config.backend == .none) {
            return error.CanvasDisabled;
        }

        switch (self.config.backend) {
            .webkitgtk => try self.presentWebKitGtk(),
            .chrome => try self.presentChrome(),
            .none => unreachable,
        }

        self.state = .visible;
        logger.info("Canvas presented", .{});
    }

    /// Hide the canvas
    pub fn hide(self: *Canvas) !void {
        if (self.config.backend == .none) {
            return error.CanvasDisabled;
        }

        switch (self.config.backend) {
            .webkitgtk => try self.hideWebKitGtk(),
            .chrome => try self.hideChrome(),
            .none => unreachable,
        }

        self.state = .hidden;
        logger.info("Canvas hidden", .{});
    }

    /// Navigate to URL
    pub fn navigate(self: *Canvas, url: []const u8) !void {
        if (self.config.backend == .none) {
            return error.CanvasDisabled;
        }

        const url_copy = try self.allocator.dupe(u8, url);
        if (self.current_url) |old| {
            self.allocator.free(old);
        }
        self.current_url = url_copy;

        self.state = .navigating;

        switch (self.config.backend) {
            .webkitgtk => try self.navigateWebKitGtk(url),
            .chrome => try self.navigateChrome(url),
            .none => unreachable,
        }

        self.state = .visible;
        logger.info("Canvas navigated to: {s}", .{url});
    }

    /// Evaluate JavaScript
    pub fn eval(self: *Canvas, js: []const u8) ![]const u8 {
        if (self.config.backend == .none) {
            return error.CanvasDisabled;
        }

        switch (self.config.backend) {
            .webkitgtk => return try self.evalWebKitGtk(js),
            .chrome => return try self.evalChrome(js),
            .none => unreachable,
        }
    }

    /// Capture screenshot
    pub fn snapshot(self: *Canvas, output_path: []const u8) !void {
        if (self.config.backend == .none) {
            return error.CanvasDisabled;
        }

        switch (self.config.backend) {
            .webkitgtk => try self.snapshotWebKitGtk(output_path),
            .chrome => try self.snapshotChrome(output_path),
            .none => unreachable,
        }

        logger.info("Canvas snapshot saved to: {s}", .{output_path});
    }

    // =========================================================================
    // WebKitGTK Implementation
    // =========================================================================

    fn initWebKitGtk(allocator: std.mem.Allocator, config: CanvasConfig) !?*WebKitContext {
        _ = allocator;
        _ = config;
        // WebKitGTK initialization via C interop would go here
        // For now, return null to indicate not implemented
        logger.warn("WebKitGTK canvas not yet implemented", .{});
        return null;
    }

    fn deinitWebKitGtk(ctx: *WebKitContext) void {
        _ = ctx;
    }

    fn presentWebKitGtk(self: *Canvas) !void {
        _ = self;
        logger.warn("WebKitGTK canvas.present not yet implemented", .{});
        return error.NotImplemented;
    }

    fn hideWebKitGtk(self: *Canvas) !void {
        _ = self;
        logger.warn("WebKitGTK canvas.hide not yet implemented", .{});
        return error.NotImplemented;
    }

    fn navigateWebKitGtk(self: *Canvas, url: []const u8) !void {
        _ = self;
        _ = url;
        logger.warn("WebKitGTK canvas.navigate not yet implemented", .{});
        return error.NotImplemented;
    }

    fn evalWebKitGtk(self: *Canvas, js: []const u8) ![]const u8 {
        _ = self;
        _ = js;
        logger.warn("WebKitGTK canvas.eval not yet implemented", .{});
        return error.NotImplemented;
    }

    fn snapshotWebKitGtk(self: *Canvas, output_path: []const u8) !void {
        _ = self;
        _ = output_path;
        logger.warn("WebKitGTK canvas.snapshot not yet implemented", .{});
        return error.NotImplemented;
    }

    // =========================================================================
    // Chrome/Headless Implementation
    // =========================================================================

    fn initChrome(self: *Canvas) !void {
        const chrome_path = try self.resolveChromeExecutableAlloc();
        defer self.allocator.free(chrome_path);

        const user_data_dir = try self.makeChromeUserDataDirAlloc();
        self.chrome_user_data_dir = user_data_dir;
        errdefer {
            std.fs.cwd().deleteTree(user_data_dir) catch {};
            self.allocator.free(user_data_dir);
            self.chrome_user_data_dir = null;
        }

        // Start Chrome in headless mode with remote debugging.
        const debug_port_arg = try std.fmt.allocPrint(self.allocator, "--remote-debugging-port={d}", .{self.config.chrome_debug_port});
        defer self.allocator.free(debug_port_arg);
        const window_size_arg = try std.fmt.allocPrint(self.allocator, "--window-size={d},{d}", .{ self.config.width, self.config.height });
        defer self.allocator.free(window_size_arg);
        const user_data_dir_arg = try std.fmt.allocPrint(self.allocator, "--user-data-dir={s}", .{user_data_dir});
        defer self.allocator.free(user_data_dir_arg);

        const args = &[_][]const u8{
            chrome_path,
            "--headless",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-software-rasterizer",
            "--disable-dev-shm-usage",
            user_data_dir_arg,
            "--remote-debugging-address=127.0.0.1",
            debug_port_arg,
            window_size_arg,
            "about:blank",
        };

        var child = std.process.Child.init(args, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        self.chrome_process = child;
        errdefer {
            logger.warn("Canvas Chrome init failed; terminating spawned Chrome process", .{});
            if (self.chrome_process) |*proc| {
                _ = proc.kill() catch {};
            }
            self.chrome_process = null;
        }

        // Port 0 means Chrome picks an available debugging port.
        const debug_port = if (self.config.chrome_debug_port == 0)
            try self.waitForDevToolsPortAlloc(user_data_dir)
        else
            self.config.chrome_debug_port;
        self.chrome_runtime_debug_port = debug_port;

        // Wait for DevTools endpoint to become ready.
        const start_ms = node_platform.nowMs();
        while (node_platform.nowMs() - start_ms < 10_000) {
            const body = self.chromeHttpGetAlloc("/json/version") catch {
                node_platform.sleepMs(100);
                continue;
            };
            self.allocator.free(body);
            logger.info("Chrome started on debug port {d}", .{debug_port});
            return;
        }

        logger.err("Chrome started but DevTools endpoint did not become ready", .{});
        return error.Timeout;
    }

    fn makeChromeUserDataDirAlloc(self: *Canvas) ![]u8 {
        var rand: [8]u8 = undefined;
        std.crypto.random.bytes(&rand);
        const suffix = std.fmt.bytesToHex(rand, .lower);
        const dirname = try std.fmt.allocPrint(self.allocator, "oc-canvas-{s}", .{suffix});
        defer self.allocator.free(dirname);

        const temp_dir = try self.getSystemTempDirAlloc();
        defer self.allocator.free(temp_dir);

        const full = try std.fs.path.join(self.allocator, &.{ temp_dir, dirname });
        errdefer self.allocator.free(full);

        std.fs.cwd().makePath(full) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return full;
    }

    fn getSystemTempDirAlloc(self: *Canvas) ![]u8 {
        const envs = if (builtin.os.tag == .windows)
            &[_][]const u8{ "TEMP", "TMP" }
        else
            &[_][]const u8{ "TMPDIR", "TMP", "TEMP" };

        for (envs) |key| {
            const value = std.process.getEnvVarOwned(self.allocator, key) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (value) |dir| {
                if (dir.len == 0) {
                    self.allocator.free(dir);
                    continue;
                }
                return dir;
            }
        }

        // Prefer current working directory over hardcoded paths on Windows to avoid
        // drive-root permission failures when TEMP/TMP are missing.
        return self.allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp");
    }

    fn waitForDevToolsPortAlloc(self: *Canvas, user_data_dir: []const u8) !u16 {
        const devtools_port_file = try std.fs.path.join(self.allocator, &.{ user_data_dir, "DevToolsActivePort" });
        defer self.allocator.free(devtools_port_file);

        const start_ms = node_platform.nowMs();
        while (node_platform.nowMs() - start_ms < 10_000) {
            const file = std.fs.cwd().openFile(devtools_port_file, .{}) catch {
                node_platform.sleepMs(50);
                continue;
            };
            defer file.close();

            const contents = file.readToEndAlloc(self.allocator, 4 * 1024) catch {
                node_platform.sleepMs(50);
                continue;
            };
            defer self.allocator.free(contents);

            var line_it = std.mem.splitScalar(u8, contents, '\n');
            const line = line_it.next() orelse {
                node_platform.sleepMs(50);
                continue;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) {
                node_platform.sleepMs(50);
                continue;
            }

            const port = std.fmt.parseInt(u16, trimmed, 10) catch {
                node_platform.sleepMs(50);
                continue;
            };

            if (port == 0) {
                node_platform.sleepMs(50);
                continue;
            }

            return port;
        }

        return error.Timeout;
    }

    fn resolveChromeExecutableAlloc(self: *Canvas) ![]u8 {
        if (self.config.chrome_path) |configured| {
            if (std.fs.path.isAbsolute(configured)) {
                std.fs.accessAbsolute(configured, .{ .mode = .read_only }) catch return error.ChromeNotFound;
            }
            return self.allocator.dupe(u8, configured);
        }

        const absolute_candidates = &[_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/chrome",
        };
        for (absolute_candidates) |candidate| {
            std.fs.accessAbsolute(candidate, .{ .mode = .read_only }) catch continue;
            return self.allocator.dupe(u8, candidate);
        }

        const command_candidates = &[_][]const u8{
            "google-chrome",
            "google-chrome-stable",
            "chromium",
            "chromium-browser",
            "chrome",
            "google-chrome.exe",
            "google-chrome-stable.exe",
            "chromium.exe",
            "chromium-browser.exe",
            "chrome.exe",
        };
        for (command_candidates) |candidate| {
            if (try findCommandOnPathAlloc(self.allocator, candidate)) |resolved| {
                return resolved;
            }
        }

        logger.err("Chrome not found. Install Chrome or set chrome_path in config.", .{});
        return error.ChromeNotFound;
    }

    fn findCommandOnPathAlloc(allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => return err,
        };
        defer allocator.free(path_env);

        var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;

            const full = try std.fs.path.join(allocator, &.{ dir, command });
            errdefer allocator.free(full);

            if (std.fs.path.isAbsolute(full)) {
                std.fs.accessAbsolute(full, .{ .mode = .read_only }) catch {
                    allocator.free(full);
                    continue;
                };
            } else {
                std.fs.cwd().access(full, .{ .mode = .read_only }) catch {
                    allocator.free(full);
                    continue;
                };
            }

            return full;
        }

        return null;
    }

    fn presentChrome(self: *Canvas) !void {
        _ = self;
        // Chrome is already "present" when started.
    }

    fn hideChrome(self: *Canvas) !void {
        _ = self;
        // No-op in headless mode.
    }

    fn navigateChrome(self: *Canvas, url: []const u8) !void {
        var session = try self.openChromeCdpSession();
        defer session.client.deinit();

        const enable_resp = try self.cdpSendCommandAlloc(&session, "Page.enable", .{});
        self.allocator.free(enable_resp);

        const nav_resp = try self.cdpSendCommandAlloc(&session, "Page.navigate", .{ .url = url });
        defer self.allocator.free(nav_resp);
        try validateNavigationResponse(nav_resp);

        // Give the browser a short moment to process navigation events.
        node_platform.sleepMs(200);
    }

    fn evalChrome(self: *Canvas, js: []const u8) ![]const u8 {
        var session = try self.openChromeCdpSession();
        defer session.client.deinit();

        const resp = try self.cdpSendCommandAlloc(&session, "Runtime.evaluate", .{
            .expression = js,
            .returnByValue = true,
            .awaitPromise = true,
        });
        defer self.allocator.free(resp);

        return try extractRuntimeEvaluateResultAlloc(self.allocator, resp);
    }

    fn snapshotChrome(self: *Canvas, output_path: []const u8) !void {
        const encoded = try self.snapshotChromeBase64("png", null, null);
        defer self.allocator.free(encoded);

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);

        const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(decoded);
    }

    pub fn snapshotBase64(self: *Canvas, format: []const u8, quality: ?u8, max_width: ?u32) ![]u8 {
        if (self.config.backend == .none) return error.CanvasDisabled;

        return switch (self.config.backend) {
            .webkitgtk => error.NotImplemented,
            .chrome => self.snapshotChromeBase64(format, quality, max_width),
            .none => unreachable,
        };
    }

    const CdpSession = struct {
        client: ws.Client,
        next_id: i64 = 1,
    };

    const ParsedWsUrl = struct {
        host: []const u8,
        host_header: []const u8,
        port: u16,
        path: []const u8,
        tls: bool,
        origin: []const u8,

        fn deinit(self: ParsedWsUrl, allocator: std.mem.Allocator) void {
            allocator.free(self.host);
            allocator.free(self.host_header);
            allocator.free(self.path);
            allocator.free(self.origin);
        }
    };

    fn openChromeCdpSession(self: *Canvas) !CdpSession {
        const ws_url = try self.discoverCdpWebSocketUrlAlloc();
        defer self.allocator.free(ws_url);

        const parsed = try parseWebSocketUrlAlloc(self.allocator, ws_url);
        defer parsed.deinit(self.allocator);

        const headers = try std.fmt.allocPrint(self.allocator, "Host: {s}\r\nOrigin: {s}", .{ parsed.host_header, parsed.origin });
        defer self.allocator.free(headers);

        var client = try ws.Client.init(self.allocator, .{
            .port = parsed.port,
            .host = parsed.host,
            .tls = parsed.tls,
            .verify_host = false,
            .verify_cert = false,
            .max_size = 32 * 1024 * 1024,
            .buffer_size = 64 * 1024,
        });
        errdefer client.deinit();

        try client.handshake(parsed.path, .{ .timeout_ms = 5_000, .headers = headers });
        try client.readTimeout(100);

        return .{ .client = client };
    }

    fn cdpSendCommandAlloc(self: *Canvas, session: *CdpSession, method: []const u8, params: anytype) ![]u8 {
        const request_id = session.next_id;
        session.next_id += 1;

        const request_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .id = request_id,
            .method = method,
            .params = params,
        }, .{
            .emit_null_optional_fields = false,
        });
        defer self.allocator.free(request_json);

        const writable = try self.allocator.dupe(u8, request_json);
        defer self.allocator.free(writable);
        try session.client.write(writable);

        const deadline_ms = node_platform.nowMs() + 10_000;
        while (node_platform.nowMs() < deadline_ms) {
            const msg = try session.client.read() orelse continue;
            defer session.client.done(msg);

            switch (msg.type) {
                .text, .binary => {
                    if (try isMatchingCdpResponse(msg.data, request_id)) {
                        return try self.allocator.dupe(u8, msg.data);
                    }
                },
                .ping => try session.client.writePong(msg.data),
                .pong => {},
                .close => return error.ConnectionClosed,
            }
        }

        return error.Timeout;
    }

    fn snapshotChromeBase64(self: *Canvas, format_raw: []const u8, quality_raw: ?u8, max_width: ?u32) ![]u8 {
        var session = try self.openChromeCdpSession();
        defer session.client.deinit();
        var metrics_overridden = false;
        defer {
            if (metrics_overridden) {
                if (self.cdpSendCommandAlloc(&session, "Emulation.clearDeviceMetricsOverride", .{})) |clear_resp| {
                    self.allocator.free(clear_resp);
                } else |err| {
                    logger.warn("Failed to clear Chrome device metrics override after snapshot: {any}", .{err});
                }
            }
        }

        const format = if (std.ascii.eqlIgnoreCase(format_raw, "jpg") or std.ascii.eqlIgnoreCase(format_raw, "jpeg")) "jpeg" else "png";

        const enable_resp = try self.cdpSendCommandAlloc(&session, "Page.enable", .{});
        self.allocator.free(enable_resp);

        if (max_width) |w| {
            if (w > 0 and w != self.config.width) {
                const scaled_height_u64 = @max(1, (@as(u64, @intCast(self.config.height)) * @as(u64, @intCast(w))) / @max(@as(u64, @intCast(self.config.width)), 1));
                const scaled_height = @as(u32, @intCast(@min(scaled_height_u64, std.math.maxInt(u32))));
                const emulation_resp = try self.cdpSendCommandAlloc(&session, "Emulation.setDeviceMetricsOverride", .{
                    .width = w,
                    .height = scaled_height,
                    .deviceScaleFactor = 1,
                    .mobile = false,
                });
                self.allocator.free(emulation_resp);
                metrics_overridden = true;
            }
        }

        const quality = if (format[0] == 'j') blk: {
            if (quality_raw) |q| {
                break :blk @as(u8, @intCast(@min(@as(u16, q), 100)));
            }
            break :blk @as(u8, 85);
        } else null;

        const shot_resp = try self.cdpSendCommandAlloc(&session, "Page.captureScreenshot", .{
            .format = format,
            .quality = quality,
            .fromSurface = true,
        });
        defer self.allocator.free(shot_resp);

        return extractScreenshotBase64Alloc(self.allocator, shot_resp);
    }

    fn discoverCdpWebSocketUrlAlloc(self: *Canvas) ![]u8 {
        const list_body = try self.chromeHttpGetAlloc("/json/list");
        defer self.allocator.free(list_body);

        if (try parseWebSocketUrlFromTargetListAlloc(self.allocator, list_body)) |ws_url| {
            return ws_url;
        }

        const created_body = try self.chromeHttpGetAlloc("/json/new?about:blank");
        defer self.allocator.free(created_body);

        if (try parseWebSocketUrlFromTargetObjectAlloc(self.allocator, created_body)) |ws_url| {
            return ws_url;
        }

        return error.TargetNotFound;
    }

    fn chromeHttpGetAlloc(self: *Canvas, path: []const u8) ![]u8 {
        const debug_port = self.chrome_runtime_debug_port orelse self.config.chrome_debug_port;
        const url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ debug_port, path });
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });

        if (result.status != .ok) return error.Unexpected;

        return body.toOwnedSlice();
    }

    fn parseWebSocketUrlAlloc(allocator: std.mem.Allocator, raw_url: []const u8) !ParsedWsUrl {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const uri = std.Uri.parse(raw_url) catch return error.InvalidUrl;
        const scheme = uri.scheme;
        const tls = std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https");
        if (!tls and !std.mem.eql(u8, scheme, "ws") and !std.mem.eql(u8, scheme, "http")) {
            return error.UnsupportedScheme;
        }

        const host_tmp = try uri.getHostAlloc(aa);
        const host = try allocator.dupe(u8, host_tmp);
        errdefer allocator.free(host);

        const default_port: u16 = if (tls) 443 else 80;
        const port: u16 = uri.port orelse default_port;

        const host_header = if (port != default_port)
            try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port })
        else
            try allocator.dupe(u8, host);
        errdefer allocator.free(host_header);

        const path_raw = try uri.path.toRawMaybeAlloc(aa);
        const base_path = if (path_raw.len == 0) "/" else path_raw;
        const path = if (uri.query) |query| blk: {
            const query_raw = try query.toRawMaybeAlloc(aa);
            break :blk try std.fmt.allocPrint(allocator, "{s}?{s}", .{ base_path, query_raw });
        } else try allocator.dupe(u8, base_path);
        errdefer allocator.free(path);

        const origin_scheme = if (tls) "https" else "http";
        const origin = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ origin_scheme, host_header });
        errdefer allocator.free(origin);

        return .{
            .host = host,
            .host_header = host_header,
            .port = port,
            .path = path,
            .tls = tls,
            .origin = origin,
        };
    }

    fn isMatchingCdpResponse(raw: []const u8, expected_id: i64) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return false;
        defer parsed.deinit();

        if (parsed.value != .object) return false;
        const id_value = parsed.value.object.get("id") orelse return false;

        const id = switch (id_value) {
            .integer => |ival| ival,
            .float => |fval| blk: {
                if (!std.math.isFinite(fval) or @trunc(fval) != fval) return false;
                break :blk @as(i64, @intFromFloat(fval));
            },
            else => return false,
        };

        if (id != expected_id) return false;

        if (parsed.value.object.get("error")) |err_value| {
            if (err_value == .object) {
                if (err_value.object.get("message")) |msg| {
                    if (msg == .string) {
                        logger.err("CDP command failed: {s}", .{msg.string});
                    }
                }
            }
            return error.ExecutionFailed;
        }

        return true;
    }

    fn extractRuntimeEvaluateResultAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value != .object) return error.Unexpected;
        const root_result = parsed.value.object.get("result") orelse return error.Unexpected;
        if (root_result != .object) return error.Unexpected;

        if (root_result.object.get("exceptionDetails") != null) {
            return error.ExecutionFailed;
        }

        const runtime_result = root_result.object.get("result") orelse return error.Unexpected;
        if (runtime_result != .object) return error.Unexpected;

        if (runtime_result.object.get("value")) |value| {
            return jsonValueToStringAlloc(allocator, value);
        }

        if (runtime_result.object.get("unserializableValue")) |uv| {
            if (uv == .string) return allocator.dupe(u8, uv.string);
        }

        if (runtime_result.object.get("description")) |desc| {
            if (desc == .string) return allocator.dupe(u8, desc.string);
        }

        return allocator.dupe(u8, "undefined");
    }

    fn extractScreenshotBase64Alloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value != .object) return error.Unexpected;
        const root_result = parsed.value.object.get("result") orelse return error.Unexpected;
        if (root_result != .object) return error.Unexpected;

        const data = root_result.object.get("data") orelse return error.Unexpected;
        if (data != .string) return error.Unexpected;

        return allocator.dupe(u8, data.string);
    }

    fn parseWebSocketUrlFromTargetListAlloc(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value != .array) return null;

        for (parsed.value.array.items) |entry| {
            if (entry != .object) continue;

            const typ = entry.object.get("type") orelse continue;
            if (typ != .string) continue;
            if (!std.mem.eql(u8, typ.string, "page")) continue;

            const ws_url = entry.object.get("webSocketDebuggerUrl") orelse continue;
            if (ws_url != .string or ws_url.string.len == 0) continue;

            return try allocator.dupe(u8, ws_url.string);
        }

        return null;
    }

    fn parseWebSocketUrlFromTargetObjectAlloc(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const ws_url = parsed.value.object.get("webSocketDebuggerUrl") orelse return null;
        if (ws_url != .string or ws_url.string.len == 0) return null;

        return try allocator.dupe(u8, ws_url.string);
    }

    fn jsonValueToStringAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
        return switch (value) {
            .null => allocator.dupe(u8, "null"),
            .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
            .string => |s| allocator.dupe(u8, s),
            .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
            .number_string => |n| allocator.dupe(u8, n),
            .array, .object => std.json.Stringify.valueAlloc(allocator, value, .{}),
        };
    }

    fn validateNavigationResponse(raw: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const root_result = parsed.value.object.get("result") orelse return;
        if (root_result != .object) return;
        const error_text = root_result.object.get("errorText") orelse return;
        if (error_text != .string or error_text.string.len == 0) return;

        logger.err("CDP navigate failed: {s}", .{error_text.string});
        return error.ExecutionFailed;
    }
};

/// Canvas manager for A2UI support
pub const CanvasManager = struct {
    allocator: std.mem.Allocator,

    // Optional "real" canvas implementation (future). For now, we treat canvas
    // commands as a logical/virtual canvas that can be snapshotted.
    canvas: ?Canvas = null,

    // Logical state used by the node command handlers.
    visible: bool = false,
    last_url: ?[]const u8 = null,
    last_a2ui_jsonl: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) CanvasManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CanvasManager) void {
        if (self.canvas) |*c| c.deinit();
        if (self.last_url) |u| self.allocator.free(u);
        if (self.last_a2ui_jsonl) |j| self.allocator.free(j);
    }

    pub fn setVisible(self: *CanvasManager, v: bool) void {
        self.visible = v;
    }

    pub fn setUrl(self: *CanvasManager, url: []const u8) !void {
        const copy = try self.allocator.dupe(u8, url);
        if (self.last_url) |old| self.allocator.free(old);
        self.last_url = copy;
    }

    pub fn getUrl(self: *CanvasManager) ?[]const u8 {
        return self.last_url;
    }

    pub fn setA2uiJsonl(self: *CanvasManager, jsonl: []const u8) !void {
        const copy = try self.allocator.dupe(u8, jsonl);
        if (self.last_a2ui_jsonl) |old| self.allocator.free(old);
        self.last_a2ui_jsonl = copy;
    }

    /// Initialize a real canvas with config (optional, future).
    pub fn initialize(self: *CanvasManager, config: CanvasConfig) !void {
        if (self.canvas) |*c| c.deinit();
        self.canvas = try Canvas.init(self.allocator, config);
    }

    pub fn getCanvas(self: *CanvasManager) ?*Canvas {
        if (self.canvas) |*c| return c;
        return null;
    }
};

test "canvas: parse target list picks first page websocket URL" {
    const allocator = std.testing.allocator;
    const raw =
        "[{\"id\":\"worker-1\",\"type\":\"service_worker\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/page/worker\"}," ++
        "{\"id\":\"page-1\",\"type\":\"page\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/page/abc\"}]";

    const ws_url = (try Canvas.parseWebSocketUrlFromTargetListAlloc(allocator, raw)).?;
    defer allocator.free(ws_url);

    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/abc", ws_url);
}

test "canvas: extract runtime evaluate result prefers value" {
    const allocator = std.testing.allocator;
    const raw = "{\"id\":7,\"result\":{\"result\":{\"type\":\"string\",\"value\":\"hello\"}}}";

    const value = try Canvas.extractRuntimeEvaluateResultAlloc(allocator, raw);
    defer allocator.free(value);

    try std.testing.expectEqualStrings("hello", value);
}

test "canvas: extract screenshot base64 payload" {
    const allocator = std.testing.allocator;
    const raw = "{\"id\":3,\"result\":{\"data\":\"aGVsbG8=\"}}";

    const b64 = try Canvas.extractScreenshotBase64Alloc(allocator, raw);
    defer allocator.free(b64);

    try std.testing.expectEqualStrings("aGVsbG8=", b64);
}
