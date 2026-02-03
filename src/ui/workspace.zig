const std = @import("std");
const text_buffer = @import("text_buffer.zig");

pub const PanelId = u64;
pub const DockNodeId = u32;
pub const ProjectId = u64;

pub const PanelKind = enum {
    Chat,
    CodeEditor,
    ToolOutput,
    Control,
};

pub const PanelState = struct {
    dock_node: DockNodeId = 0,
    is_focused: bool = false,
    is_dirty: bool = false,
};

pub const EditorOwner = enum { user, ai };

pub const ChatPanel = struct {
    agent_id: ?[]const u8 = null,
    session_key: ?[]const u8 = null,
};

pub const CodeEditorPanel = struct {
    file_id: []const u8,
    language: []const u8,
    content: text_buffer.TextBuffer,
    last_modified_by: EditorOwner = .ai,
    version: u32 = 1,
};

pub const ToolOutputPanel = struct {
    tool_name: []const u8,
    stdout: text_buffer.TextBuffer,
    stderr: text_buffer.TextBuffer,
    exit_code: i32 = 0,
};

pub const ControlPanel = struct {
    active_tab: ControlTab = .Agents,
    selected_agent_id: ?[]const u8 = null,
};

pub const ControlTab = enum {
    Agents,
    Notifications,
    Settings,
    Operator,
};

pub const PanelData = union(enum) {
    Chat: ChatPanel,
    CodeEditor: CodeEditorPanel,
    ToolOutput: ToolOutputPanel,
    Control: ControlPanel,

    pub fn deinit(self: *PanelData, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Chat => |*chat| {
                if (chat.agent_id) |id| allocator.free(id);
                if (chat.session_key) |key| allocator.free(key);
            },
            .CodeEditor => |*editor| {
                allocator.free(editor.file_id);
                allocator.free(editor.language);
                editor.content.deinit(allocator);
            },
            .ToolOutput => |*out| {
                allocator.free(out.tool_name);
                out.stdout.deinit(allocator);
                out.stderr.deinit(allocator);
            },
            .Control => |*ctrl| {
                if (ctrl.selected_agent_id) |id| allocator.free(id);
            },
        }
    }
};

pub const Panel = struct {
    id: PanelId,
    kind: PanelKind,
    title: []const u8,
    data: PanelData,
    state: PanelState,

    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        self.data.deinit(allocator);
    }
};

pub const DockLayout = struct {
    imgui_ini: []u8,
};

