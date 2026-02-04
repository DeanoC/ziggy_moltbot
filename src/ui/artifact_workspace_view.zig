const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const components = @import("components/components.zig");
const ui_systems = @import("ui_systems.zig");
const undo_redo = @import("systems/undo_redo.zig");
const systems = @import("systems/systems.zig");

const ArtifactTab = enum {
    preview,
    edit,
};

var active_tab: ArtifactTab = .preview;
var edit_initialized = false;
var edit_buf: [4096:0]u8 = [_:0]u8{0} ** 4096;
var edit_len: usize = 0;
var undo_stack: ?undo_redo.UndoRedoStack(EditState) = null;

const EditState = struct {
    len: usize,
    buf: [4096]u8,
};

const ToolbarIcon = enum {
    copy,
    undo,
    redo,
    expand,
};

pub fn draw() void {
    const opened = zgui.beginChild("ArtifactWorkspaceView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        _ = components.layout.header_bar.begin(.{ .title = "Artifact Workspace", .subtitle = "Preview & Edit" });
        components.layout.header_bar.end();

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
        if (drawTabToggle("Preview", active_tab == .preview)) {
            active_tab = .preview;
        }
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (drawTabToggle("Edit", active_tab == .edit)) {
            active_tab = .edit;
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

        if (components.layout.scroll_area.begin(.{ .id = "ArtifactWorkspaceContent", .border = false })) {
            switch (active_tab) {
                .preview => drawPreview(t),
                .edit => drawEditor(),
            }
        }
        components.layout.scroll_area.end();

        zgui.separator();
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        _ = drawToolbarIcon("toolbar_copy", .copy, t);
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (drawToolbarIcon("toolbar_undo", .undo, t)) {
            applyUndo();
        }
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (drawToolbarIcon("toolbar_redo", .redo, t)) {
            applyRedo();
        }
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = drawToolbarIcon("toolbar_expand", .expand, t);
    }
    zgui.endChild();
}

fn drawPreview(t: *const theme.Theme) void {
    if (components.layout.card.begin(.{ .title = "Report Summary", .id = "artifact_summary" })) {
        theme.push(.heading);
        zgui.text("Quarterly Performance Overview", .{});
        theme.pop();
        zgui.textWrapped(
            "This report summarizes sales performance, highlights key insights, and links supporting artifacts collected during the run.",
            .{},
        );
    }
    components.layout.card.end();

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    if (components.layout.card.begin(.{ .title = "Key Insights", .id = "artifact_insights" })) {
        zgui.bulletText("North America revenue is trending up 12% month-over-month.", .{});
        zgui.bulletText("Top competitor share declined after feature launch.", .{});
        zgui.bulletText("Pipeline risk concentrated in two enterprise accounts.", .{});
    }
    components.layout.card.end();

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.md });

    if (components.layout.card.begin(.{ .title = "Sales Performance (Chart)", .id = "artifact_chart" })) {
        zgui.textWrapped("Weekly sales performance", .{});
        const draw_list = zgui.getWindowDrawList();
        const cursor = zgui.getCursorScreenPos();
        const size = zgui.getContentRegionAvail();
        const height = @min(140.0, size[1]);
        const width = size[0];
        const bar_width = 18.0;
        const gap = 10.0;
        const base_y = cursor[1] + height;
        const bar_color = zgui.colorConvertFloat4ToU32(theme.activeTheme().colors.primary);
        var x = cursor[0];
        const bars = [_]f32{ 0.4, 0.6, 0.3, 0.8, 0.5, 0.7 };
        for (bars) |ratio| {
            const bar_h = height * ratio;
            draw_list.addRectFilled(.{
                .pmin = .{ x, base_y - bar_h },
                .pmax = .{ x + bar_width, base_y },
                .col = bar_color,
                .rounding = 3.0,
            });
            x += bar_width + gap;
        }
        const axis_color = zgui.colorConvertFloat4ToU32(theme.activeTheme().colors.border);
        draw_list.addLine(.{
            .p1 = .{ cursor[0], base_y },
            .p2 = .{ cursor[0] + width, base_y },
            .col = axis_color,
            .thickness = 1.0,
        });
        draw_list.addLine(.{
            .p1 = .{ cursor[0], cursor[1] },
            .p2 = .{ cursor[0], base_y },
            .col = axis_color,
            .thickness = 1.0,
        });
        draw_list.addText(.{ cursor[0] + width - 36.0, base_y + 4.0 }, axis_color, "Week", .{});
        draw_list.addText(.{ cursor[0] + 4.0, cursor[1] - 16.0 }, axis_color, "Sales", .{});
        zgui.dummy(.{ .w = width, .h = height + 12.0 });

        zgui.separator();
        zgui.text("Competitor Analysis", .{});
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = drawTabToggle("Sales", true);
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = drawTabToggle("Dow", false);
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = drawTabToggle("Proclues", false);
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        _ = drawTabToggle("Pemble", false);
    }
    components.layout.card.end();
}

