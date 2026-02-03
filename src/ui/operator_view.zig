const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

pub const NodeInvokeAction = struct {
    node_id: []u8,
    command: []u8,
    params_json: ?[]u8 = null,
    timeout_ms: ?u32 = null,

    pub fn deinit(self: *const NodeInvokeAction, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.command);
        if (self.params_json) |params| {
            allocator.free(params);
        }
    }
};

pub const ExecApprovalResolveAction = struct {
    request_id: []u8,
    decision: ExecApprovalDecision,

    pub fn deinit(self: *const ExecApprovalResolveAction, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
    }
};

pub const ExecApprovalDecision = enum {
    allow_once,
    allow_always,
    deny,
};

pub const OperatorAction = struct {
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
};

var node_id_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var command_buf: [256:0]u8 = [_:0]u8{0} ** 256;
var params_buf: [1024:0]u8 = [_:0]u8{0} ** 1024;
var timeout_buf: [64:0]u8 = [_:0]u8{0} ** 64;
var initialized = false;
var sidebar_collapsed = false;

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    is_connected: bool,
) OperatorAction {
    var action = OperatorAction{};

    if (!initialized) {
        fillBuffer(timeout_buf[0..], "30000");
        initialized = true;
    }

    if (zgui.beginChild("Operator", .{ .h = 0.0, .child_flags = .{ .border = true } })) {
        const spacing = theme.activeTheme().spacing.md;
        theme.push(.heading);
        zgui.text("Operator", .{});
        theme.pop();
        zgui.separator();

        const avail = zgui.getContentRegionAvail();
        const sidebar_width = @min(280.0, avail[0] * 0.35);

        if (components.layout.sidebar.begin(.{
            .id = "operator",
            .width = sidebar_width,
            .collapsible = true,
            .collapsed = &sidebar_collapsed,
        })) {
            if (!sidebar_collapsed) {
                zgui.text("Nodes", .{});
                zgui.beginDisabled(.{ .disabled = !is_connected or ctx.nodes_loading });
                if (components.core.button.draw("Refresh Nodes", .{ .variant = .secondary, .size = .small })) {
                    action.refresh_nodes = true;
                }
                zgui.sameLine(.{ .spacing = spacing });
                if (components.core.button.draw("Describe Selected", .{ .variant = .secondary, .size = .small })) {
                    if (ctx.current_node) |node_id| {
                        action.describe_node = allocator.dupe(u8, node_id) catch null;
                    }
                }
                zgui.endDisabled();
                if (!is_connected) {
                    zgui.textWrapped("Connect to load nodes.", .{});
                } else if (ctx.nodes_loading) {
                    zgui.textWrapped("Loading nodes...", .{});
                }

                const list_height: f32 = 180.0;
                if (components.layout.scroll_area.begin(.{ .id = "NodesList", .height = list_height, .border = true })) {
                    if (ctx.nodes.items.len == 0) {
                        zgui.textWrapped("No nodes available.", .{});
                    } else {
                        for (ctx.nodes.items, 0..) |node, index| {
                            zgui.pushIntId(@intCast(index));
                            defer zgui.popId();
                            const selected = ctx.current_node != null and std.mem.eql(u8, ctx.current_node.?, node.id);
                            const connected_label = statusLabel(node.connected);
                            const paired_label = statusLabel(node.paired);
                            const name = node.display_name orelse node.id;
                            var label_buf: [256]u8 = undefined;
                            const label = std.fmt.bufPrint(
                                &label_buf,
                                "{s} ({s}, {s})",
                                .{ name, connected_label, paired_label },
                            ) catch name;
                            if (components.data.list_item.draw(.{
                                .label = label,
                                .selected = selected,
                                .id = node.id,
                            })) {
                                action.select_node = allocator.dupe(u8, node.id) catch null;
                            }
                        }
                    }
                }
                components.layout.scroll_area.end();

                zgui.separator();
                zgui.text("Execution Approvals", .{});
                if (!is_connected) {
                    zgui.textWrapped("Connect to receive approval requests.", .{});
                } else if (ctx.approvals.items.len == 0) {
                    zgui.textWrapped("No pending approvals.", .{});
                } else {
                    if (components.layout.scroll_area.begin(.{ .id = "ApprovalsList", .height = 160.0, .border = true })) {
                        for (ctx.approvals.items, 0..) |approval, index| {
                            zgui.pushIntId(@intCast(index));
                            defer zgui.popId();
                            const decision = components.data.approval_card.draw(.{
                                .id = approval.id,
                                .summary = approval.summary,
                                .requested_at_ms = approval.requested_at_ms,
                                .payload_json = approval.payload_json,
                                .can_resolve = approval.can_resolve,
                            });
                            const id_copy = switch (decision) {
                                .none => null,
                                else => allocator.dupe(u8, approval.id) catch null,
                            };
                            if (id_copy) |value| {
                                action.resolve_approval = ExecApprovalResolveAction{
                                    .request_id = value,
                                    .decision = switch (decision) {
                                        .allow_once => .allow_once,
                                        .allow_always => .allow_always,
                                        .deny => .deny,
                                        .none => unreachable,
                                    },
                                };
                            }
                        }
                    }
                    components.layout.scroll_area.end();
                }
            }
        }
        components.layout.sidebar.end();

        zgui.sameLine(.{ .spacing = spacing });
        if (components.layout.scroll_area.begin(.{ .id = "OperatorMain", .border = false })) {
            drawSelectedNode(allocator, ctx, &action);

            zgui.separator();
            zgui.text("Invoke Node Command", .{});
            _ = zgui.inputText("Node ID", .{ .buf = node_id_buf[0.. :0] });
            zgui.sameLine(.{});
            if (components.core.button.draw("Use Selected", .{ .variant = .secondary, .size = .small })) {
                if (ctx.current_node) |node_id| {
                    fillBuffer(node_id_buf[0..], node_id);
                }
            }
            zgui.sameLine(.{ .spacing = spacing });
            if (components.core.button.draw("Describe", .{ .variant = .secondary, .size = .small })) {
                const node_text = std.mem.sliceTo(&node_id_buf, 0);
                if (node_text.len > 0) {
                    action.describe_node = allocator.dupe(u8, node_text) catch null;
                }
            }
            _ = zgui.inputText("Command", .{ .buf = command_buf[0.. :0] });
            _ = zgui.inputText("Timeout (ms)", .{ .buf = timeout_buf[0.. :0] });
            _ = zgui.inputTextMultiline("Params (JSON)", .{
                .buf = params_buf[0.. :0],
                .h = 80.0,
                .flags = .{ .allow_tab_input = true },
            });

            zgui.beginDisabled(.{ .disabled = !is_connected });
            if (components.core.button.draw("Invoke", .{ .variant = .primary })) {
                const node_text = std.mem.sliceTo(&node_id_buf, 0);
                const command_text = std.mem.sliceTo(&command_buf, 0);
                const params_text = std.mem.sliceTo(&params_buf, 0);
                var node_copy = allocator.dupe(u8, node_text) catch null;
                if (node_copy) |node_id| {
                    const command_copy = allocator.dupe(u8, command_text) catch {
                        allocator.free(node_id);
                        node_copy = null;
                        return action;
                    };
                    var params_copy: ?[]u8 = null;
                    if (params_text.len > 0) {
                        params_copy = allocator.dupe(u8, params_text) catch {
                            allocator.free(command_copy);
                            allocator.free(node_id);
                            return action;
                        };
                    }
                    action.invoke_node = NodeInvokeAction{
                        .node_id = node_id,
                        .command = command_copy,
                        .params_json = params_copy,
                        .timeout_ms = parseTimeout(std.mem.sliceTo(&timeout_buf, 0)),
                    };
                }
            }
            zgui.endDisabled();

            if (ctx.operator_notice) |notice| {
                zgui.separator();
                zgui.textColored(.{ 0.9, 0.6, 0.2, 1.0 }, "Notice", .{});
                zgui.textWrapped("{s}", .{notice});
                if (components.core.button.draw("Clear Notice", .{ .variant = .ghost })) {
                    action.clear_operator_notice = true;
                }
            }

            if (ctx.node_result) |result| {
                zgui.separator();
                zgui.text("Last Operator Response", .{});
                if (components.layout.scroll_area.begin(.{ .id = "NodeResult", .height = 140.0, .border = true })) {
                    zgui.textWrapped("{s}", .{result});
                }
                components.layout.scroll_area.end();
                if (components.core.button.draw("Clear Response", .{ .variant = .secondary })) {
                    action.clear_node_result = true;
                }
            }
        }
        components.layout.scroll_area.end();
    }
    zgui.endChild();

    return action;
}

