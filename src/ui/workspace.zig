const std = @import("std");
const text_buffer = @import("text_buffer.zig");
const chat_view = @import("chat_view.zig");
const text_editor = @import("widgets/text_editor.zig");

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

pub const CustomLayoutState = struct {
    left_ratio: f32 = 0.42,
    min_left_width: f32 = 360.0,
    min_right_width: f32 = 320.0,
};

pub const EditorOwner = enum { user, ai };

pub const ChatPanel = struct {
    agent_id: ?[]const u8 = null,
    session_key: ?[]const u8 = null,
    view: chat_view.ViewState = .{},
};

pub const CodeEditorPanel = struct {
    file_id: []const u8,
    language: []const u8,
    content: text_buffer.TextBuffer,
    last_modified_by: EditorOwner = .ai,
    version: u32 = 1,
    editor: ?text_editor.TextEditor = null,
    editor_hash: u64 = 0,
};

pub const ToolOutputPanel = struct {
    tool_name: []const u8,
    stdout: text_buffer.TextBuffer,
    stderr: text_buffer.TextBuffer,
    exit_code: i32 = 0,
    stdout_editor: ?text_editor.TextEditor = null,
    stderr_editor: ?text_editor.TextEditor = null,
    stdout_hash: u64 = 0,
    stderr_hash: u64 = 0,
};

pub const ControlPanel = struct {
    active_tab: ControlTab = .Agents,
    selected_agent_id: ?[]const u8 = null,
};

pub const ControlTab = enum {
    Agents,
    Inbox,
    Projects,
    Sources,
    ArtifactWorkspace,
    RunInspector,
    ApprovalsInbox,
    ActiveAgents,
    MediaGallery,
    Sessions,
    Settings,
    Operator,
    Showcase,
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
                chat_view.deinit(&chat.view, allocator);
            },
            .CodeEditor => |*editor| {
                allocator.free(editor.file_id);
                allocator.free(editor.language);
                editor.content.deinit(allocator);
                if (editor.editor) |*text_editor_state| {
                    text_editor_state.deinit(allocator);
                }
                editor.editor = null;
            },
            .ToolOutput => |*out| {
                allocator.free(out.tool_name);
                out.stdout.deinit(allocator);
                out.stderr.deinit(allocator);
                if (out.stdout_editor) |*editor| {
                    editor.deinit(allocator);
                }
                if (out.stderr_editor) |*editor| {
                    editor.deinit(allocator);
                }
                out.stdout_editor = null;
                out.stderr_editor = null;
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

pub const Workspace = struct {
    panels: std.ArrayList(Panel),
    custom_layout: CustomLayoutState,
    focused_panel_id: ?PanelId,
    active_project: ProjectId,
    dirty: bool = false,

    pub fn initEmpty(allocator: std.mem.Allocator) Workspace {
        _ = allocator;
        return .{
            .panels = std.ArrayList(Panel).empty,
            .custom_layout = .{},
            .focused_panel_id = null,
            .active_project = 0,
            .dirty = false,
        };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Workspace {
        var ws = Workspace.initEmpty(allocator);
        try ws.panels.ensureTotalCapacity(allocator, 2);

        try ws.panels.append(allocator, try makeControlPanel(allocator, 1));
        try ws.panels.append(allocator, try makeChatPanel(allocator, 2, "main", null));

        ws.focused_panel_id = ws.panels.items[1].id;
        return ws;
    }

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        for (self.panels.items) |*panel| {
            panel.deinit(allocator);
        }
        self.panels.deinit(allocator);
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
        return .{
            .active_project = self.active_project,
            .focused_panel_id = self.focused_panel_id,
            .custom_layout = .{
                .left_ratio = self.custom_layout.left_ratio,
                .min_left_width = self.custom_layout.min_left_width,
                .min_right_width = self.custom_layout.min_right_width,
            },
            .panels = panels,
        };
    }

    pub fn fromSnapshot(allocator: std.mem.Allocator, snapshot: WorkspaceSnapshot) !Workspace {
        var ws = Workspace.initEmpty(allocator);
        ws.active_project = snapshot.active_project;
        ws.focused_panel_id = snapshot.focused_panel_id;

        if (snapshot.custom_layout) |layout| {
            ws.custom_layout = .{
                .left_ratio = layout.left_ratio,
                .min_left_width = layout.min_left_width,
                .min_right_width = layout.min_right_width,
            };
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
    agent_id: ?[]const u8 = null,
    session: ?[]const u8 = null,
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

pub const CustomLayoutSnapshot = struct {
    left_ratio: f32 = 0.42,
    min_left_width: f32 = 360.0,
    min_right_width: f32 = 320.0,
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
    custom_layout: ?CustomLayoutSnapshot = null,
    panels: ?[]PanelSnapshot = null,

    pub fn deinit(self: *WorkspaceSnapshot, allocator: std.mem.Allocator) void {
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
                .agent_id = if (chat.agent_id) |id| try allocator.dupe(u8, id) else null,
                .session = if (chat.session_key) |key| try allocator.dupe(u8, key) else null,
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
                    .Inbox => "Inbox",
                    .Projects => "Projects",
                    .Sources => "Sources",
                    .ArtifactWorkspace => "Artifact Workspace",
                    .RunInspector => "Run Inspector",
                    .ApprovalsInbox => "Approvals Inbox",
                    .ActiveAgents => "Active Agents",
                    .MediaGallery => "Media Gallery",
                    .Sessions => "Sessions",
                    .Settings => "Settings",
                    .Operator => "Operator",
                    .Showcase => "Showcase",
                }),
                .selected_agent_id = if (ctrl.selected_agent_id) |id| try allocator.dupe(u8, id) else null,
            };
        },
    }

    return snap;
}

