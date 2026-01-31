const std = @import("std");
const zgui = @import("zgui");
const builtin = @import("builtin");
const state = @import("../client/state.zig");
const config = @import("../client/config.zig");
const layout = @import("layout.zig");
const ui_state = @import("state.zig");
const theme = @import("theme.zig");
const sessions_panel = @import("panels/sessions_panel.zig");
const chat_panel = @import("panels/chat_panel.zig");
const settings_panel = @import("panels/settings_panel.zig");
const settings_view = @import("settings_view.zig");
const operator_view = @import("operator_view.zig");
const status_bar = @import("status_bar.zig");

pub const UiAction = struct {
    send_message: ?[]u8 = null,
    connect: bool = false,
    disconnect: bool = false,
    save_config: bool = false,
    clear_saved: bool = false,
    config_updated: bool = false,
    refresh_sessions: bool = false,
    select_session: ?[]u8 = null,
    check_updates: bool = false,
    open_release: bool = false,
    download_update: bool = false,
    open_download: bool = false,
    install_update: bool = false,
    refresh_nodes: bool = false,
    select_node: ?[]u8 = null,
    invoke_node: ?operator_view.NodeInvokeAction = null,
    describe_node: ?[]u8 = null,
    resolve_approval: ?operator_view.ExecApprovalResolveAction = null,
    clear_node_describe: ?[]u8 = null,
    clear_node_result: bool = false,
    clear_operator_notice: bool = false,
};

var safe_insets: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

pub fn setSafeInsets(left: f32, top: f32, right: f32, bottom: f32) void {
    safe_insets = .{ left, top, right, bottom };
}

