const std = @import("std");
const workspace = @import("workspace.zig");
const ui_command = @import("ui_command.zig");
const text_buffer = @import("text_buffer.zig");

pub const PanelManager = struct {
    allocator: std.mem.Allocator,
    workspace: workspace.Workspace,
    next_panel_id: workspace.PanelId,

    pub fn init(allocator: std.mem.Allocator, ws: workspace.Workspace) PanelManager {
        var manager = PanelManager{
            .allocator = allocator,
            .workspace = ws,
            .next_panel_id = 1,
        };
        manager.recomputeNextId();
        return manager;
    }

    pub fn deinit(self: *PanelManager) void {
        self.workspace.deinit(self.allocator);
    }

    pub fn recomputeNextId(self: *PanelManager) void {
        var max_id: workspace.PanelId = 0;
        for (self.workspace.panels.items) |panel| {
            if (panel.id > max_id) max_id = panel.id;
        }
        self.next_panel_id = max_id + 1;
    }

    pub fn applyUiCommand(self: *PanelManager, cmd: ui_command.UiCommand) !void {
        switch (cmd) {
            .OpenPanel => |open| try self.applyOpen(open),
            .UpdatePanel => |update| _ = try self.applyUpdate(update),
            .FocusPanel => |panel_id| self.focusPanel(panel_id),
            .ClosePanel => |panel_id| _ = self.closePanel(panel_id),
        }
    }

    pub fn openPanel(
        self: *PanelManager,
        kind: workspace.PanelKind,
        title: []const u8,
        data: workspace.PanelData,
    ) !workspace.PanelId {
        const id = self.next_panel_id;
        self.next_panel_id += 1;
        const title_copy = try self.allocator.dupe(u8, title);
        try self.workspace.panels.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .title = title_copy,
            .data = data,
            .state = .{},
        });
        self.workspace.markDirty();
        return id;
    }

    pub fn updatePanel(
        self: *PanelManager,
        id: workspace.PanelId,
        data: workspace.PanelData,
        title: ?[]const u8,
    ) bool {
        for (self.workspace.panels.items) |*panel| {
            if (panel.id == id) {
                if (title) |new_title| {
                    self.allocator.free(panel.title);
                    panel.title = self.allocator.dupe(u8, new_title) catch panel.title;
                }
                panel.data.deinit(self.allocator);
                panel.data = data;
                self.workspace.markDirty();
                return true;
            }
        }
        data.deinit(self.allocator);
        return false;
    }

    pub fn focusPanel(self: *PanelManager, id: workspace.PanelId) void {
        self.workspace.focused_panel_id = id;
        self.workspace.markDirty();
    }

    pub fn closePanel(self: *PanelManager, id: workspace.PanelId) bool {
        var index: usize = 0;
        while (index < self.workspace.panels.items.len) : (index += 1) {
            if (self.workspace.panels.items[index].id == id) {
                var removed = self.workspace.panels.orderedRemove(index);
                removed.deinit(self.allocator);
                self.workspace.markDirty();
                if (self.workspace.focused_panel_id != null and self.workspace.focused_panel_id.? == id) {
                    self.workspace.focused_panel_id = null;
                }
                return true;
            }
        }
        return false;
    }

    pub fn findReusablePanel(
        self: *PanelManager,
        kind: workspace.PanelKind,
        key: ?[]const u8,
    ) ?*workspace.Panel {
        switch (kind) {
            .Chat => {
                if (key) |session| {
                    for (self.workspace.panels.items) |*panel| {
                        if (panel.kind != .Chat) continue;
                        const data = panel.data.Chat;
                        if (data.session_key) |existing| {
                            if (std.mem.eql(u8, existing, session)) return panel;
                        }
                    }
                }
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Chat) return panel;
                }
            },
            .CodeEditor => {
                if (key) |file_id| {
                    for (self.workspace.panels.items) |*panel| {
                        if (panel.kind != .CodeEditor) continue;
                        if (std.mem.eql(u8, panel.data.CodeEditor.file_id, file_id)) return panel;
                    }
                }
            },
            .Control => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Control) return panel;
                }
            },
            .ToolOutput => {},
        }
        return null;
    }

    fn applyOpen(self: *PanelManager, open: ui_command.OpenPanelCmd) !void {
        const payload = open.data;
        switch (open.kind) {
            .Chat => {
                const session = if (payload) |data| data.Chat.session else null;
                if (self.findReusablePanel(.Chat, session)) |panel| {
                    if (session) |key| {
                        if (panel.data.Chat.session_key) |prev| self.allocator.free(prev);
                        panel.data.Chat.session_key = try self.allocator.dupe(u8, key);
                    }
                    self.focusPanel(panel.id);
                    return;
                }
                const session_copy = if (session) |key| try self.allocator.dupe(u8, key) else null;
                const data = workspace.PanelData{ .Chat = .{ .session_key = session_copy } };
                _ = try self.openPanel(.Chat, open.title orelse "Chat", data);
            },
            .CodeEditor => {
                if (payload == null) return;
                const data = payload.?.CodeEditor;
                const file_id = data.file orelse return;

                if (self.findReusablePanel(.CodeEditor, file_id)) |panel| {
                    if (data.content) |content| {
                        try panel.data.CodeEditor.content.set(self.allocator, content);
                        panel.data.CodeEditor.last_modified_by = .ai;
                        panel.data.CodeEditor.version += 1;
                        panel.state.is_dirty = false;
                    }
                    if (data.language) |language| {
                        self.allocator.free(panel.data.CodeEditor.language);
                        panel.data.CodeEditor.language = try self.allocator.dupe(u8, language);
                    }
                    self.focusPanel(panel.id);
                    return;
                }

                const language = data.language orelse "text";
                const content = data.content orelse "";
                const file_copy = try self.allocator.dupe(u8, file_id);
                const lang_copy = try self.allocator.dupe(u8, language);
                const buffer = try text_buffer.TextBuffer.init(self.allocator, content);
                const panel_data = workspace.PanelData{ .CodeEditor = .{
                    .file_id = file_copy,
                    .language = lang_copy,
                    .content = buffer,
                    .last_modified_by = .ai,
                    .version = 1,
                } };
                _ = try self.openPanel(.CodeEditor, open.title orelse file_id, panel_data);
            },
            .ToolOutput => {
                if (payload == null) return;
                const data = payload.?.ToolOutput;
                const tool_name = data.tool_name orelse return;
                const stdout = data.stdout orelse "";
                const stderr = data.stderr orelse "";
                const exit_code = data.exit_code orelse 0;
                const tool_copy = try self.allocator.dupe(u8, tool_name);
                const stdout_buf = try text_buffer.TextBuffer.init(self.allocator, stdout);
                const stderr_buf = try text_buffer.TextBuffer.init(self.allocator, stderr);
                const panel_data = workspace.PanelData{ .ToolOutput = .{
                    .tool_name = tool_copy,
                    .stdout = stdout_buf,
                    .stderr = stderr_buf,
                    .exit_code = exit_code,
                } };
                _ = try self.openPanel(.ToolOutput, open.title orelse "Tool Output", panel_data);
            },
            .Control => {
                if (self.findReusablePanel(.Control, null)) |panel| {
                    if (payload) |data| {
                        if (data.Control.active_tab) |tab| {
                            panel.data.Control.active_tab = parseControlTab(tab);
                        }
                    }
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Control = .{} };
                _ = try self.openPanel(.Control, open.title orelse "Control", panel_data);
            },
        }
    }

    fn applyUpdate(self: *PanelManager, update: ui_command.UpdatePanelCmd) !bool {
        for (self.workspace.panels.items) |*panel| {
            if (panel.id != update.id) continue;
            if (update.title) |title| {
                self.allocator.free(panel.title);
                panel.title = try self.allocator.dupe(u8, title);
            }
            switch (update.data) {
                .Chat => |data| {
                    if (panel.kind != .Chat) return false;
                    if (data.session) |session| {
                        if (panel.data.Chat.session_key) |prev| self.allocator.free(prev);
                        panel.data.Chat.session_key = try self.allocator.dupe(u8, session);
                    }
                },
                .CodeEditor => |data| {
                    if (panel.kind != .CodeEditor) return false;
                    if (data.file) |file| {
                        self.allocator.free(panel.data.CodeEditor.file_id);
                        panel.data.CodeEditor.file_id = try self.allocator.dupe(u8, file);
                    }
                    if (data.language) |language| {
                        self.allocator.free(panel.data.CodeEditor.language);
                        panel.data.CodeEditor.language = try self.allocator.dupe(u8, language);
                    }
                    if (data.content) |content| {
                        try panel.data.CodeEditor.content.set(self.allocator, content);
                        panel.data.CodeEditor.last_modified_by = .ai;
                        panel.data.CodeEditor.version += 1;
                        panel.state.is_dirty = false;
                    }
                },
                .ToolOutput => |data| {
                    if (panel.kind != .ToolOutput) return false;
                    if (data.tool_name) |name| {
                        self.allocator.free(panel.data.ToolOutput.tool_name);
                        panel.data.ToolOutput.tool_name = try self.allocator.dupe(u8, name);
                    }
                    if (data.stdout) |stdout| {
                        try panel.data.ToolOutput.stdout.set(self.allocator, stdout);
                    }
                    if (data.stderr) |stderr| {
                        try panel.data.ToolOutput.stderr.set(self.allocator, stderr);
                    }
                    if (data.exit_code) |code| {
                        panel.data.ToolOutput.exit_code = code;
                    }
                },
                .Control => |data| {
                    if (panel.kind != .Control) return false;
                    if (data.active_tab) |tab| {
                        panel.data.Control.active_tab = parseControlTab(tab);
                    }
                },
            }
            self.workspace.markDirty();
            return true;
        }
        return false;
    }
};

fn parseControlTab(label: []const u8) workspace.ControlTab {
    if (std.mem.eql(u8, label, "Settings")) return .Settings;
    if (std.mem.eql(u8, label, "Operator")) return .Operator;
    return .Sessions;
}