fn drawEditor() void {
    if (!edit_initialized) {
        const seed =
            "## Report Summary\n\n" ++
            "Write a concise summary of the report findings.\n\n" ++
            "## Key Insights\n\n" ++
            "- Insight 1\n" ++
            "- Insight 2\n\n" ++
            "## Action Items\n\n" ++
            "- Follow up with sales leadership\n";
        fillBuffer(edit_buf[0..], seed);
        edit_len = bufferLen();
        ensureUndoStack();
        edit_initialized = true;
    }

    const before = captureState();
    const changed = zgui.inputTextMultiline("##ArtifactEditor", .{
        .buf = edit_buf[0.. :0],
        .h = 340.0,
        .flags = .{ .allow_tab_input = true },
    });
    if (zgui.isItemActive()) {
        const sys = ui_systems.get();
        sys.keyboard.setFocus("artifact_editor");
        registerShortcuts(sys);
    }
    if (changed) {
        edit_len = bufferLen();
        const after = captureState();
        if (!statesEqual(before, after)) {
            ensureUndoStack();
            if (undo_stack) |*stack| {
                _ = stack.execute(.{
                    .name = "edit",
                    .state_before = before,
                    .state_after = after,
                }) catch {};
            }
        }
    }
}

fn fillBuffer(buf: []u8, text: []const u8) void {
    const len = @min(text.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..len], text[0..len]);
    buf[len] = 0;
    if (len + 1 < buf.len) {
        @memset(buf[len + 1 ..], 0);
    }
}

fn ensureUndoStack() void {
    if (undo_stack == null) {
        undo_stack = undo_redo.UndoRedoStack(EditState).init(std.heap.page_allocator, 64, null);
    }
}

fn captureState() EditState {
    var state = EditState{
        .len = edit_len,
        .buf = [_]u8{0} ** 4096,
    };
    const slice = edit_buf[0..edit_len];
    std.mem.copyForwards(u8, state.buf[0..edit_len], slice);
    return state;
}

fn applyState(state: EditState) void {
    edit_len = @min(state.len, edit_buf.len - 1);
    std.mem.copyForwards(u8, edit_buf[0..edit_len], state.buf[0..edit_len]);
    edit_buf[edit_len] = 0;
    if (edit_len + 1 < edit_buf.len) {
        @memset(edit_buf[edit_len + 1 ..], 0);
    }
}

fn statesEqual(a: EditState, b: EditState) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
}

fn bufferLen() usize {
    return std.mem.sliceTo(&edit_buf, 0).len;
}

fn applyUndo() void {
    if (undo_stack) |*stack| {
        if (stack.undo()) |state| {
            applyState(state);
        }
    }
}

fn applyRedo() void {
    if (undo_stack) |*stack| {
        if (stack.redo()) |state| {
            applyState(state);
        }
    }
}

fn registerShortcuts(sys: *systems.Systems) void {
    sys.keyboard.register(.{
        .id = "artifact.undo",
        .key = .z,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onUndoShortcut,
    }) catch {};
    sys.keyboard.register(.{
        .id = "artifact.redo",
        .key = .y,
        .ctrl = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onRedoShortcut,
    }) catch {};
    sys.keyboard.register(.{
        .id = "artifact.redo_shift",
        .key = .z,
        .ctrl = true,
        .shift = true,
        .scope = .focused,
        .focus_id = "artifact_editor",
        .action = onRedoShortcut,
    }) catch {};
}

