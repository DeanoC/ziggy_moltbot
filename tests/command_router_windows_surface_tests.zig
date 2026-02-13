const std = @import("std");
const builtin = @import("builtin");
const zsc = @import("ziggystarclaw");

const command_router = zsc.node.command_router;
const node_context = zsc.node.node_context;

fn expectCommandRegistration(cmd: node_context.Command, should_register: bool) !void {
    const requested = [_]node_context.Command{cmd};

    if (should_register) {
        var router = try command_router.initRouterWithCommands(std.testing.allocator, &requested);
        defer router.deinit();
        try std.testing.expect(router.isRegistered(cmd.toString()));
    } else {
        try std.testing.expectError(
            error.CommandNotSupported,
            command_router.initRouterWithCommands(std.testing.allocator, &requested),
        );
    }
}

test "command router: windows media command registration follows backend support" {
    const camera_support = zsc.windows.camera.detectBackendSupport(std.testing.allocator);
    const screen_support = zsc.windows.screen.detectBackendSupport(std.testing.allocator);

    const should_register_camera_list = builtin.target.os.tag == .windows and camera_support.list;
    const should_register_camera_snap = builtin.target.os.tag == .windows and camera_support.snap;
    const should_register_camera_clip = builtin.target.os.tag == .windows and camera_support.clip;
    const should_register_screen_record = builtin.target.os.tag == .windows and screen_support.record;

    try expectCommandRegistration(.camera_list, should_register_camera_list);
    try expectCommandRegistration(.camera_snap, should_register_camera_snap);
    try expectCommandRegistration(.camera_clip, should_register_camera_clip);
    try expectCommandRegistration(.screen_record, should_register_screen_record);
}