fn panelFromSnapshot(allocator: std.mem.Allocator, snap: PanelSnapshot) !Panel {
    const resolved_title = if (snap.kind == .Control and std.mem.eql(u8, snap.title, "Control"))
        "Workspace"
    else
        snap.title;
    const title_copy = try allocator.dupe(u8, resolved_title);
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
    if (std.mem.eql(u8, label, "Agents")) return .Agents;
    if (std.mem.eql(u8, label, "Inbox")) return .Inbox;
    if (std.mem.eql(u8, label, "Projects")) return .Projects;
    if (std.mem.eql(u8, label, "Sources")) return .Sources;
    if (std.mem.eql(u8, label, "Artifact Workspace")) return .ArtifactWorkspace;
    if (std.mem.eql(u8, label, "Run Inspector")) return .RunInspector;
    if (std.mem.eql(u8, label, "Approvals Inbox")) return .ApprovalsInbox;
    if (std.mem.eql(u8, label, "Active Agents")) return .ActiveAgents;
    if (std.mem.eql(u8, label, "Media Gallery")) return .MediaGallery;
    if (std.mem.eql(u8, label, "Sessions")) return .Sessions;
    if (std.mem.eql(u8, label, "Settings")) return .Settings;
    if (std.mem.eql(u8, label, "Operator")) return .Operator;
    if (std.mem.eql(u8, label, "Showcase")) return .Showcase;
    return .Agents;
}

fn freePanelSnapshot(allocator: std.mem.Allocator, panel: PanelSnapshot) void {
    allocator.free(panel.title);
    if (panel.chat) |chat| {
        if (chat.agent_id) |agent| allocator.free(agent);
        if (chat.session) |session| allocator.free(session);
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
    const agent_copy = if (agent_id) |agent| try allocator.dupe(u8, agent) else null;
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
    const title = try allocator.dupe(u8, "Workspace");
    return .{
        .id = id,
        .kind = .Control,
        .title = title,
        .data = .{ .Control = .{} },
        .state = .{},
    };
}