fn statusLabel(value: ?bool) []const u8 {
    if (value) |flag| return if (flag) "online" else "offline";
    return "unknown";
}

fn drawSelectedNode(allocator: std.mem.Allocator, ctx: *state.ClientContext, action: *OperatorAction) void {
    zgui.separator();
    zgui.text("Selected Node", .{});
    if (ctx.current_node == null) {
        zgui.textWrapped("No node selected.", .{});
        return;
    }

    const node_id = ctx.current_node.?;
    const node = findNode(ctx.nodes.items, node_id) orelse {
        zgui.textWrapped("Selected node not found.", .{});
        return;
    };

    const label = node.display_name orelse node.id;
    const subtitle: ?[]const u8 = if (node.display_name != null) node.id else null;
    components.data.agent_status.draw(.{
        .label = label,
        .subtitle = subtitle,
        .connected = node.connected,
        .paired = node.paired,
        .platform = node.platform,
    });
    if (node.version) |version| {
        zgui.textWrapped("Version: {s}", .{version});
    }
    if (node.core_version) |core| {
        zgui.textWrapped("Core Version: {s}", .{core});
    }
    if (node.ui_version) |ui| {
        zgui.textWrapped("UI Version: {s}", .{ui});
    }
    if (node.connected_at_ms) |ts| {
        zgui.textWrapped("Connected At (ms): {d}", .{ts});
    }
    if (node.permissions_json) |perm| {
        zgui.text("Permissions", .{});
        if (zgui.beginChild("NodePermissions", .{ .h = 80.0, .child_flags = .{ .border = true } })) {
            zgui.textWrapped("{s}", .{perm});
        }
        zgui.endChild();
    }

    zgui.text("Capabilities", .{});
    if (node.caps) |caps| {
        if (caps.len == 0) {
            zgui.textWrapped("none", .{});
        } else {
            for (caps) |cap| {
                zgui.bulletText("{s}", .{cap});
            }
        }
    } else {
        zgui.textWrapped("none", .{});
    }

    zgui.text("Commands", .{});
    if (node.commands) |commands| {
        if (commands.len == 0) {
            zgui.textWrapped("none", .{});
        } else {
            for (commands) |command| {
                zgui.bulletText("{s}", .{command});
            }
        }
    } else {
        zgui.textWrapped("none", .{});
    }

    zgui.separator();
    zgui.text("Describe Response", .{});
    if (findNodeDescribe(ctx.node_describes.items, node.id)) |describe| {
        if (zgui.beginChild("NodeDescribe", .{ .h = 120.0, .child_flags = .{ .border = true } })) {
            zgui.textWrapped("{s}", .{describe.payload_json});
        }
        zgui.endChild();
        if (zgui.button("Clear Describe", .{})) {
            action.clear_node_describe = allocator.dupe(u8, node.id) catch null;
        }
    } else {
        zgui.textWrapped("No describe response yet.", .{});
    }
}

fn findNode(nodes: []const types.Node, node_id: []const u8) ?types.Node {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.id, node_id)) return node;
    }
    return null;
}

fn findNodeDescribe(describes: []const state.NodeDescribe, node_id: []const u8) ?state.NodeDescribe {
    for (describes) |describe| {
        if (std.mem.eql(u8, describe.node_id, node_id)) return describe;
    }
    return null;
}

fn parseTimeout(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn fillBuffer(buf: []u8, value: []const u8) void {
    if (buf.len == 0) return;
    @memset(buf, 0);
    const len = @min(value.len, buf.len - 1);
    @memcpy(buf[0..len], value[0..len]);
    buf[len] = 0;
}
