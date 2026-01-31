const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("../workspace.zig");

pub fn draw(panel: *workspace.Panel, allocator: std.mem.Allocator) void {
    if (panel.kind != .ToolOutput) return;
    _ = allocator;
    const output = &panel.data.ToolOutput;

    zgui.text("Tool:", .{});
    zgui.sameLine(.{});
    zgui.text("{s}", .{output.tool_name});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textDisabled("exit {d}", .{output.exit_code});
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