pub fn draw(
    allocator: std.mem.Allocator,
    ctx: *state.ClientContext,
    cfg: *config.Config,
    is_connected: bool,
    app_version: []const u8,
    state_ui: *ui_state.UiState,
) UiAction {
    var action = UiAction{};

    const display = zgui.io.getDisplaySize();
    if (display[0] > 0.0 and display[1] > 0.0) {
        const left = safe_insets[0];
        const top = safe_insets[1];
        const right = safe_insets[2];
        const bottom = safe_insets[3];
        const width = @max(1.0, display[0] - left - right);
        const extra_bottom: f32 = if (builtin.abi == .android) 24.0 else 0.0;
        const height = @max(1.0, display[1] - top - bottom - extra_bottom);
        zgui.setNextWindowPos(.{ .x = left, .y = top, .cond = .always });
        zgui.setNextWindowSize(.{ .w = width, .h = height, .cond = .always });
    }

    const compact_header = builtin.abi == .android or (display[1] > 0.0 and display[1] < 720.0);
    var flags = zgui.WindowFlags{ .no_collapse = true, .no_saved_settings = true };
    if (compact_header) {
        flags.no_title_bar = true;
        flags.no_scrollbar = true;
        flags.no_scroll_with_mouse = true;
    }

    if (zgui.begin("ZiggyStarClaw", .{ .flags = flags })) {
        if (!compact_header) {
            theme.push(.title);
            zgui.text("ZiggyStarClaw and the Lobsters From Mars", .{});
            theme.pop();
            zgui.separator();
        }

        const style = zgui.getStyle();
        const spacing_x = style.item_spacing[0];
        const spacing_y = style.item_spacing[1];
        const avail = zgui.getContentRegionAvail();
        const status_height = zgui.getFrameHeightWithSpacing();
        const usable_h = @max(1.0, avail[1] - status_height - spacing_y);

        var metrics = layout.compute(state_ui, avail[0], usable_h, spacing_x, spacing_y);

        if (metrics.compact_layout) {
            if (zgui.beginChild(
                "SessionsPanel",
                .{ .w = metrics.avail_width, .h = metrics.sessions_height, .child_flags = .{ .border = true } },
            )) {
                const sessions_action = sessions_panel.draw(allocator, ctx);
                action.refresh_sessions = sessions_action.refresh;
                action.select_session = sessions_action.selected_key;
            }
            zgui.endChild();

            if (layout.splitterHorizontal(
                "split_sessions",
                metrics.avail_width,
                metrics.splitter,
                &state_ui.compact_sessions_height,
                state_ui.min_sessions_height,
                metrics.usable_height,
                1.0,
            )) {
                metrics = layout.compute(state_ui, avail[0], usable_h, spacing_x, spacing_y);
            }

            if (zgui.beginChild(
                "ChatPanel",
                .{ .w = metrics.avail_width, .h = metrics.chat_height, .child_flags = .{ .border = true } },
            )) {
                const chat_action = chat_panel.draw(allocator, ctx);
                action.send_message = chat_action.send_message;
            }
            zgui.endChild();

            if (layout.splitterHorizontal(
                "split_settings",
                metrics.avail_width,
                metrics.splitter,
                &state_ui.compact_settings_height,
                state_ui.min_settings_height,
                metrics.usable_height,
                -1.0,
            )) {
                metrics = layout.compute(state_ui, avail[0], usable_h, spacing_x, spacing_y);
            }

            if (zgui.beginChild(
                "RightPanel",
                .{ .w = metrics.avail_width, .h = metrics.settings_height, .child_flags = .{ .border = true } },
            )) {
                if (zgui.beginTabBar("RightTabs", .{})) {
                    if (zgui.beginTabItem("Settings", .{})) {
                        const settings_action = settings_panel.draw(
                            allocator,
                            cfg,
                            ctx.state,
                            is_connected,
                            &ctx.update_state,
                            app_version,
                        );
                        action.connect = settings_action.connect;
                        action.disconnect = settings_action.disconnect;
                        action.save_config = settings_action.save;
                        action.clear_saved = settings_action.clear_saved;
                        action.config_updated = settings_action.config_updated;
                        action.check_updates = settings_action.check_updates;
                        action.open_release = settings_action.open_release;
                        action.download_update = settings_action.download_update;
                        action.open_download = settings_action.open_download;
                        action.install_update = settings_action.install_update;
                        zgui.endTabItem();
                    }
                    if (zgui.beginTabItem("Operator", .{})) {
                        const operator_action = operator_view.draw(allocator, ctx, is_connected);
                        action.refresh_nodes = operator_action.refresh_nodes;
                        action.select_node = operator_action.select_node;
                        action.invoke_node = operator_action.invoke_node;
                        action.describe_node = operator_action.describe_node;
                        action.resolve_approval = operator_action.resolve_approval;
                        action.clear_node_describe = operator_action.clear_node_describe;
                        action.clear_node_result = operator_action.clear_node_result;
                        action.clear_operator_notice = operator_action.clear_operator_notice;
                        zgui.endTabItem();
                    }
                    zgui.endTabBar();
                }
            }
            zgui.endChild();
        } else {
            if (zgui.beginChild(
                "SessionsPanel",
                .{ .w = metrics.left_width, .h = metrics.usable_height, .child_flags = .{ .border = true } },
            )) {
                const sessions_action = sessions_panel.draw(allocator, ctx);
                action.refresh_sessions = sessions_action.refresh;
                action.select_session = sessions_action.selected_key;
            }
            zgui.endChild();

            zgui.sameLine(.{ .spacing = spacing_x });

            const total_gap = state_ui.splitter_thickness * 2.0 + spacing_x * 2.0;
            const max_left = @max(
                state_ui.min_left_width,
                avail[0] - state_ui.right_width - state_ui.min_center_width - total_gap,
            );
            if (layout.splitterVertical(
                "split_left",
                metrics.usable_height,
                metrics.splitter,
                &state_ui.left_width,
                state_ui.min_left_width,
                max_left,
                1.0,
            )) {
                metrics = layout.compute(state_ui, avail[0], usable_h, spacing_x, spacing_y);
            }

            zgui.sameLine(.{ .spacing = spacing_x });

            if (zgui.beginChild(
                "ChatPanel",
                .{ .w = metrics.center_width, .h = metrics.usable_height, .child_flags = .{ .border = true } },
            )) {
                const chat_action = chat_panel.draw(allocator, ctx);
                action.send_message = chat_action.send_message;
            }
            zgui.endChild();

            zgui.sameLine(.{ .spacing = spacing_x });

            const max_right = @max(
                state_ui.min_right_width,
                avail[0] - state_ui.left_width - state_ui.min_center_width - total_gap,
            );
            if (layout.splitterVertical(
                "split_right",
                metrics.usable_height,
                metrics.splitter,
                &state_ui.right_width,
                state_ui.min_right_width,
                max_right,
                -1.0,
            )) {
                metrics = layout.compute(state_ui, avail[0], usable_h, spacing_x, spacing_y);
            }

            zgui.sameLine(.{ .spacing = spacing_x });

            if (zgui.beginChild(
                "RightPanel",
                .{ .w = metrics.right_width, .h = metrics.usable_height, .child_flags = .{ .border = true } },
            )) {
                if (zgui.beginTabBar("RightTabs", .{})) {
                    if (zgui.beginTabItem("Settings", .{})) {
                        const settings_action = settings_panel.draw(
                            allocator,
                            cfg,
                            ctx.state,
                            is_connected,
                            &ctx.update_state,
                            app_version,
                        );
                        action.connect = settings_action.connect;
                        action.disconnect = settings_action.disconnect;
                        action.save_config = settings_action.save;
                        action.clear_saved = settings_action.clear_saved;
                        action.config_updated = settings_action.config_updated;
                        action.check_updates = settings_action.check_updates;
                        action.open_release = settings_action.open_release;
                        action.download_update = settings_action.download_update;
                        action.open_download = settings_action.open_download;
                        action.install_update = settings_action.install_update;
                        zgui.endTabItem();
                    }
                    if (zgui.beginTabItem("Operator", .{})) {
                        const operator_action = operator_view.draw(allocator, ctx, is_connected);
                        action.refresh_nodes = operator_action.refresh_nodes;
                        action.select_node = operator_action.select_node;
                        action.invoke_node = operator_action.invoke_node;
                        action.describe_node = operator_action.describe_node;
                        action.resolve_approval = operator_action.resolve_approval;
                        action.clear_node_describe = operator_action.clear_node_describe;
                        action.clear_node_result = operator_action.clear_node_result;
                        action.clear_operator_notice = operator_action.clear_operator_notice;
                        zgui.endTabItem();
                    }
                    zgui.endTabBar();
                }
            }
            zgui.endChild();
        }

        status_bar.draw(ctx.state, is_connected, ctx.current_session, ctx.messages.items.len, ctx.last_error);
    }
    zgui.end();

    return action;
}

pub fn syncSettings(cfg: config.Config) void {
    settings_view.syncFromConfig(cfg);
}
