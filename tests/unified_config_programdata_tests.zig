const std = @import("std");
const builtin = @import("builtin");

const zsc = @import("ziggystarclaw");
const unified_config = zsc.unified_config;

const c = @cImport({
    @cInclude("stdlib.h");
});

test "unified_config expands %ProgramData%" {
    // Use libc setenv for portability across Zig stdlib versions.
    if (builtin.os.tag == .windows) return;

    // Set a deterministic ProgramData root.
    _ = c.setenv("ProgramData", "/tmp/ZSCProgramData", 1);
    _ = c.setenv("PROGRAMDATA", "/tmp/ZSCProgramData", 1);

    const cfg_path = "test_programdata_config.json";
    defer std.fs.cwd().deleteFile(cfg_path) catch {};

    const json =
        \\{
        \\  "gateway": { "wsUrl": "ws://example/ws", "authToken": "tok" },
        \\  "node": {
        \\    "enabled": true,
        \\    "nodeToken": "",
        \\    "nodeId": "node-123",
        \\    "displayName": "test",
        \\    "healthReporterIntervalMs": 10000,
        \\    "deviceIdentityPath": "%ProgramData%\\ZiggyStarClaw\\node-device.json",
        \\    "execApprovalsPath": "%ProgramData%\\ZiggyStarClaw\\exec-approvals.json"
        \\  },
        \\  "operator": { "enabled": false },
        \\  "logging": { "level": "info", "file": "%PROGRAMDATA%\\ZiggyStarClaw\\logs\\node.log" }
        \\}
    ;

    {
        const f = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(json);
        try f.writeAll("\n");
    }

    var cfg = try unified_config.load(std.testing.allocator, cfg_path);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, cfg.node.deviceIdentityPath, "/tmp/ZSCProgramData") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg.node.execApprovalsPath, "/tmp/ZSCProgramData") != null);
    try std.testing.expect(cfg.logging.file != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg.logging.file.?, "/tmp/ZSCProgramData") != null);
}
