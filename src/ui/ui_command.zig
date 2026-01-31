const std = @import("std");
const workspace = @import("workspace.zig");

pub const UiCommand = union(enum) {
    OpenPanel: OpenPanelCmd,
    UpdatePanel: UpdatePanelCmd,
    FocusPanel: workspace.PanelId,
    ClosePanel: workspace.PanelId,

    pub fn deinit(self: *UiCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .OpenPanel => |*cmd| cmd.deinit(allocator),
            .UpdatePanel => |*cmd| cmd.deinit(allocator),
            .FocusPanel => {},
            .ClosePanel => {},
        }
    }
};

pub const OpenPanelCmd = struct {
    kind: workspace.PanelKind,
    title: ?[]const u8 = null,
    data: ?PanelDataPayload = null,

    pub fn deinit(self: *OpenPanelCmd, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.data) |*data| data.deinit(allocator);
    }
};

pub const UpdatePanelCmd = struct {
    id: workspace.PanelId,
    title: ?[]const u8 = null,
    data: PanelDataPayload,

    pub fn deinit(self: *UpdatePanelCmd, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        self.data.deinit(allocator);
    }
};

pub const PanelDataPayload = union(enum) {
    Chat: ChatPanelPayload,
    CodeEditor: CodeEditorPanelPayload,
    ToolOutput: ToolOutputPanelPayload,
    Control: ControlPanelPayload,

    pub fn deinit(self: *PanelDataPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Chat => |*chat| {
                if (chat.session) |session| allocator.free(session);
            },
            .CodeEditor => |*editor| {
                if (editor.file) |file| allocator.free(file);
                if (editor.language) |lang| allocator.free(lang);
                if (editor.content) |content| allocator.free(content);
            },
            .ToolOutput => |*out| {
                if (out.tool_name) |name| allocator.free(name);
                if (out.stdout) |stdout| allocator.free(stdout);
                if (out.stderr) |stderr| allocator.free(stderr);
            },
            .Control => |*ctrl| {
                if (ctrl.active_tab) |tab| allocator.free(tab);
            },
        }
    }
};

pub const ChatPanelPayload = struct {
    session: ?[]const u8 = null,
};

