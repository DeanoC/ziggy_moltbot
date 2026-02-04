const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

const AgentStatus = struct {
    label: []const u8,
    variant: components.core.badge.Variant,
};

pub fn draw(ctx: *state.ClientContext) void {
    const opened = zgui.beginChild("AgentsView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        const header_open = components.layout.header_bar.begin(.{ .title = "Active Agents", .subtitle = "Live status" });
        if (header_open) {
            var total_buf: [32]u8 = undefined;
            const total_label = std.fmt.bufPrint(&total_buf, "{d} agents", .{ctx.nodes.items.len}) catch "0 agents";
            components.core.badge.draw(total_label, .{ .variant = .primary, .filled = false, .size = .small });
        }
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        if (components.layout.card.begin(.{ .title = "Status Overview", .id = "agents_overview" })) {
            const counts = collectCounts(ctx.nodes.items);
            drawCountBadge("Ready", counts.ready, .success);
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            drawCountBadge("Pairing", counts.pairing, .warning);
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            drawCountBadge("Offline", counts.offline, .neutral);
        }
        components.layout.card.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        if (components.layout.scroll_area.begin(.{ .id = "AgentsList", .border = false })) {
            if (ctx.nodes.items.len == 0) {
                zgui.textDisabled("No active agents connected.", .{});
            } else {
                for (ctx.nodes.items, 0..) |node, idx| {
                    zgui.pushIntId(@intCast(idx));
                    defer zgui.popId();
                    drawAgentRow(node);
                    if (idx + 1 < ctx.nodes.items.len) {
                        zgui.separator();
                        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
                    }
                }
            }
        }
        components.layout.scroll_area.end();
    }
    zgui.endChild();
}

fn drawAgentRow(node: types.Node) void {
    const label = node.display_name orelse node.id;
    const subtitle = node.device_family orelse node.model_identifier orelse node.platform;
    components.data.agent_status.draw(.{
        .label = label,
        .subtitle = subtitle,
        .connected = node.connected,
        .paired = node.paired,
        .platform = node.platform,
    });
    const status = statusForNode(node);
    zgui.sameLine(.{});
    components.core.badge.draw(status.label, .{
        .variant = status.variant,
        .filled = true,
        .size = .small,
    });
}

fn statusForNode(node: types.Node) AgentStatus {
    const connected = node.connected orelse false;
    const paired = node.paired orelse false;
    if (connected and paired) {
        return .{ .label = "Ready", .variant = .success };
    }
    if (connected and !paired) {
        return .{ .label = "Pairing", .variant = .warning };
    }
    return .{ .label = "Offline", .variant = .neutral };
}

const StatusCounts = struct {
    ready: usize = 0,
    pairing: usize = 0,
    offline: usize = 0,
};

fn collectCounts(nodes: []const types.Node) StatusCounts {
    var counts = StatusCounts{};
    for (nodes) |node| {
        const status = statusForNode(node);
        switch (status.variant) {
            .success => counts.ready += 1,
            .warning => counts.pairing += 1,
            else => counts.offline += 1,
        }
    }
    return counts;
}

fn drawCountBadge(label: []const u8, count: usize, variant: components.core.badge.Variant) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} ({d})", .{ label, count }) catch label;
    components.core.badge.draw(text, .{ .variant = variant, .filled = false, .size = .small });
}
