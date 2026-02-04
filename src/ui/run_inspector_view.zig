const std = @import("std");
const zgui = @import("zgui");
const state = @import("../client/state.zig");
const types = @import("../protocol/types.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const components = @import("components/components.zig");

var split_state = components.layout.split_pane.SplitState{ .size = 520.0 };
var show_logs = false;

const Step = struct {
    label: []const u8,
    state: components.data.progress_step.State,
};

pub fn draw(ctx: *state.ClientContext) void {
    const opened = zgui.beginChild("RunInspectorView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        _ = components.layout.header_bar.begin(.{ .title = "Task Progress", .subtitle = "Run Inspector" });
        components.layout.header_bar.end();

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
                const steps = [_]Step{
                    .{ .label = "Collect Sources", .state = .complete },
                    .{ .label = "Analyze Data", .state = .complete },
                    .{ .label = "Draft Summary", .state = .active },
                    .{ .label = "Review Outputs", .state = .pending },
                };
                theme.push(.heading);
                zgui.text("Task Progress", .{});
                theme.pop();
                zgui.separator();
                zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
                drawStepList(steps[0..], t);

                zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
                if (components.core.button.draw("View Logs", .{ .variant = .secondary, .size = .small })) {
                    show_logs = !show_logs;
                }

                zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
                if (components.layout.card.begin(.{ .title = "Current Step Details", .id = "run_inspector_detail" })) {
                    zgui.textWrapped("Step: Draft Summary", .{});
                    components.core.badge.draw("In Progress", .{ .variant = .primary, .filled = false, .size = .small });
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
                    var refs_buf: [3][]const u8 = undefined;
                    const refs = collectReferenceNames(ctx, &refs_buf);
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
                            zgui.textDisabled("Referenced files:", .{});
                            if (refs.len == 0) {
                                zgui.textWrapped("No references yet.", .{});
                            } else {
                                for (refs, 0..) |ref_name, ref_idx| {
                                    if (ref_idx > 0) zgui.sameLine(.{ .spacing = t.spacing.xs });
                                    components.core.badge.draw(ref_name, .{ .variant = .neutral, .filled = false, .size = .small });
                                }
                            }
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

fn drawStepList(steps: []const Step, t: *const theme.Theme) void {
    for (steps, 0..) |step, idx| {
        zgui.pushIntId(@intCast(idx));
        defer zgui.popId();
        drawStepRow(step, idx + 1, t);
        if (idx + 1 < steps.len) {
            zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });
        }
    }
}

fn drawStepRow(step: Step, index: usize, t: *const theme.Theme) void {
    const cursor_screen = zgui.getCursorScreenPos();
    const cursor_local = zgui.getCursorPos();
    const avail = zgui.getContentRegionAvail();
    const row_height = zgui.getFrameHeight() + t.spacing.sm;
    _ = zgui.invisibleButton("##step_row", .{ .w = avail[0], .h = row_height });

    const draw_list = zgui.getWindowDrawList();
    const circle_size: f32 = row_height - t.spacing.xs;
    const center = .{ cursor_screen[0] + circle_size * 0.5, cursor_screen[1] + circle_size * 0.5 };
    const variant = statusVariant(step.state);
    const color = switch (variant) {
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
        .primary => t.colors.primary,
        .neutral => t.colors.divider,
    };

    draw_list.addCircleFilled(.{
        .p = center,
        .r = circle_size * 0.5,
        .col = zgui.colorConvertFloat4ToU32(color),
    });
    if (step.state == .complete) {
        drawCheckmark(draw_list, t, center, circle_size * 0.45);
    } else {
        var idx_buf: [8]u8 = undefined;
        const idx_label = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "1";
        const idx_size = zgui.calcTextSize(idx_label, .{});
        draw_list.addText(
            .{ center[0] - idx_size[0] * 0.5, center[1] - idx_size[1] * 0.5 },
            zgui.colorConvertFloat4ToU32(t.colors.background),
            "{s}",
            .{idx_label},
        );
    }

    const label_size = zgui.calcTextSize(step.label, .{});
    const text_pos = .{
        cursor_screen[0] + circle_size + t.spacing.sm,
        cursor_screen[1] + (row_height - label_size[1]) * 0.5,
    };
    draw_list.addText(
        text_pos,
        zgui.colorConvertFloat4ToU32(t.colors.text_primary),
        "{s}",
        .{step.label},
    );

    drawStepBadge(draw_list, t, statusLabel(step.state), variant, cursor_screen, avail[0], row_height);
    zgui.setCursorPos(.{ cursor_local[0], cursor_local[1] + row_height });
    zgui.dummy(.{ .w = 0.0, .h = 0.0 });
}

fn drawCheckmark(draw_list: zgui.DrawList, t: *const theme.Theme, center: [2]f32, size: f32) void {
    const x = center[0] - size * 0.5;
    const y = center[1] - size * 0.2;
    const color = zgui.colorConvertFloat4ToU32(t.colors.background);
    draw_list.addLine(.{
        .p1 = .{ x, y + size * 0.4 },
        .p2 = .{ x + size * 0.35, y + size },
        .col = color,
        .thickness = 2.0,
    });
    draw_list.addLine(.{
        .p1 = .{ x + size * 0.35, y + size },
        .p2 = .{ x + size, y },
        .col = color,
        .thickness = 2.0,
    });
}

fn drawStepBadge(
    draw_list: zgui.DrawList,
    t: *const theme.Theme,
    label: []const u8,
    variant: components.core.badge.Variant,
    row_pos: [2]f32,
    row_width: f32,
    row_height: f32,
) void {
    const label_size = zgui.calcTextSize(label, .{});
    const padding = .{ t.spacing.xs, t.spacing.xs * 0.5 };
    const badge_size = .{
        label_size[0] + padding[0] * 2.0,
        label_size[1] + padding[1] * 2.0,
    };
    const x = row_pos[0] + row_width - badge_size[0] - t.spacing.sm;
    const y = row_pos[1] + (row_height - badge_size[1]) * 0.5;
    const base = switch (variant) {
        .neutral => t.colors.divider,
        .primary => t.colors.primary,
        .success => t.colors.success,
        .warning => t.colors.warning,
        .danger => t.colors.danger,
    };
    const bg = colors.withAlpha(base, 0.18);
    const border = colors.withAlpha(base, 0.4);
    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + badge_size[0], y + badge_size[1] },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = t.radius.lg,
    });
    draw_list.addRect(.{
        .pmin = .{ x, y },
        .pmax = .{ x + badge_size[0], y + badge_size[1] },
        .col = zgui.colorConvertFloat4ToU32(border),
        .rounding = t.radius.lg,
    });
    draw_list.addText(
        .{ x + padding[0], y + padding[1] },
        zgui.colorConvertFloat4ToU32(base),
        "{s}",
        .{label},
    );
}

