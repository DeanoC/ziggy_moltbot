const std = @import("std");
const moltbot = @import("moltbot");

// UI tests are compile-only for now; rendering requires an active backend.

test "ui modules compile" {
    _ = moltbot.ui.chat_view;
    _ = moltbot.ui.input_panel;
    _ = moltbot.ui.main_window;
    _ = moltbot.ui.status_bar;
    _ = moltbot.ui.settings_view;
    try std.testing.expect(true);
}
