const zgui = @import("zgui");
const state = @import("../client/state.zig");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

var split_state = components.layout.split_pane.SplitState{ .size = 520.0 };
var show_logs = false;

pub fn draw(ctx: *state.ClientContext) void {
    const opened = zgui.beginChild("RunInspectorView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        if (components.layout.header_bar.begin(.{ .title = "Run Inspector", .subtitle = "Task Progress" })) {
            components.layout.header_bar.end();
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        const split_args = components.layout.split_pane.Args{
            .id = "run_inspector",
            .axis = .vertical,
            .primary_size = split_state.size,
            .min_primary = 360.0,
            .min_secondary = 240.0,
            .border = true,
            .padded = true,
        };

        components.layout.split_pane.begin(split_args, &split_state);
        if (components.layout.split_pane.beginPrimary(split_args, &split_state)) {
            if (components.layout.scroll_area.begin(.{ .id = "RunInspectorMain", .border = false })) {
                const steps = [_]components.composite.task_progress.Step{
                    .{ .label = "Collect Sources", .state = .complete },
                    .{ .label = "Analyze Data", .state = .complete },
                    .{ .label = "Draft Summary", .state = .active },
                    .{ .label = "Review Outputs", .state = .pending },
                };
                if (components.composite.task_progress.draw(.{
                    .title = "Task Progress",
                    .steps = steps[0..],
                    .detail = "Drafting executive summary based on the latest sources and charts.",
                    .show_logs_button = true,
                }) == .view_logs) {
                    show_logs = !show_logs;
                }

                zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
                if (components.layout.card.begin(.{ .title = "Current Step Details", .id = "run_inspector_detail" })) {
                    zgui.textWrapped("Step: Draft Summary", .{});
                    zgui.textWrapped("ETA: 2 minutes", .{});
                    zgui.textWrapped("Outputs: Summary doc, chart annotations", .{});
                }
                components.layout.card.end();

                if (show_logs) {
                    zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
                    if (components.layout.card.begin(.{ .title = "Live Logs", .id = "run_inspector_logs" })) {
                        zgui.textWrapped("[info] Fetching competitor data...", .{});
                        zgui.textWrapped("[info] Aggregating weekly metrics...", .{});
                        zgui.textWrapped("[warn] Missing segment in region APAC.", .{});
                        zgui.textWrapped("[info] Writing summary section...", .{});
                    }
                    components.layout.card.end();
                }
            }
            components.layout.scroll_area.end();
        }
        components.layout.split_pane.endPrimary();

        components.layout.split_pane.handleSplitter(split_args, &split_state);

        if (components.layout.split_pane.beginSecondary(split_args, &split_state)) {
            if (components.layout.scroll_area.begin(.{ .id = "RunInspectorSide", .border = false })) {
                if (components.layout.card.begin(.{ .title = "Agent Notifications", .id = "run_inspector_agents" })) {
                    if (ctx.nodes.items.len == 0) {
                        zgui.textDisabled("No active agents yet.", .{});
                    } else {
                        for (ctx.nodes.items, 0..) |node, idx| {
                            zgui.pushIntId(@intCast(idx));
                            defer zgui.popId();
                            const label = node.display_name orelse node.id;
                            components.data.agent_status.draw(.{
                                .label = label,
                                .subtitle = node.platform,
                                .connected = node.connected,
                                .paired = node.paired,
                                .platform = node.platform,
                            });
                            if (idx + 1 < ctx.nodes.items.len) {
                                zgui.separator();
                            }
                            zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
                        }
                    }
                }
                components.layout.card.end();
            }
            components.layout.scroll_area.end();
        }
        components.layout.split_pane.endSecondary();
        components.layout.split_pane.end();
    }
    zgui.endChild();
}
