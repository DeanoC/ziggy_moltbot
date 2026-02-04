const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("../workspace.zig");
const components = @import("../components/components.zig");

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator) void {
    if (panel.kind != .ToolOutput) return;
    _ = allocator;
    const output = &panel.data.ToolOutput;

    var subtitle_buf: [32]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buf, "exit {d}", .{output.exit_code}) catch "exit ?";
    _ = components.layout.header_bar.begin(.{
        .title = output.tool_name,
        .subtitle = subtitle,
    });
    components.layout.header_bar.end();
    zgui.separator();

    zgui.textDisabled("stdout", .{});
    _ = zgui.inputTextMultiline("##tool_stdout", .{
        .buf = output.stdout.asZ(),
        .h = 140.0,
        .flags = .{ .read_only = true },
    });
    zgui.separator();
    zgui.textDisabled("stderr", .{});
    _ = zgui.inputTextMultiline("##tool_stderr", .{
        .buf = output.stderr.asZ(),
        .h = 140.0,
        .flags = .{ .read_only = true },
    });
}
