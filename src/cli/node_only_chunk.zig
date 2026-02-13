const std = @import("std");
const build_options = @import("build_options");
const config = @import("../client/config.zig");
const update_checker = @import("../client/update_checker.zig");
const logger = @import("../utils/logger.zig");

pub const Options = struct {
    config_path: []const u8,
    override_url: ?[]const u8,
    override_token: ?[]const u8,
    override_token_set: bool,
    override_update_url: ?[]const u8,
    override_insecure: ?bool,
    check_update_only: bool,
    print_update_url: bool,
    save_config: bool,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var cfg = try config.loadOrDefault(allocator, options.config_path);
    defer cfg.deinit(allocator);

    if (options.override_url) |url| {
        allocator.free(cfg.server_url);
        cfg.server_url = try allocator.dupe(u8, url);
    } else {
        const env_url = std.process.getEnvVarOwned(allocator, "MOLT_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_url) |url| {
            allocator.free(cfg.server_url);
            cfg.server_url = url;
        }
    }

    if (options.override_token_set) {
        const token = options.override_token orelse "";
        allocator.free(cfg.token);
        cfg.token = try allocator.dupe(u8, token);
    } else {
        const env_token = std.process.getEnvVarOwned(allocator, "MOLT_TOKEN") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_token) |token| {
            allocator.free(cfg.token);
            cfg.token = token;
        }
    }

    if (options.override_insecure) |value| {
        cfg.insecure_tls = value;
    } else {
        const env_insecure = std.process.getEnvVarOwned(allocator, "MOLT_INSECURE_TLS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_insecure) |value| {
            defer allocator.free(value);
            cfg.insecure_tls = parseBool(value);
        }
    }

    if (options.override_update_url) |url| {
        if (cfg.update_manifest_url) |old| {
            allocator.free(old);
        }
        cfg.update_manifest_url = try allocator.dupe(u8, url);
    }

    if (options.print_update_url) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{options.config_path});
            return error.InvalidArguments;
        }

        var normalized = try update_checker.sanitizeUrl(allocator, manifest_url);
        defer allocator.free(normalized);
        _ = try update_checker.normalizeUrlForParse(allocator, &normalized);

        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Normalized URL: {s}\n", .{normalized});

        if (!options.check_update_only and !options.save_config) {
            return;
        }
    }

    if (options.save_config and !options.check_update_only) {
        try config.save(allocator, options.config_path, cfg);
        logger.info("Config saved to {s}", .{options.config_path});
        return;
    }

    if (options.check_update_only) {
        const manifest_url = cfg.update_manifest_url orelse "";
        if (manifest_url.len == 0) {
            logger.err("Update manifest URL is empty. Use --update-url or set it in {s}.", .{options.config_path});
            return error.InvalidArguments;
        }

        var info = try update_checker.checkOnce(allocator, manifest_url, build_options.app_version);
        defer info.deinit(allocator);

        var stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("Manifest URL: {s}\n", .{manifest_url});
        try stdout.print("Current version: {s}\n", .{build_options.app_version});
        try stdout.print("Latest version: {s}\n", .{info.version});
        const newer = update_checker.isNewerVersion(info.version, build_options.app_version);
        try stdout.print("Status: {s}\n", .{if (newer) "update available" else "up to date"});
        try stdout.print("Release URL: {s}\n", .{info.release_url orelse "-"});
        try stdout.print("Download URL: {s}\n", .{info.download_url orelse "-"});
        try stdout.print("Download file: {s}\n", .{info.download_file orelse "-"});
        try stdout.print("SHA256: {s}\n", .{info.download_sha256 orelse "-"});

        if (options.save_config) {
            try config.save(allocator, options.config_path, cfg);
            logger.info("Config saved to {s}", .{options.config_path});
        }
    }
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}
