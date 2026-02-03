const std = @import("std");
const zgui = @import("zgui");
const state = @import("../../client/state.zig");
const agent_registry = @import("../../client/agent_registry.zig");
const session_keys = @import("../../client/session_keys.zig");
const types = @import("../../protocol/types.zig");
const workspace = @import("../workspace.zig");

pub const AgentSessionAction = struct {
    agent_id: []u8,
    session_key: []u8,
};

pub const AddAgentAction = struct {
    id: []u8,
    display_name: []u8,
    icon: []u8,
};

pub const AgentsPanelAction = struct {
    refresh: bool = false,
    new_chat_agent_id: ?[]u8 = null,
    open_session: ?AgentSessionAction = null,
    set_default: ?AgentSessionAction = null,
    delete_session: ?[]u8 = null,
    add_agent: ?AddAgentAction = null,
    remove_agent_id: ?[]u8 = null,
};

var add_id_buf: [64:0]u8 = [_:0]u8{0} ** 64;
var add_name_buf: [128:0]u8 = [_:0]u8{0} ** 128;
var add_icon_buf: [16:0]u8 = [_:0]u8{0} ** 16;
var add_initialized = false;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
) AgentsPanelAction {
    var action = AgentsPanelAction{};

    if (!add_initialized) {
        fillBuffer(add_icon_buf[0..], "A");
        add_initialized = true;
    }

    ensureSelection(allocator, registry, panel);

    zgui.text("Agents", .{});
    if (zgui.button("Refresh Sessions", .{})) {
        action.refresh = true;
    }

    zgui.separator();

    const avail = zgui.getContentRegionAvail();
    const list_width: f32 = @min(240.0, @max(160.0, avail[0] * 0.35));

    if (zgui.beginChild("AgentsList", .{ .w = list_width, .child_flags = .{ .border = true } })) {
        if (registry.agents.items.len == 0) {
            zgui.textDisabled("No agents configured.", .{});
        }
        for (registry.agents.items, 0..) |agent, index| {
            zgui.pushIntId(@intCast(index));
            defer zgui.popId();
            const label = zgui.formatZ("{s} {s}", .{ agent.icon, agent.display_name });
            const selected = if (panel.selected_agent_id) |sel|
                std.mem.eql(u8, sel, agent.id)
            else
                false;
            if (zgui.selectable(label, .{ .selected = selected })) {
                setSelectedAgent(allocator, panel, agent.id);
            }
        }
        zgui.separator();
        drawAddAgent(allocator, registry, panel, &action);
    }
    zgui.endChild();

    zgui.sameLine(.{ .spacing = 12.0 });

    if (zgui.beginChild("AgentDetails", .{ .w = 0.0, .child_flags = .{ .border = true } })) {
        if (panel.selected_agent_id) |selected_id| {
            if (registry.find(selected_id)) |agent| {
                drawAgentDetails(allocator, agent, &action, panel);
                zgui.separator();
                drawAgentSessions(allocator, ctx, agent, &action);
            } else {
                zgui.textDisabled("Select an agent to view details.", .{});
            }
        } else {
            zgui.textDisabled("Select an agent to view details.", .{});
        }
    }
    zgui.endChild();

    return action;
}

fn ensureSelection(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
) void {
    if (registry.agents.items.len == 0) {
        clearSelectedAgent(allocator, panel);
        return;
    }
    if (panel.selected_agent_id) |selected| {
        if (registry.find(selected) != null) return;
        clearSelectedAgent(allocator, panel);
    }
    const fallback = registry.agents.items[0].id;
    setSelectedAgent(allocator, panel, fallback);
}

fn setSelectedAgent(allocator: std.mem.Allocator, panel: *workspace.ControlPanel, id: []const u8) void {
    if (panel.selected_agent_id) |selected| {
        if (std.mem.eql(u8, selected, id)) return;
        allocator.free(selected);
    }
    panel.selected_agent_id = allocator.dupe(u8, id) catch panel.selected_agent_id;
}

fn clearSelectedAgent(allocator: std.mem.Allocator, panel: *workspace.ControlPanel) void {
    if (panel.selected_agent_id) |selected| {
        allocator.free(selected);
    }
    panel.selected_agent_id = null;
}

