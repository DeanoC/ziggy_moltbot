const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");

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
        zgui.text("Operator", .{});
        zgui.separator();

        zgui.text("Nodes", .{});
        zgui.beginDisabled(.{ .disabled = !is_connected or ctx.nodes_loading });
        if (zgui.button("Refresh Nodes", .{})) {
            action.refresh_nodes = true;
        }
        zgui.sameLine(.{});
        if (zgui.button("Describe Selected", .{})) {
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

        const list_height: f32 = 150.0;
        if (zgui.beginChild("NodesList", .{ .h = list_height, .child_flags = .{ .border = true } })) {
            if (ctx.nodes.items.len == 0) {
                zgui.textWrapped("No nodes available.", .{});
            } else {
                for (ctx.nodes.items, 0..) |node, index| {
                    zgui.pushIntId(@intCast(index));
                    defer zgui.popId();
                    const selected = ctx.current_node != null and std.mem.eql(u8, ctx.current_node.?, node.id);
                    const connected_label = statusLabel(node.connected);
                    const paired_label = statusLabel(node.paired);
                    const title = if (node.display_name) |name|
                        zgui.formatZ("{s} ({s}, {s})", .{ name, connected_label, paired_label })
                    else
                        zgui.formatZ("{s} ({s}, {s})", .{ node.id, connected_label, paired_label });
                    if (zgui.selectable(title, .{ .selected = selected })) {
                        action.select_node = allocator.dupe(u8, node.id) catch null;
                    }
                }
            }
        }
        zgui.endChild();

        drawSelectedNode(allocator, ctx, &action);

        zgui.separator();
        zgui.text("Execution Approvals", .{});
        if (!is_connected) {
            zgui.textWrapped("Connect to receive approval requests.", .{});
        } else if (ctx.approvals.items.len == 0) {
            zgui.textWrapped("No pending approvals.", .{});
        } else {
            if (zgui.beginChild("ApprovalsList", .{ .h = 140.0, .child_flags = .{ .border = true } })) {
                for (ctx.approvals.items, 0..) |approval, index| {
                    zgui.pushIntId(@intCast(index));
                    defer zgui.popId();
                    zgui.textWrapped("Request: {s}", .{approval.id});
                    if (approval.summary) |summary| {
                        zgui.textWrapped("Summary: {s}", .{summary});
                    }
                    if (approval.requested_at_ms) |ts| {
                        zgui.textWrapped("Requested At: {d}", .{ts});
                    }
                    if (approval.can_resolve) {
                        if (zgui.button("Allow Once", .{})) {
                            const id_copy = allocator.dupe(u8, approval.id) catch null;
                            if (id_copy) |value| {
                                action.resolve_approval = ExecApprovalResolveAction{
                                    .request_id = value,
                                    .decision = .allow_once,
                                };
                            }
                        }
                        zgui.sameLine(.{});
                        if (zgui.button("Allow Always", .{})) {
                            const id_copy = allocator.dupe(u8, approval.id) catch null;
                            if (id_copy) |value| {
                                action.resolve_approval = ExecApprovalResolveAction{
                                    .request_id = value,
                                    .decision = .allow_always,
                                };
                            }
                        }
                        zgui.sameLine(.{});
                        if (zgui.button("Deny", .{})) {
                            const id_copy = allocator.dupe(u8, approval.id) catch null;
                            if (id_copy) |value| {
                                action.resolve_approval = ExecApprovalResolveAction{
                                    .request_id = value,
                                    .decision = .deny,
                                };
                            }
                        }
                    } else {
                        zgui.textWrapped("Missing approval id in payload.", .{});
                    }
                    zgui.textWrapped("{s}", .{approval.payload_json});
                    zgui.separator();
                }
            }
            zgui.endChild();
        }

        zgui.separator();
        zgui.text("Invoke Node Command", .{});
        _ = zgui.inputText("Node ID", .{ .buf = node_id_buf[0.. :0] });
        zgui.sameLine(.{});
        if (zgui.button("Use Selected", .{})) {
            if (ctx.current_node) |node_id| {
                fillBuffer(node_id_buf[0..], node_id);
            }
        }
        zgui.sameLine(.{});
        if (zgui.button("Describe", .{})) {
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
        if (zgui.button("Invoke", .{})) {
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
            if (zgui.button("Clear Notice", .{})) {
                action.clear_operator_notice = true;
            }
        }

        if (ctx.node_result) |result| {
            zgui.separator();
            zgui.text("Last Operator Response", .{});
            if (zgui.beginChild("NodeResult", .{ .h = 120.0, .child_flags = .{ .border = true } })) {
                zgui.textWrapped("{s}", .{result});
            }
            zgui.endChild();
            if (zgui.button("Clear Response", .{})) {
                action.clear_node_result = true;
            }
        }
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

    zgui.textWrapped("ID: {s}", .{node.id});
    if (node.display_name) |name| {
        zgui.textWrapped("Name: {s}", .{name});
    }
    if (node.platform) |platform| {
        zgui.textWrapped("Platform: {s}", .{platform});
    }
    if (node.version) |version| {
        zgui.textWrapped("Version: {s}", .{version});
    }
    if (node.core_version) |core| {
        zgui.textWrapped("Core Version: {s}", .{core});
    }
    if (node.ui_version) |ui| {
        zgui.textWrapped("UI Version: {s}", .{ui});
    }
    if (node.connected) |connected| {
        zgui.textWrapped("Connected: {s}", .{if (connected) "yes" else "no"});
    }
    if (node.paired) |paired| {
        zgui.textWrapped("Paired: {s}", .{if (paired) "yes" else "no"});
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
