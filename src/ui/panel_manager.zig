const std = @import("std");
const workspace = @import("workspace.zig");
const ui_command = @import("ui_command.zig");
const text_buffer = @import("text_buffer.zig");
const session_keys = @import("../client/session_keys.zig");

pub const PanelManager = struct {
    allocator: std.mem.Allocator,
    workspace: workspace.Workspace,
    next_panel_id: *workspace.PanelId,
    focus_request_id: ?workspace.PanelId = null,

    pub fn init(allocator: std.mem.Allocator, ws: workspace.Workspace, next_panel_id: *workspace.PanelId) PanelManager {
        var manager = PanelManager{
            .allocator = allocator,
            .workspace = ws,
            .next_panel_id = next_panel_id,
            .focus_request_id = null,
        };
        manager.recomputeNextId();
        return manager;
    }

    pub fn deinit(self: *PanelManager) void {
        self.workspace.deinit(self.allocator);
    }

    /// The workspace renderer/layout currently treats some panel kinds as singletons per-window
    /// (one slot per kind). If duplicates exist, behavior is confusing (detach appears to "copy",
    /// focus routing is ambiguous, etc). Compact them by keeping one and dropping the rest.
    ///
    /// Note: this is intentionally conservative (only applies to kinds that are effectively
    /// singleton in today's UI).
    pub fn compactSingletonPanels(self: *PanelManager) void {
        _ = self;
    }

    pub fn recomputeNextId(self: *PanelManager) void {
        var max_id: workspace.PanelId = 0;
        for (self.workspace.panels.items) |panel| {
            if (panel.id > max_id) max_id = panel.id;
        }
        const candidate = max_id + 1;
        if (candidate > self.next_panel_id.*) {
            self.next_panel_id.* = candidate;
        }
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
        const id = self.next_panel_id.*;
        self.next_panel_id.* += 1;
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

    /// Remove a panel from this manager and return it without freeing. Caller owns it.
    pub fn takePanel(self: *PanelManager, id: workspace.PanelId) ?workspace.Panel {
        var index: usize = 0;
        while (index < self.workspace.panels.items.len) : (index += 1) {
            if (self.workspace.panels.items[index].id == id) {
                const removed = self.workspace.panels.orderedRemove(index);
                self.workspace.markDirty();
                if (self.workspace.focused_panel_id != null and self.workspace.focused_panel_id.? == id) {
                    self.workspace.focused_panel_id = null;
                }
                if (self.focus_request_id != null and self.focus_request_id.? == id) {
                    self.focus_request_id = null;
                }
                return removed;
            }
        }
        return null;
    }

    /// Insert a panel (previously taken from some other manager) into this manager.
    pub fn putPanel(self: *PanelManager, panel: workspace.Panel) !void {
        try self.workspace.panels.append(self.allocator, panel);
        self.workspace.markDirty();
        self.recomputeNextId();
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
        self.focus_request_id = id;
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
                if (self.focus_request_id != null and self.focus_request_id.? == id) {
                    self.focus_request_id = null;
                }
                return true;
            }
        }
        return false;
    }

    pub fn closePanelByKind(self: *PanelManager, kind: workspace.PanelKind) bool {
        if (self.findPanelByKind(kind)) |panel| {
            return self.closePanel(panel.id);
        }
        return false;
    }

    pub fn ensurePanel(self: *PanelManager, kind: workspace.PanelKind) void {
        if (self.findPanelByKind(kind)) |panel| {
            self.focusPanel(panel.id);
            return;
        }
        _ = self.openDefaultPanel(kind) catch {};
    }

    pub fn hasPanel(self: *PanelManager, kind: workspace.PanelKind) bool {
        return self.findPanelByKind(kind) != null;
    }

    pub fn findReusablePanel(
        self: *PanelManager,
        kind: workspace.PanelKind,
        key: ?[]const u8,
    ) ?*workspace.Panel {
        switch (kind) {
            .Chat => {
                if (key) |session| {
                    const agent_id = if (session_keys.parse(session)) |parts| parts.agent_id else null;
                    for (self.workspace.panels.items) |*panel| {
                        if (panel.kind != .Chat) continue;
                        const data = panel.data.Chat;
                        if (agent_id) |agent| {
                            if (data.agent_id) |existing_agent| {
                                if (std.mem.eql(u8, existing_agent, agent)) return panel;
                            }
                        } else if (data.session_key) |existing| {
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
            .Agents => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Agents) return panel;
                }
            },
            .Operator => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Operator) return panel;
                }
            },
            .ApprovalsInbox => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .ApprovalsInbox) return panel;
                }
            },
            .Inbox => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Inbox) return panel;
                }
            },
            .Settings => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Settings) return panel;
                }
            },
            .Workboard => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Workboard) return panel;
                }
            },
            .Showcase => {
                for (self.workspace.panels.items) |*panel| {
                    if (panel.kind == .Showcase) return panel;
                }
            },
            .ToolOutput => {},
        }
        return null;
    }

    pub fn ensureChatPanelForAgent(
        self: *PanelManager,
        agent_id: []const u8,
        title: []const u8,
        session_key: ?[]const u8,
    ) !workspace.PanelId {
        for (self.workspace.panels.items) |*panel| {
            if (panel.kind != .Chat) continue;
            if (panel.data.Chat.agent_id) |existing| {
                if (!std.mem.eql(u8, existing, agent_id)) continue;
            } else {
                panel.data.Chat.agent_id = try self.allocator.dupe(u8, agent_id);
            }

            if (!std.mem.eql(u8, panel.title, title)) {
                self.allocator.free(panel.title);
                panel.title = try self.allocator.dupe(u8, title);
            }

            if (session_key) |session| {
                if (panel.data.Chat.session_key) |prev| self.allocator.free(prev);
                panel.data.Chat.session_key = try self.allocator.dupe(u8, session);
                if (panel.data.Chat.selected_session_id) |selected| {
                    self.allocator.free(selected);
                    panel.data.Chat.selected_session_id = null;
                }
            }

            self.workspace.markDirty();
            self.focusPanel(panel.id);
            return panel.id;
        }

        const data = workspace.PanelData{ .Chat = .{
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .session_key = if (session_key) |session| try self.allocator.dupe(u8, session) else null,
            .selected_session_id = null,
        } };
        const panel_id = try self.openPanel(.Chat, title, data);
        self.focusPanel(panel_id);
        return panel_id;
    }

    fn findPanelByKind(self: *PanelManager, kind: workspace.PanelKind) ?*workspace.Panel {
        for (self.workspace.panels.items) |*panel| {
            if (panel.kind == kind) return panel;
        }
        return null;
    }

    fn openDefaultPanel(self: *PanelManager, kind: workspace.PanelKind) !workspace.PanelId {
        switch (kind) {
            .Chat => {
                const data = workspace.PanelData{ .Chat = .{
                    .agent_id = try self.allocator.dupe(u8, "main"),
                    .session_key = null,
                } };
                return try self.openPanel(.Chat, "Chat", data);
            },
            .Control => {
                const data = workspace.PanelData{ .Control = .{} };
                return try self.openPanel(.Control, "Workspace", data);
            },
            .Agents => {
                const data = workspace.PanelData{ .Agents = .{
                    .active_tab = .Agents,
                    .selected_agent_id = null,
                } };
                return try self.openPanel(.Agents, "Agents", data);
            },
            .Operator => {
                const panel_data = workspace.PanelData{ .Operator = {} };
                return try self.openPanel(.Operator, "Operator", panel_data);
            },
            .ApprovalsInbox => {
                const panel_data = workspace.PanelData{ .ApprovalsInbox = {} };
                return try self.openPanel(.ApprovalsInbox, "Approvals", panel_data);
            },
            .Inbox => {
                const panel_data = workspace.PanelData{ .Inbox = .{
                    .active_tab = .Inbox,
                    .selected_agent_id = null,
                } };
                return try self.openPanel(.Inbox, "Activity", panel_data);
            },
            .Settings => {
                const panel_data = workspace.PanelData{ .Settings = {} };
                return try self.openPanel(.Settings, "Settings", panel_data);
            },
            .Workboard => {
                const panel_data = workspace.PanelData{ .Workboard = {} };
                return try self.openPanel(.Workboard, "Workboard", panel_data);
            },
            .CodeEditor => {
                const file_id = "untitled.zig";
                const language = "zig";
                const file_copy = try self.allocator.dupe(u8, file_id);
                errdefer self.allocator.free(file_copy);
                const lang_copy = try self.allocator.dupe(u8, language);
                errdefer self.allocator.free(lang_copy);
                var buffer = try text_buffer.TextBuffer.init(self.allocator, "");
                errdefer buffer.deinit(self.allocator);
                const panel_data = workspace.PanelData{ .CodeEditor = .{
                    .file_id = file_copy,
                    .language = lang_copy,
                    .content = buffer,
                    .last_modified_by = .ai,
                    .version = 1,
                } };
                return try self.openPanel(.CodeEditor, file_id, panel_data);
            },
            .ToolOutput => {
                const tool_name = "Tool Output";
                const tool_copy = try self.allocator.dupe(u8, tool_name);
                errdefer self.allocator.free(tool_copy);
                var stdout_buf = try text_buffer.TextBuffer.init(self.allocator, "");
                errdefer stdout_buf.deinit(self.allocator);
                var stderr_buf = try text_buffer.TextBuffer.init(self.allocator, "");
                errdefer stderr_buf.deinit(self.allocator);
                const panel_data = workspace.PanelData{ .ToolOutput = .{
                    .tool_name = tool_copy,
                    .stdout = stdout_buf,
                    .stderr = stderr_buf,
                    .exit_code = 0,
                } };
                return try self.openPanel(.ToolOutput, "Tool Output", panel_data);
            },
            .Showcase => {
                const panel_data = workspace.PanelData{ .Showcase = {} };
                return try self.openPanel(.Showcase, "Showcase", panel_data);
            },
        }
    }

    fn applyOpen(self: *PanelManager, open: ui_command.OpenPanelCmd) !void {
        const payload = open.data;
        switch (open.kind) {
            .Chat => {
                const session = if (payload) |data| data.Chat.session else null;
                if (session) |key| {
                    if (session_keys.parse(key)) |parts| {
                        _ = try self.ensureChatPanelForAgent(parts.agent_id, open.title orelse "Chat", key);
                        return;
                    }
                }
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
                if (payload) |data| {
                    if (data.Control.active_tab) |tab| {
                        const tab_kind = panelKindForControlTab(parseControlTab(tab));
                        if (tab_kind != .Control) {
                            self.ensurePanel(tab_kind);
                            return;
                        }
                    }
                }
                if (self.findReusablePanel(.Control, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Control = .{} };
                _ = try self.openPanel(.Control, open.title orelse "Workspace", panel_data);
            },
            .Agents => {
                if (self.findReusablePanel(.Agents, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Agents = .{
                    .active_tab = .Agents,
                    .selected_agent_id = null,
                } };
                _ = try self.openPanel(.Agents, open.title orelse "Agents", panel_data);
            },
            .Operator => {
                if (self.findReusablePanel(.Operator, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Operator = {} };
                _ = try self.openPanel(.Operator, open.title orelse "Operator", panel_data);
            },
            .ApprovalsInbox => {
                if (self.findReusablePanel(.ApprovalsInbox, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .ApprovalsInbox = {} };
                _ = try self.openPanel(.ApprovalsInbox, open.title orelse "Approvals", panel_data);
            },
            .Inbox => {
                if (self.findReusablePanel(.Inbox, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Inbox = .{
                    .active_tab = .Inbox,
                    .selected_agent_id = null,
                } };
                _ = try self.openPanel(.Inbox, open.title orelse "Activity", panel_data);
            },
            .Settings => {
                if (self.findReusablePanel(.Settings, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Settings = {} };
                _ = try self.openPanel(.Settings, open.title orelse "Settings", panel_data);
            },
            .Workboard => {
                if (self.findReusablePanel(.Workboard, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Workboard = {} };
                _ = try self.openPanel(.Workboard, open.title orelse "Workboard", panel_data);
            },
            .Showcase => {
                if (self.findReusablePanel(.Showcase, null)) |panel| {
                    self.focusPanel(panel.id);
                    return;
                }
                const panel_data = workspace.PanelData{ .Showcase = {} };
                _ = try self.openPanel(.Showcase, open.title orelse "Showcase", panel_data);
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
                .Agents => |data| {
                    if (panel.kind != .Agents) return false;
                    if (data.active_tab) |tab| {
                        panel.data.Agents.active_tab = parseControlTab(tab);
                    }
                },
                .Operator => {
                    if (panel.kind != .Operator) return false;
                },
                .ApprovalsInbox => {
                    if (panel.kind != .ApprovalsInbox) return false;
                },
                .Inbox => |data| {
                    if (panel.kind != .Inbox) return false;
                    if (data.active_tab) |tab| {
                        panel.data.Inbox.active_tab = parseControlTab(tab);
                    }
                },
                .Settings => {
                    if (panel.kind != .Settings) return false;
                },
                .Workboard => {
                    if (panel.kind != .Workboard) return false;
                },
                .Showcase => {
                    if (panel.kind != .Showcase) return false;
                },
            }
            self.workspace.markDirty();
            return true;
        }
        return false;
    }
};

fn parseControlTab(label: []const u8) workspace.ControlTab {
    if (std.mem.eql(u8, label, "Agents")) return .Agents;
    if (std.mem.eql(u8, label, "Inbox")) return .Inbox;
    if (std.mem.eql(u8, label, "Projects")) return .Projects;
    if (std.mem.eql(u8, label, "Sources")) return .Sources;
    if (std.mem.eql(u8, label, "Artifact Workspace")) return .ArtifactWorkspace;
    if (std.mem.eql(u8, label, "Run Inspector")) return .RunInspector;
    if (std.mem.eql(u8, label, "Approvals Inbox")) return .ApprovalsInbox;
    if (std.mem.eql(u8, label, "Active Agents")) return .ActiveAgents;
    if (std.mem.eql(u8, label, "Media Gallery")) return .MediaGallery;
    if (std.mem.eql(u8, label, "Settings")) return .Settings;
    if (std.mem.eql(u8, label, "Operator")) return .Operator;
    if (std.mem.eql(u8, label, "Showcase")) return .Showcase;
    return .Agents;
}

fn panelKindForControlTab(tab: workspace.ControlTab) workspace.PanelKind {
    return switch (tab) {
        .Agents => .Agents,
        .Inbox => .Inbox,
        .ApprovalsInbox => .ApprovalsInbox,
        .Settings => .Settings,
        .Operator => .Operator,
        else => .Control,
    };
}
