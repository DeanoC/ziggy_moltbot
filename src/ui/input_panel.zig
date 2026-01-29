const zgui = @import("zgui");

var input_buf: [512:0]u8 = [_:0]u8{0} ** 512;

pub fn draw() bool {
    var send = false;

    _ = zgui.inputTextMultiline("##message_input", .{
        .buf = input_buf[0.. :0],
        .h = 80.0,
        .flags = .{ .allow_tab_input = true },
    });

    if (zgui.button("Send", .{})) {
        send = true;
        input_buf[0] = 0;
    }

    return send;
}
