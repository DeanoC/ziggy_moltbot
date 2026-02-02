const std = @import("std");
const zgui = @import("zgui");
const theme = @import("../../theme.zig");
const components = @import("../components.zig");

pub const SourceType = enum {
    local,
    cloud,
    git,
};

pub const Source = struct {
    name: []const u8,
    source_type: SourceType = .local,
    connected: bool = true,
};

pub const FileEntry = struct {
    name: []const u8,
    language: ?[]const u8 = null,
    status: ?[]const u8 = null,
    dirty: bool = false,
};

pub const Args = struct {
    id: []const u8 = "source_browser",
    sources: []const Source = &[_]Source{},
    selected_source: ?usize = null,
    current_path: []const u8 = "",
    files: []const FileEntry = &[_]FileEntry{},
    selected_file: ?usize = null,
    split_state: ?*components.layout.split_pane.SplitState = null,
};

pub const Action = struct {
    select_source: ?usize = null,
    select_file: ?usize = null,
};

var default_split_state = components.layout.split_pane.SplitState{ .size = 220.0 };

fn sourceTypeLabel(source_type: SourceType) []const u8 {
    return switch (source_type) {
        .local => "local",
        .cloud => "cloud",
        .git => "git",
    };
}

pub fn draw(args: Args) Action {
    var action = Action{};
    const t = theme.activeTheme();
    var split_state = args.split_state orelse &default_split_state;
    if (split_state.size == 0.0) {
        split_state.size = 220.0;
    }

    const split_args = components.layout.split_pane.Args{
        .id = args.id,
        .axis = .vertical,
        .primary_size = split_state.size,
        .min_primary = 180.0,
        .min_secondary = 220.0,
        .border = true,
        .padded = true,
    };

    components.layout.split_pane.begin(split_args, split_state);
    if (components.layout.split_pane.beginPrimary(split_args, split_state)) {
        theme.push(.heading);
        zgui.text("Sources", .{});
        theme.pop();
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });

        var sources_id_buf: [96]u8 = undefined;
        const sources_id = std.fmt.bufPrint(&sources_id_buf, "{s}_sources", .{args.id}) catch "sources";
        if (components.layout.scroll_area.begin(.{ .id = sources_id, .height = 0.0, .border = true })) {
            if (args.sources.len == 0) {
                zgui.textDisabled("No sources available.", .{});
            } else {
                for (args.sources, 0..) |source, idx| {
                    zgui.pushIntId(@intCast(idx));
                    defer zgui.popId();
                    var label_buf: [196]u8 = undefined;
                    const status = if (source.connected) "connected" else "offline";
                    const label = std.fmt.bufPrint(
                        &label_buf,
                        "{s} ({s}, {s})",
                        .{ source.name, sourceTypeLabel(source.source_type), status },
                    ) catch source.name;
                    const selected = args.selected_source != null and args.selected_source.? == idx;
                    if (components.data.list_item.draw(.{
                        .label = label,
                        .selected = selected,
                    })) {
                        action.select_source = idx;
                    }
                }
            }
        }
        components.layout.scroll_area.end();
    }
    components.layout.split_pane.endPrimary();

    components.layout.split_pane.handleSplitter(split_args, split_state);

    if (components.layout.split_pane.beginSecondary(split_args, split_state)) {
        if (args.current_path.len > 0) {
            zgui.text("Path:", .{});
            zgui.sameLine(.{ .spacing = t.spacing.sm });
            zgui.textDisabled("{s}", .{args.current_path});
            zgui.separator();
        }

        var files_id_buf: [96]u8 = undefined;
        const files_id = std.fmt.bufPrint(&files_id_buf, "{s}_files", .{args.id}) catch "files";
        if (components.layout.scroll_area.begin(.{ .id = files_id, .height = 0.0, .border = true })) {
            if (args.files.len == 0) {
                zgui.textDisabled("No files in this source.", .{});
            } else {
                for (args.files, 0..) |file, idx| {
                    zgui.pushIntId(@intCast(idx));
                    defer zgui.popId();
                    var label_buf: [256]u8 = undefined;
                    const label = std.fmt.bufPrint(
                        &label_buf,
                        "{s}{s}{s}{s}{s}{s}{s}",
                        .{
                            file.name,
                            if (file.dirty) " *" else "",
                            if (file.language != null) " (" else "",
                            file.language orelse "",
                            if (file.language != null) ")" else "",
                            if (file.status != null) " - " else "",
                            file.status orelse "",
                        },
                    ) catch file.name;
                    const selected = args.selected_file != null and args.selected_file.? == idx;
                    if (components.data.list_item.draw(.{
                        .label = label,
                        .selected = selected,
                    })) {
                        action.select_file = idx;
                    }
                }
            }
        }
        components.layout.scroll_area.end();
    }
    components.layout.split_pane.endSecondary();
    components.layout.split_pane.end();
    return action;
}
