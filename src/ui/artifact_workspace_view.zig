const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const components = @import("components/components.zig");

const ArtifactTab = enum {
    preview,
    edit,
};

var active_tab: ArtifactTab = .preview;
var edit_initialized = false;
var edit_buf: [4096:0]u8 = [_:0]u8{0} ** 4096;

pub fn draw() void {
    const opened = zgui.beginChild("ArtifactWorkspaceView", .{ .h = 0.0, .child_flags = .{ .border = true } });
    if (opened) {
        const t = theme.activeTheme();
        if (components.layout.header_bar.begin(.{ .title = "Artifact Workspace", .subtitle = "Preview & Edit" })) {
            components.layout.header_bar.end();
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });
        if (components.core.tab_bar.begin("ArtifactTabs")) {
            if (components.core.tab_bar.beginItem("Preview")) {
                active_tab = .preview;
                components.core.tab_bar.endItem();
            }
            if (components.core.tab_bar.beginItem("Edit")) {
                active_tab = .edit;
                components.core.tab_bar.endItem();
            }
            components.core.tab_bar.end();
        }

        zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

        if (components.layout.scroll_area.begin(.{ .id = "ArtifactWorkspaceContent", .border = false })) {
            switch (active_tab) {
                .preview => drawPreview(t),
                .edit => drawEditor(),
            }
        }
        components.layout.scroll_area.end();

        zgui.separator();
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
        if (components.core.icon_button.draw("C", .{ .tooltip = "Copy" })) {}
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (components.core.icon_button.draw("U", .{ .tooltip = "Undo" })) {}
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (components.core.icon_button.draw("R", .{ .tooltip = "Redo" })) {}
        zgui.sameLine(.{ .spacing = t.spacing.sm });
        if (components.core.icon_button.draw("E", .{ .tooltip = "Expand" })) {}
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

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

    if (components.layout.card.begin(.{ .title = "Key Insights", .id = "artifact_insights" })) {
        zgui.bulletText("North America revenue is trending up 12% month-over-month.", .{});
        zgui.bulletText("Top competitor share declined after feature launch.", .{});
        zgui.bulletText("Pipeline risk concentrated in two enterprise accounts.", .{});
    }
    components.layout.card.end();

    zgui.dummy(.{ .w = 0.0, .h = t.spacing.sm });

    if (components.layout.card.begin(.{ .title = "Sales Performance (Chart)", .id = "artifact_chart" })) {
        zgui.textWrapped("Chart placeholder: weekly sales performance.", .{});
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
        zgui.dummy(.{ .w = width, .h = height });
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
        edit_initialized = true;
    }

    _ = zgui.inputTextMultiline("##ArtifactEditor", .{
        .buf = edit_buf[0.. :0],
        .h = 340.0,
        .flags = .{ .allow_tab_input = true },
    });
}

fn fillBuffer(buf: []u8, text: []const u8) void {
    const len = @min(text.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..len], text[0..len]);
    buf[len] = 0;
    if (len + 1 < buf.len) {
        @memset(buf[len + 1 ..], 0);
    }
}
