const std = @import("std");
const moltbot = @import("ziggystarclaw");

// UI tests are compile-only for now; rendering requires an active backend.

test "ui modules compile" {
    _ = moltbot.ui.chat_view;
    _ = moltbot.ui.input_panel;
    _ = moltbot.ui.main_window;
    _ = moltbot.ui.status_bar;
    _ = moltbot.ui.settings_view;
    _ = moltbot.ui.workspace;
    _ = moltbot.ui.panel_manager;
    _ = moltbot.ui.ui_command;
    _ = moltbot.ui.ui_command_inbox;
    try std.testing.expect(true);
}

test "workspace snapshot roundtrip" {
    const allocator = std.testing.allocator;
    var ws = try moltbot.ui.workspace.Workspace.initDefault(allocator);
    defer ws.deinit(allocator);

    var snapshot = try ws.toSnapshot(allocator);
    defer snapshot.deinit(allocator);

    var ws2 = try moltbot.ui.workspace.Workspace.fromSnapshot(allocator, snapshot);
    defer ws2.deinit(allocator);

    try std.testing.expectEqual(ws.panels.items.len, ws2.panels.items.len);
    try std.testing.expectEqual(ws.panels.items[0].kind, ws2.panels.items[0].kind);
}

test "ui command parse open code editor" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"OpenPanel\",\"kind\":\"CodeEditor\",\"file\":\"ui.zig\",\"language\":\"zig\",\"content\":\"hello\"}";
    const cmd = try moltbot.ui.ui_command.parse(allocator, json) orelse return error.TestExpectedCommand;
    var owned = cmd;
    defer owned.deinit(allocator);

    switch (owned) {
        .OpenPanel => |open| {
            try std.testing.expectEqual(moltbot.ui.workspace.PanelKind.CodeEditor, open.kind);
        },
        else => return error.TestExpectedCommand,
    }
}

test "panel manager reuses code editor" {
    const allocator = std.testing.allocator;
    var ws = try moltbot.ui.workspace.Workspace.initDefault(allocator);
    var manager = moltbot.ui.panel_manager.PanelManager.init(allocator, ws);
    defer manager.deinit();

    const json = "{\"type\":\"OpenPanel\",\"kind\":\"CodeEditor\",\"file\":\"main.zig\",\"language\":\"zig\",\"content\":\"updated\"}";
    const cmd = try moltbot.ui.ui_command.parse(allocator, json) orelse return error.TestExpectedCommand;
    var owned = cmd;
    defer owned.deinit(allocator);
    try manager.applyUiCommand(owned);

    var found: usize = 0;
    for (manager.workspace.panels.items) |panel| {
        if (panel.kind == .CodeEditor and std.mem.eql(u8, panel.data.CodeEditor.file_id, "main.zig")) {
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}