fn drawAddAgent(
    allocator: std.mem.Allocator,
    registry: *agent_registry.AgentRegistry,
    panel: *workspace.ControlPanel,
    action: *AgentsPanelAction,
) void {
    zgui.text("Add Agent", .{});
    _ = zgui.inputText("Id", .{ .buf = add_id_buf[0.. :0] });
    _ = zgui.inputText("Name", .{ .buf = add_name_buf[0.. :0] });
    _ = zgui.inputText("Icon", .{ .buf = add_icon_buf[0.. :0] });

    const id = std.mem.sliceTo(&add_id_buf, 0);
    const name = std.mem.sliceTo(&add_name_buf, 0);
    const icon = std.mem.sliceTo(&add_icon_buf, 0);
    const valid_id = session_keys.isAgentIdValid(id);
    const exists = registry.find(id) != null;
    const can_add = valid_id and !exists;

    zgui.beginDisabled(.{ .disabled = !can_add });
    if (zgui.button("Add", .{})) {
        const display = if (name.len > 0) name else id;
        const icon_text = if (icon.len > 0) icon else "?";
        const id_copy = allocator.dupe(u8, id) catch return;
        errdefer allocator.free(id_copy);
        const name_copy = allocator.dupe(u8, display) catch {
            allocator.free(id_copy);
            return;
        };
        errdefer allocator.free(name_copy);
        const icon_copy = allocator.dupe(u8, icon_text) catch {
            allocator.free(id_copy);
            allocator.free(name_copy);
            return;
        };
        action.add_agent = .{
            .id = id_copy,
            .display_name = name_copy,
            .icon = icon_copy,
        };
        setSelectedAgent(allocator, panel, id);
        fillBuffer(add_id_buf[0..], "");
        fillBuffer(add_name_buf[0..], "");
        fillBuffer(add_icon_buf[0..], "A");
    }
    zgui.endDisabled();

    if (!valid_id and id.len > 0) {
        zgui.textDisabled("Use letters, numbers, _ or -.", .{});
    } else if (exists) {
        zgui.textDisabled("Agent id already exists.", .{});
    }
}