pub const CodeEditorPanelPayload = struct {
    file: ?[]const u8 = null,
    language: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const ToolOutputPanelPayload = struct {
    tool_name: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    exit_code: ?i32 = null,
};

pub const ControlPanelPayload = struct {
    active_tab: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8) !?UiCommand {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return null;
    if (type_val != .string) return null;

    const type_str = type_val.string;
    if (std.mem.eql(u8, type_str, "OpenPanel")) {
        return parseOpen(allocator, obj);
    }
    if (std.mem.eql(u8, type_str, "UpdatePanel")) {
        return parseUpdate(allocator, obj);
    }
    if (std.mem.eql(u8, type_str, "FocusPanel")) {
        const id = parseId(obj.get("id") orelse return null) orelse return null;
        return UiCommand{ .FocusPanel = id };
    }
    if (std.mem.eql(u8, type_str, "ClosePanel")) {
        const id = parseId(obj.get("id") orelse return null) orelse return null;
        return UiCommand{ .ClosePanel = id };
    }

    return null;
}

fn parseOpen(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?UiCommand {
    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .string) return null;
    const kind = parsePanelKind(kind_val.string) orelse return null;

    const title = parseStringDup(allocator, obj, "title");
    errdefer if (title) |value| allocator.free(value);
    const payload_obj = extractPayloadObject(obj);

    const data = switch (kind) {
        .Chat => blk: {
            const session = parseStringDupFrom(allocator, obj, payload_obj, "session");
            break :blk PanelDataPayload{ .Chat = .{ .session = session } };
        },
        .CodeEditor => blk: {
            const file = parseStringDupFrom(allocator, obj, payload_obj, "file") orelse {
                if (title) |value| allocator.free(value);
                return null;
            };
            const language = parseStringDupFrom(allocator, obj, payload_obj, "language");
            const content = parseStringDupFrom(allocator, obj, payload_obj, "content");
            break :blk PanelDataPayload{ .CodeEditor = .{ .file = file, .language = language, .content = content } };
        },
        .ToolOutput => blk: {
            const tool_name = parseStringDupFrom(allocator, obj, payload_obj, "tool_name") orelse
                parseStringDupFrom(allocator, obj, payload_obj, "tool") orelse {
                    if (title) |value| allocator.free(value);
                    return null;
                };
            const stdout = parseStringDupFrom(allocator, obj, payload_obj, "stdout");
            const stderr = parseStringDupFrom(allocator, obj, payload_obj, "stderr");
            const exit_code = parseIntFrom(obj, payload_obj, "exit_code");
            break :blk PanelDataPayload{ .ToolOutput = .{
                .tool_name = tool_name,
                .stdout = stdout,
                .stderr = stderr,
                .exit_code = exit_code,
            } };
        },
        .Control => blk: {
            const active_tab = parseStringDupFrom(allocator, obj, payload_obj, "active_tab");
            break :blk PanelDataPayload{ .Control = .{ .active_tab = active_tab } };
        },
    };

    return UiCommand{ .OpenPanel = .{ .kind = kind, .title = title, .data = data } };
}

fn parseUpdate(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?UiCommand {
    const id_val = obj.get("id") orelse return null;
    const id = parseId(id_val) orelse return null;
    const title = parseStringDup(allocator, obj, "title");
    errdefer if (title) |value| allocator.free(value);
    const payload_obj = extractPayloadObject(obj);

    const kind_val = obj.get("kind");
    const kind = if (kind_val != null and kind_val.? == .string)
        parsePanelKind(kind_val.?.string)
    else
        null;

    if (kind) |resolved| {
        const data = try parseDataPayloadForKind(allocator, obj, payload_obj, resolved, false);
        return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
    }

    if (payload_obj != null) {
        if (payload_obj.?.get("file") != null or payload_obj.?.get("content") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .CodeEditor, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
        if (payload_obj.?.get("stdout") != null or payload_obj.?.get("stderr") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .ToolOutput, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
        if (payload_obj.?.get("active_tab") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .Control, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
    } else {
        if (obj.get("file") != null or obj.get("content") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .CodeEditor, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
        if (obj.get("stdout") != null or obj.get("stderr") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .ToolOutput, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
        if (obj.get("active_tab") != null) {
            const data = try parseDataPayloadForKind(allocator, obj, payload_obj, .Control, true);
            return UiCommand{ .UpdatePanel = .{ .id = id, .title = title, .data = data } };
        }
    }

    if (title) |value| allocator.free(value);
    return null;
}

fn parseDataPayloadForKind(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    payload_obj: ?std.json.ObjectMap,
    kind: workspace.PanelKind,
    allow_partial: bool,
) !PanelDataPayload {
    switch (kind) {
        .Chat => {
            const session = parseStringDupFrom(allocator, obj, payload_obj, "session");
            if (!allow_partial and session == null) return error.MissingPanelData;
            return .{ .Chat = .{ .session = session } };
        },
        .CodeEditor => {
            const file = parseStringDupFrom(allocator, obj, payload_obj, "file");
            const language = parseStringDupFrom(allocator, obj, payload_obj, "language");
            const content = parseStringDupFrom(allocator, obj, payload_obj, "content");
            if (!allow_partial and file == null) {
                if (language) |lang| allocator.free(lang);
                if (content) |body| allocator.free(body);
                return error.MissingPanelData;
            }
            return .{ .CodeEditor = .{ .file = file, .language = language, .content = content } };
        },
        .ToolOutput => {
            const tool_name = parseStringDupFrom(allocator, obj, payload_obj, "tool_name") orelse
                parseStringDupFrom(allocator, obj, payload_obj, "tool");
            const stdout = parseStringDupFrom(allocator, obj, payload_obj, "stdout");
            const stderr = parseStringDupFrom(allocator, obj, payload_obj, "stderr");
            const exit_code = parseIntFrom(obj, payload_obj, "exit_code");
            if (!allow_partial and tool_name == null) return error.MissingPanelData;
            return .{ .ToolOutput = .{ .tool_name = tool_name, .stdout = stdout, .stderr = stderr, .exit_code = exit_code } };
        },
        .Control => {
            const active_tab = parseStringDupFrom(allocator, obj, payload_obj, "active_tab");
            if (!allow_partial and active_tab == null) return error.MissingPanelData;
            return .{ .Control = .{ .active_tab = active_tab } };
        },
    }
}

fn parsePanelKind(label: []const u8) ?workspace.PanelKind {
    if (std.mem.eql(u8, label, "Chat")) return .Chat;
    if (std.mem.eql(u8, label, "CodeEditor")) return .CodeEditor;
    if (std.mem.eql(u8, label, "ToolOutput")) return .ToolOutput;
    if (std.mem.eql(u8, label, "Control")) return .Control;
    return null;
}

fn parseId(val: std.json.Value) ?workspace.PanelId {
    return switch (val) {
        .integer => |num| @intCast(num),
        .float => |num| @intFromFloat(num),
        else => null,
    };
}

fn extractPayloadObject(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    const data_val = obj.get("data") orelse return null;
    if (data_val != .object) return null;
    return data_val.object;
}

fn parseStringDup(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return allocator.dupe(u8, value.string) catch null;
}

fn parseStringDupFrom(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    payload_obj: ?std.json.ObjectMap,
    key: []const u8,
) ?[]const u8 {
    if (payload_obj) |payload| {
        if (payload.get(key)) |value| {
            if (value == .string) return allocator.dupe(u8, value.string) catch null;
        }
    }
    return parseStringDup(allocator, obj, key);
}

fn parseIntFrom(
    obj: std.json.ObjectMap,
    payload_obj: ?std.json.ObjectMap,
    key: []const u8,
) ?i32 {
    if (payload_obj) |payload| {
        if (payload.get(key)) |value| return parseInt(value);
    }
    if (obj.get(key)) |value| return parseInt(value);
    return null;
}

fn parseInt(value: std.json.Value) ?i32 {
    return switch (value) {
        .integer => |num| @intCast(num),
        .float => |num| @intFromFloat(num),
        else => null,
    };
}