fn statusVariant(step_state: components.data.progress_step.State) components.core.badge.Variant {
    return switch (step_state) {
        .pending => .neutral,
        .active => .primary,
        .complete => .success,
        .failed => .danger,
    };
}

fn statusLabel(step_state: components.data.progress_step.State) []const u8 {
    return switch (step_state) {
        .pending => "Pending",
        .active => "In Progress",
        .complete => "Complete",
        .failed => "Failed",
    };
}

fn collectReferenceNames(ctx: *state.ClientContext, buf: [][]const u8) [][]const u8 {
    var len: usize = 0;
    const messages = messagesForCurrentSession(ctx);
    var index: usize = messages.len;
    while (index > 0 and len < buf.len) : (index -= 1) {
        const message: types.ChatMessage = messages[index - 1];
        if (message.attachments) |attachments| {
            for (attachments) |attachment| {
                if (len >= buf.len) break;
                buf[len] = attachment.name orelse attachment.url;
                len += 1;
            }
        }
    }
    return buf[0..len];
}

fn messagesForCurrentSession(ctx: *state.ClientContext) []const types.ChatMessage {
    if (ctx.current_session) |session_key| {
        if (ctx.findSessionState(session_key)) |session_state| {
            return session_state.messages.items;
        }
    }
    return &[_]types.ChatMessage{};
}