fn drawAgentDetails(
    allocator: std.mem.Allocator,
    agent: *agent_registry.AgentProfile,
    action: *AgentsPanelAction,
    panel: *workspace.ControlPanel,
) void {
    zgui.text("{s} {s}", .{ agent.icon, agent.display_name });
    zgui.textDisabled("Id: {s}", .{agent.id});

    zgui.separator();
    zgui.text("Soul", .{});
    zgui.textDisabled("{s}", .{agent.soul_path orelse "(not set)"});
    zgui.text("Config", .{});
    zgui.textDisabled("{s}", .{agent.config_path orelse "(not set)"});
    zgui.text("Personality", .{});
    zgui.textDisabled("{s}", .{agent.personality_path orelse "(not set)"});

    zgui.separator();
    if (zgui.button("New Chat", .{})) {
        action.new_chat_agent_id = allocator.dupe(u8, agent.id) catch null;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    const is_main = std.mem.eql(u8, agent.id, "main");
    zgui.beginDisabled(.{ .disabled = is_main });
    if (zgui.button("Remove Agent", .{})) {
        action.remove_agent_id = allocator.dupe(u8, agent.id) catch null;
        clearSelectedAgent(allocator, panel);
    }
    zgui.endDisabled();
    if (is_main) {
        zgui.sameLine(.{ .spacing = 6.0 });
        zgui.textDisabled("Main agent cannot be removed.", .{});
    }
}

fn drawAgentSessions(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    agent: *agent_registry.AgentProfile,
    action: *AgentsPanelAction,
) void {
    zgui.text("Chats", .{});
    if (ctx.sessions.items.len == 0) {
        zgui.textDisabled("No sessions loaded.", .{});
        return;
    }

    var session_indices = std.ArrayList(usize).empty;
    defer session_indices.deinit(allocator);

    for (ctx.sessions.items, 0..) |session, index| {
        if (isNotificationSession(session)) continue;
        if (session_keys.parse(session.key)) |parts| {
            if (!std.mem.eql(u8, parts.agent_id, agent.id)) continue;
        } else {
            if (!std.mem.eql(u8, agent.id, "main")) continue;
        }
        session_indices.append(allocator, index) catch {};
    }

    if (session_indices.items.len == 0) {
        zgui.textDisabled("No chats for this agent.", .{});
        return;
    }

    std.sort.heap(usize, session_indices.items, ctx.sessions.items, sessionUpdatedDesc);

    const now_ms = std.time.milliTimestamp();
    for (session_indices.items) |idx| {
        const session = ctx.sessions.items[idx];
        zgui.pushIntId(@intCast(idx));
        defer zgui.popId();

        const legacy = session_keys.parse(session.key) == null;
        const base_label = session.display_name orelse session.label orelse session.key;
        const label = if (legacy)
            zgui.formatZ("[legacy] {s}", .{base_label})
        else
            zgui.formatZ("{s}", .{base_label});
        zgui.text("{s}", .{label});
        zgui.sameLine(.{ .spacing = 12.0 });
        renderRelativeTime(now_ms, session.updated_at);

        zgui.sameLine(.{ .spacing = 12.0 });
        if (zgui.button("Open", .{})) {
            const agent_copy = allocator.dupe(u8, agent.id) catch return;
            errdefer allocator.free(agent_copy);
            const session_copy = allocator.dupe(u8, session.key) catch {
                allocator.free(agent_copy);
                return;
            };
            action.open_session = .{
                .agent_id = agent_copy,
                .session_key = session_copy,
            };
        }

        const is_default = agent.default_session_key != null and
            std.mem.eql(u8, agent.default_session_key.?, session.key);
        zgui.sameLine(.{ .spacing = 6.0 });
        zgui.beginDisabled(.{ .disabled = is_default });
        if (zgui.button("Make Default", .{})) {
            const agent_copy = allocator.dupe(u8, agent.id) catch return;
            errdefer allocator.free(agent_copy);
            const session_copy = allocator.dupe(u8, session.key) catch {
                allocator.free(agent_copy);
                return;
            };
            action.set_default = .{
                .agent_id = agent_copy,
                .session_key = session_copy,
            };
        }
        zgui.endDisabled();

        zgui.sameLine(.{ .spacing = 6.0 });
        if (zgui.button("Delete", .{})) {
            action.delete_session = allocator.dupe(u8, session.key) catch return;
        }

        if (is_default) {
            zgui.sameLine(.{ .spacing = 6.0 });
            zgui.textDisabled("Default", .{});
        }

        zgui.textDisabled("{s}", .{session.key});
        zgui.separator();
    }
}

fn sessionUpdatedDesc(sessions: []const types.Session, a: usize, b: usize) bool {
    const updated_a = sessions[a].updated_at orelse 0;
    const updated_b = sessions[b].updated_at orelse 0;
    return updated_a > updated_b;
}

fn renderRelativeTime(now_ms: i64, updated_at: ?i64) void {
    const ts = updated_at orelse 0;
    if (ts <= 0) {
        zgui.textDisabled("never", .{});
        return;
    }
    const delta_ms = if (now_ms > ts) now_ms - ts else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;

    if (seconds < 60) {
        zgui.textDisabled("{d}s ago", .{seconds});
        return;
    }
    if (minutes < 60) {
        zgui.textDisabled("{d}m ago", .{minutes});
        return;
    }
    if (hours < 24) {
        zgui.textDisabled("{d}h ago", .{hours});
        return;
    }
    zgui.textDisabled("{d}d ago", .{days});
}

fn isNotificationSession(session: types.Session) bool {
    const kind = session.kind orelse return false;
    return std.ascii.eqlIgnoreCase(kind, "cron") or std.ascii.eqlIgnoreCase(kind, "heartbeat");
}

fn fillBuffer(buf: []u8, value: []const u8) void {
    const len = @min(buf.len, value.len + 1);
    if (len > 0) {
        @memcpy(buf[0 .. len - 1], value[0 .. len - 1]);
        buf[len - 1] = 0;
    }
    if (len < buf.len) {
        @memset(buf[len..], 0);
    }
}
