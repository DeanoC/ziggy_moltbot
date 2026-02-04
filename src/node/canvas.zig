const std = @import("std");
const node_context = @import("node_context.zig");
const NodeContext = node_context.NodeContext;
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
        // Find Chrome executable
        const chrome_paths = &[_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/chrome",
        };

        var chrome_path: ?[]const u8 = null;

        if (self.config.chrome_path) |configured| {
            chrome_path = configured;
        } else {
            for (chrome_paths) |path| {
                std.fs.cwd().access(path, .{ .mode = .read_only }) catch continue;
                chrome_path = path;
                break;
            }
        }

        if (chrome_path == null) {
            logger.err("Chrome not found. Install Chrome or set chrome_path in config.", .{});
            return error.ChromeNotFound;
        }

        // Start Chrome in headless mode with remote debugging
        const args = &[_][]const u8{
            chrome_path.?,
            "--headless",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-software-rasterizer",
            "--disable-dev-shm-usage",
            "--remote-debugging-address=127.0.0.1",
            try std.fmt.allocPrint(self.allocator, "--remote-debugging-port={d}", .{self.config.chrome_debug_port}),
            "--window-size=",
            try std.fmt.allocPrint(self.allocator, "{d},{d}", .{ self.config.width, self.config.height }),
            "about:blank",
        };
        defer {
            self.allocator.free(args[6]);
            self.allocator.free(args[7]);
        }

        var child = std.process.Child.init(args, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        self.chrome_process = child;

        // Wait for Chrome to start
        node_platform.sleepMs(2000);

        logger.info("Chrome started on debug port {d}", .{self.config.chrome_debug_port});
    }

    fn presentChrome(self: *Canvas) !void {
        _ = self;
        // Chrome is already "present" when started
        // For headless mode, this is a no-op
        // For headed mode, we'd need to manage X11 window
    }

    fn hideChrome(self: *Canvas) !void {
        _ = self;
        // No-op in headless mode
    }

    fn navigateChrome(self: *Canvas, url: []const u8) !void {
        const debug_url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}/json/new?{s}", .{ self.config.chrome_debug_port, url });
        // Use HTTP client to navigate - Chrome DevTools Protocol
        logger.warn("Chrome navigation requires CDP implementation: {s}", .{debug_url});
        self.allocator.free(debug_url);
    }

    fn evalChrome(self: *Canvas, js: []const u8) ![]const u8 {
        // Use Chrome DevTools Protocol to evaluate JavaScript
        // This requires WebSocket connection to Chrome
        _ = js;
        logger.warn("Chrome canvas.eval requires WebSocket implementation", .{});
        return try self.allocator.dupe(u8, "");
    }

    fn snapshotChrome(self: *Canvas, output_path: []const u8) !void {
        const debug_url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}/json/list", .{self.config.chrome_debug_port});
        defer self.allocator.free(debug_url);

        // Use Chrome DevTools Protocol to capture screenshot
        _ = output_path;
        logger.warn("Chrome canvas.snapshot requires CDP implementation", .{});
    }
};

/// Canvas manager for A2UI support
pub const CanvasManager = struct {
    allocator: std.mem.Allocator,
    canvas: ?Canvas = null,

    pub fn init(allocator: std.mem.Allocator) CanvasManager {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CanvasManager) void {
        if (self.canvas) |*c| {
            c.deinit();
        }
    }

    /// Initialize canvas with config
    pub fn initialize(self: *CanvasManager, config: CanvasConfig) !void {
        if (self.canvas) |*c| {
            c.deinit();
        }

        self.canvas = try Canvas.init(self.allocator, config);
    }

    /// Get canvas instance
    pub fn getCanvas(self: *CanvasManager) ?*Canvas {
        if (self.canvas) |*c| {
            return c;
        }
        return null;
    }
};