pub const Workspace = struct {
    panels: std.ArrayList(Panel),
    layout: DockLayout,
    focused_panel_id: ?PanelId,
    active_project: ProjectId,
    dirty: bool = false,

    pub fn initEmpty(allocator: std.mem.Allocator) Workspace {
        return .{
            .panels = std.ArrayList(Panel).empty,
            .layout = .{ .imgui_ini = allocator.dupe(u8, "") catch unreachable },
            .focused_panel_id = null,
            .active_project = 0,
            .dirty = false,
        };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Workspace {
        var ws = Workspace.initEmpty(allocator);
        try ws.panels.ensureTotalCapacity(allocator, 4);

        try ws.panels.append(allocator, try makeControlPanel(allocator, 1));
        try ws.panels.append(allocator, try makeCodeEditorPanel(allocator, 2, "main.zig", "zig", ""));
        try ws.panels.append(allocator, try makeChatPanel(allocator, 3, "main", null));
        try ws.panels.append(allocator, try makeToolOutputPanel(allocator, 4, "Tool Output", "", "", 0));

        ws.focused_panel_id = ws.panels.items[2].id;
        return ws;
    }

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        for (self.panels.items) |*panel| {
            panel.deinit(allocator);
        }
        self.panels.deinit(allocator);
        allocator.free(self.layout.imgui_ini);
    }

    pub fn markDirty(self: *Workspace) void {
        self.dirty = true;
    }

    pub fn markClean(self: *Workspace) void {
        self.dirty = false;
    }

    pub fn toSnapshot(self: *const Workspace, allocator: std.mem.Allocator) !WorkspaceSnapshot {
        var panels = try allocator.alloc(PanelSnapshot, self.panels.items.len);
        var filled: usize = 0;
        errdefer {
            for (panels[0..filled]) |panel| {
                freePanelSnapshot(allocator, panel);
            }
            allocator.free(panels);
        }
        for (self.panels.items, 0..) |panel, idx| {
            panels[idx] = try panelToSnapshot(allocator, panel);
            filled = idx + 1;
        }
        const layout_copy = try allocator.dupe(u8, self.layout.imgui_ini);
        return .{
            .active_project = self.active_project,
            .focused_panel_id = self.focused_panel_id,
            .layout_ini = layout_copy,
            .panels = panels,
        };
    }

    pub fn fromSnapshot(allocator: std.mem.Allocator, snapshot: WorkspaceSnapshot) !Workspace {
        var ws = Workspace.initEmpty(allocator);
        ws.active_project = snapshot.active_project;
        ws.focused_panel_id = snapshot.focused_panel_id;

        if (snapshot.layout_ini) |ini| {
            allocator.free(ws.layout.imgui_ini);
            ws.layout.imgui_ini = try allocator.dupe(u8, ini);
        }

        if (snapshot.panels) |panel_snaps| {
            try ws.panels.ensureTotalCapacity(allocator, panel_snaps.len);
            for (panel_snaps) |snap| {
                try ws.panels.append(allocator, try panelFromSnapshot(allocator, snap));
            }
        }
        return ws;
    }
};

pub const PanelStateSnapshot = struct {
    dock_node: DockNodeId = 0,
    is_focused: bool = false,
    is_dirty: bool = false,
};