fn onUndoShortcut(_: ?*anyopaque) void {
    applyUndo();
}

fn onRedoShortcut(_: ?*anyopaque) void {
    applyRedo();
}

fn drawTabToggle(label: []const u8, active: bool) bool {
    return components.core.button.draw(label, .{
        .variant = if (active) .primary else .secondary,
        .size = .small,
    });
}

fn drawToolbarIcon(id: []const u8, icon: ToolbarIcon, t: *const theme.Theme) bool {
    const size = t.spacing.lg + t.spacing.sm;
    const cursor = zgui.getCursorScreenPos();
    const id_z = zgui.formatZ("##{s}", .{id});
    _ = zgui.invisibleButton(id_z, .{ .w = size, .h = size });
    const hovered = zgui.isItemHovered(.{});
    const clicked = zgui.isItemClicked(.left);

    const draw_list = zgui.getWindowDrawList();
    const bg = if (hovered)
        colors.withAlpha(t.colors.primary, 0.12)
    else
        t.colors.surface;
    draw_list.addRectFilled(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + size, cursor[1] + size },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = t.radius.sm,
    });
    draw_list.addRect(.{
        .pmin = cursor,
        .pmax = .{ cursor[0] + size, cursor[1] + size },
        .col = zgui.colorConvertFloat4ToU32(colors.withAlpha(t.colors.border, 0.7)),
        .rounding = t.radius.sm,
    });

    const center = .{ cursor[0] + size * 0.5, cursor[1] + size * 0.5 };
    const icon_color = zgui.colorConvertFloat4ToU32(t.colors.text_primary);
    switch (icon) {
        .copy => {
            const rect_size: f32 = size * 0.35;
            draw_list.addRect(.{
                .pmin = .{ center[0] - rect_size, center[1] - rect_size },
                .pmax = .{ center[0] + rect_size * 0.4, center[1] + rect_size * 0.4 },
                .col = icon_color,
                .rounding = 2.0,
            });
            draw_list.addRect(.{
                .pmin = .{ center[0] - rect_size * 0.4, center[1] - rect_size * 0.4 },
                .pmax = .{ center[0] + rect_size, center[1] + rect_size },
                .col = icon_color,
                .rounding = 2.0,
            });
        },
        .undo => {
            const left = center[0] - size * 0.18;
            const right = center[0] + size * 0.18;
            draw_list.addLine(.{
                .p1 = .{ right, center[1] },
                .p2 = .{ left, center[1] },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ left, center[1] },
                .p2 = .{ left + size * 0.1, center[1] - size * 0.1 },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ left, center[1] },
                .p2 = .{ left + size * 0.1, center[1] + size * 0.1 },
                .col = icon_color,
                .thickness = 2.0,
            });
        },
        .redo => {
            const left = center[0] - size * 0.18;
            const right = center[0] + size * 0.18;
            draw_list.addLine(.{
                .p1 = .{ left, center[1] },
                .p2 = .{ right, center[1] },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ right, center[1] },
                .p2 = .{ right - size * 0.1, center[1] - size * 0.1 },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ right, center[1] },
                .p2 = .{ right - size * 0.1, center[1] + size * 0.1 },
                .col = icon_color,
                .thickness = 2.0,
            });
        },
        .expand => {
            const offset = size * 0.18;
            draw_list.addLine(.{
                .p1 = .{ center[0] - offset, center[1] - offset },
                .p2 = .{ center[0] - offset, center[1] - size * 0.3 },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ center[0] - offset, center[1] - offset },
                .p2 = .{ center[0] - size * 0.3, center[1] - offset },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ center[0] + offset, center[1] + offset },
                .p2 = .{ center[0] + offset, center[1] + size * 0.3 },
                .col = icon_color,
                .thickness = 2.0,
            });
            draw_list.addLine(.{
                .p1 = .{ center[0] + offset, center[1] + offset },
                .p2 = .{ center[0] + size * 0.3, center[1] + offset },
                .col = icon_color,
                .thickness = 2.0,
            });
        },
    }

    return clicked;
}
