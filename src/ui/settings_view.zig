const zgui = @import("zgui");

pub fn draw() void {
    if (zgui.beginChild("Settings", .{ .h = 120.0, .child_flags = .{ .border = true } })) {
        zgui.text("Settings (stub)", .{});
        zgui.textDisabled("Server URL and token UI will live here.", .{});
    }
    zgui.endChild();
}