pub const ChatPanelSnapshot = struct {
    session: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const CodeEditorPanelSnapshot = struct {
    file_id: []const u8,
    language: []const u8,
    content: []const u8,
    last_modified_by: []const u8 = "ai",
    version: u32 = 1,
};

pub const ToolOutputPanelSnapshot = struct {
    tool_name: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32 = 0,
};

pub const ControlPanelSnapshot = struct {
    active_tab: []const u8 = "Agents",
    selected_agent_id: ?[]const u8 = null,
};

pub const PanelSnapshot = struct {
    id: PanelId,
    kind: PanelKind,
    title: []const u8,
    state: PanelStateSnapshot = .{},
    chat: ?ChatPanelSnapshot = null,
    code_editor: ?CodeEditorPanelSnapshot = null,
    tool_output: ?ToolOutputPanelSnapshot = null,
    control: ?ControlPanelSnapshot = null,
};

pub const WorkspaceSnapshot = struct {
    active_project: ProjectId = 0,
    focused_panel_id: ?PanelId = null,
    layout_ini: ?[]const u8 = null,
    panels: ?[]PanelSnapshot = null,

    pub fn deinit(self: *WorkspaceSnapshot, allocator: std.mem.Allocator) void {
        if (self.layout_ini) |ini| allocator.free(ini);
        if (self.panels) |panels| {
            for (panels) |panel| {
                freePanelSnapshot(allocator, panel);
            }
            allocator.free(panels);
        }
    }
};

fn panelToSnapshot(allocator: std.mem.Allocator, panel: Panel) !PanelSnapshot {
    const title_copy = try allocator.dupe(u8, panel.title);
    var snap = PanelSnapshot{
        .id = panel.id,
        .kind = panel.kind,
        .title = title_copy,
        .state = .{
            .dock_node = panel.state.dock_node,
            .is_focused = panel.state.is_focused,
            .is_dirty = panel.state.is_dirty,
        },
    };
    errdefer freePanelSnapshot(allocator, snap);

    switch (panel.data) {
        .Chat => |chat| {
            snap.chat = .{
                .session = if (chat.session_key) |key| try allocator.dupe(u8, key) else null,
                .agent_id = if (chat.agent_id) |id| try allocator.dupe(u8, id) else null,
            };
        },
        .CodeEditor => |editor| {
            snap.code_editor = .{
                .file_id = try allocator.dupe(u8, editor.file_id),
                .language = try allocator.dupe(u8, editor.language),
                .content = try allocator.dupe(u8, editor.content.slice()),
                .last_modified_by = if (editor.last_modified_by == .user)
                    try allocator.dupe(u8, "user")
                else
                    try allocator.dupe(u8, "ai"),
                .version = editor.version,
            };
        },
        .ToolOutput => |out| {
            snap.tool_output = .{
                .tool_name = try allocator.dupe(u8, out.tool_name),
                .stdout = try allocator.dupe(u8, out.stdout.slice()),
                .stderr = try allocator.dupe(u8, out.stderr.slice()),
                .exit_code = out.exit_code,
            };
        },
        .Control => |ctrl| {
            snap.control = .{
                .active_tab = try allocator.dupe(u8, switch (ctrl.active_tab) {
                    .Agents => "Agents",
                    .Notifications => "Notifications",
                    .Settings => "Settings",
                    .Operator => "Operator",
                }),
                .selected_agent_id = if (ctrl.selected_agent_id) |id| try allocator.dupe(u8, id) else null,
            };
        },
    }

    return snap;
}

fn panelFromSnapshot(allocator: std.mem.Allocator, snap: PanelSnapshot) !Panel {
    const title_copy = try allocator.dupe(u8, snap.title);
    errdefer allocator.free(title_copy);
    const state_val = PanelState{
        .dock_node = snap.state.dock_node,
        .is_focused = snap.state.is_focused,
        .is_dirty = snap.state.is_dirty,
    };

    switch (snap.kind) {
        .Chat => {
            const session_copy = if (snap.chat) |chat|
                if (chat.session) |session| try allocator.dupe(u8, session) else null
            else
                null;
            const agent_copy = if (snap.chat) |chat|
                if (chat.agent_id) |agent| try allocator.dupe(u8, agent) else null
            else
                null;
            return .{
                .id = snap.id,
                .kind = .Chat,
                .title = title_copy,
                .data = .{ .Chat = .{ .agent_id = agent_copy, .session_key = session_copy } },
                .state = state_val,
            };
        },
        .CodeEditor => {
            const ce = snap.code_editor orelse return error.MissingPanelData;
            const file_id = try allocator.dupe(u8, ce.file_id);
            const language = try allocator.dupe(u8, ce.language);
            const content = try text_buffer.TextBuffer.init(allocator, ce.content);
            const modified_by: EditorOwner = if (std.mem.eql(u8, ce.last_modified_by, "user"))
                .user
            else
                .ai;
            return .{
                .id = snap.id,
                .kind = .CodeEditor,
                .title = title_copy,
                .data = .{ .CodeEditor = .{
                    .file_id = file_id,
                    .language = language,
                    .content = content,
                    .last_modified_by = modified_by,
                    .version = ce.version,
                } },
                .state = state_val,
            };
        },
        .ToolOutput => {
            const to = snap.tool_output orelse return error.MissingPanelData;
            const tool_name = try allocator.dupe(u8, to.tool_name);
            const stdout = try text_buffer.TextBuffer.init(allocator, to.stdout);
            const stderr = try text_buffer.TextBuffer.init(allocator, to.stderr);
            return .{
                .id = snap.id,
                .kind = .ToolOutput,
                .title = title_copy,
                .data = .{ .ToolOutput = .{
                    .tool_name = tool_name,
                    .stdout = stdout,
                    .stderr = stderr,
                    .exit_code = to.exit_code,
                } },
                .state = state_val,
            };
        },
        .Control => {
            const ctrl_snap = snap.control orelse ControlPanelSnapshot{};
            const active_tab = parseControlTab(ctrl_snap.active_tab);
            return .{
                .id = snap.id,
                .kind = .Control,
                .title = title_copy,
                .data = .{ .Control = .{
                    .active_tab = active_tab,
                    .selected_agent_id = if (ctrl_snap.selected_agent_id) |id| try allocator.dupe(u8, id) else null,
                } },
                .state = state_val,
            };
        },
    }
}

fn parseControlTab(label: []const u8) ControlTab {
    if (std.mem.eql(u8, label, "Settings")) return .Settings;
    if (std.mem.eql(u8, label, "Operator")) return .Operator;
    if (std.mem.eql(u8, label, "Notifications")) return .Notifications;
    return .Agents;
}

fn freePanelSnapshot(allocator: std.mem.Allocator, panel: PanelSnapshot) void {
    allocator.free(panel.title);
    if (panel.chat) |chat| {
        if (chat.session) |session| allocator.free(session);
        if (chat.agent_id) |agent| allocator.free(agent);
    }
    if (panel.code_editor) |editor| {
        allocator.free(editor.file_id);
        allocator.free(editor.language);
        allocator.free(editor.content);
        allocator.free(editor.last_modified_by);
    }
    if (panel.tool_output) |out| {
        allocator.free(out.tool_name);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }
    if (panel.control) |ctrl| {
        allocator.free(ctrl.active_tab);
        if (ctrl.selected_agent_id) |id| allocator.free(id);
    }
}

pub fn makeChatPanel(
    allocator: std.mem.Allocator,
    id: PanelId,
    agent_id: ?[]const u8,
    session_key: ?[]const u8,
) !Panel {
    const title = try allocator.dupe(u8, "Chat");
    const agent_copy = if (agent_id) |id_value| try allocator.dupe(u8, id_value) else null;
    const session_copy = if (session_key) |key| try allocator.dupe(u8, key) else null;
    return .{
        .id = id,
        .kind = .Chat,
        .title = title,
        .data = .{ .Chat = .{ .agent_id = agent_copy, .session_key = session_copy } },
        .state = .{},
    };
}

pub fn makeCodeEditorPanel(
    allocator: std.mem.Allocator,
    id: PanelId,
    file_id: []const u8,
    language: []const u8,
    content: []const u8,
) !Panel {
    const title = try allocator.dupe(u8, file_id);
    const file_copy = try allocator.dupe(u8, file_id);
    const lang_copy = try allocator.dupe(u8, language);
    const buffer = try text_buffer.TextBuffer.init(allocator, content);
    return .{
        .id = id,
        .kind = .CodeEditor,
        .title = title,
        .data = .{ .CodeEditor = .{
            .file_id = file_copy,
            .language = lang_copy,
            .content = buffer,
            .last_modified_by = .ai,
            .version = 1,
        } },
        .state = .{},
    };
}

pub fn makeToolOutputPanel(
    allocator: std.mem.Allocator,
    id: PanelId,
    tool_name: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
) !Panel {
    const title = try allocator.dupe(u8, "Tool Output");
    const tool_copy = try allocator.dupe(u8, tool_name);
    const stdout_buf = try text_buffer.TextBuffer.init(allocator, stdout);
    const stderr_buf = try text_buffer.TextBuffer.init(allocator, stderr);
    return .{
        .id = id,
        .kind = .ToolOutput,
        .title = title,
        .data = .{ .ToolOutput = .{
            .tool_name = tool_copy,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .exit_code = exit_code,
        } },
        .state = .{},
    };
}

pub fn makeControlPanel(allocator: std.mem.Allocator, id: PanelId) !Panel {
    const title = try allocator.dupe(u8, "Control");
    return .{
        .id = id,
        .kind = .Control,
        .title = title,
        .data = .{ .Control = .{} },
        .state = .{},
    };
}
