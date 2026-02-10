const std = @import("std");
const components = @import("../components/components.zig");
const draw_context = @import("../draw_context.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets/widgets.zig");
const panel_chrome = @import("../panel_chrome.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");
const nav_router = @import("../input/nav_router.zig");
const surface_chrome = @import("../surface_chrome.zig");

var draw_ctx_toggle = false;
var sdf_debug_enabled = false;
var input_debug_enabled = false;
var scroll_y: f32 = 0.0;
var scroll_max: f32 = 0.0;

pub const Action = struct {
    open_pack_root: bool = false,
    reload_effective_pack: bool = false,
};

var preview_disabled: bool = false;
var preview_checked: bool = true;
var preview_focus_ring: bool = true;
var preview_text_editor: ?widgets.text_editor.TextEditor = null;

pub fn draw(allocator: std.mem.Allocator, rect_override: ?draw_context.Rect) Action {
    var action: Action = .{};
    const t = theme.activeTheme();
    const panel_rect = rect_override orelse return action;
    var dc = draw_context.DrawContext.init(
        allocator,
        .{ .direct = .{} },
        t,
        panel_rect,
    );
    defer dc.deinit();
    surface_chrome.drawBackground(&dc, panel_rect);

    const queue = input_router.getQueue();
    const padding = t.spacing.md;
    const content_rect = draw_context.Rect.fromMinSize(
        .{ panel_rect.min[0] + padding, panel_rect.min[1] + padding },
        .{ panel_rect.size()[0] - padding * 2.0, panel_rect.size()[1] - padding * 2.0 },
    );
    if (content_rect.size()[0] <= 0.0 or content_rect.size()[1] <= 0.0) {
        return action;
    }

    handleWheelScroll(queue, panel_rect, &scroll_y, scroll_max, 36.0);

    dc.pushClip(content_rect);
    var cursor_y = content_rect.min[1] - scroll_y;

    const project_args = components.composite.project_card.Args{
        .id = "showcase_project",
        .name = "Ziggy Starclaw",
        .description = "Major UI redesign milestone",
        .categories = &[_]components.composite.project_card.Category{
            .{ .name = "desktop", .variant = .primary },
            .{ .name = "release", .variant = .success },
        },
        .recent_artifacts = &[_]components.composite.project_card.Artifact{
            .{ .name = "ui_layout.zig", .file_type = "zig", .status = "edited" },
            .{ .name = "theme_tokens.json", .file_type = "json", .status = "synced" },
            .{ .name = "wireframe.png", .file_type = "image", .status = "exported" },
        },
    };
    const project_width = content_rect.size()[0];
    const project_height = components.composite.project_card.measureHeight(
        allocator,
        &dc,
        project_args,
        project_width,
    );
    const project_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, project_height });
    components.composite.project_card.draw(
        allocator,
        &dc,
        project_rect,
        project_args,
    );
    cursor_y += project_height + t.spacing.md;

    const source_height = @max(220.0, @min(360.0, content_rect.size()[1] * 0.35));
    const source_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, source_height });
    _ = components.composite.source_browser.draw(allocator, &dc, .{
        .id = "showcase_source",
        .sources = &[_]components.composite.source_browser.Source{
            .{ .name = "Local Workspace", .source_type = .local, .connected = true },
            .{ .name = "Design Repo", .source_type = .git, .connected = true },
            .{ .name = "Cloud Backup", .source_type = .cloud, .connected = false },
        },
        .selected_source = 0,
        .current_path = "/ui/components",
        .files = &[_]components.composite.source_browser.FileEntry{
            .{ .name = "project_card.zig", .language = "zig", .status = "modified", .dirty = true },
            .{ .name = "source_browser.zig", .language = "zig", .status = "synced", .dirty = false },
            .{ .name = "layout.md", .language = "md", .status = "review", .dirty = false },
        },
        .rect = source_rect,
    });
    cursor_y += source_height + t.spacing.md;

    const task_args = components.composite.task_progress.Args{
        .title = "Build Pipeline",
        .steps = &[_]components.composite.task_progress.Step{
            .{ .label = "Plan", .state = .complete },
            .{ .label = "Build", .state = .active },
            .{ .label = "Ship", .state = .pending },
        },
        .detail = "Compiling UI assets and validating layout rules.",
        .show_logs_button = true,
    };
    const task_height = components.composite.task_progress.measureHeight(
        allocator,
        &dc,
        task_args,
        project_width,
    );
    const task_rect = draw_context.Rect.fromMinSize(.{ content_rect.min[0], cursor_y }, .{ project_width, task_height });
    _ = components.composite.task_progress.draw(
        allocator,
        &dc,
        task_rect,
        queue,
        task_args,
    );
    cursor_y += task_height + t.spacing.md;

    const demo_height = drawContextDemoCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += demo_height + t.spacing.md;

    const inspect_height = themePackInspectorCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t, &action);
    cursor_y += inspect_height + t.spacing.md;

    const preview_height = themePreviewCard(allocator, &dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += preview_height + t.spacing.md;

    const sdf_height = sdfDebugCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += sdf_height + t.spacing.md;

    const input_height = inputDebugCard(&dc, queue, .{ content_rect.min[0], cursor_y }, project_width, t);
    cursor_y += input_height + t.spacing.md;

    dc.popClip();

    const content_height = (cursor_y + scroll_y) - content_rect.min[1];
    scroll_max = @max(0.0, content_height - content_rect.size()[1]);
    if (scroll_y > scroll_max) scroll_y = scroll_max;
    if (scroll_y < 0.0) scroll_y = 0.0;

    return action;
}

fn themePackInspectorCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
    action: *Action,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    const max_w = width - padding * 2.0;
    const open_label = "Open pack root";
    const reload_label = "Reload effective pack";
    const open_w = buttonWidth(dc, open_label, t);
    const reload_w = buttonWidth(dc, reload_label, t);
    const stacked_actions = (open_w + t.spacing.sm + reload_w) > max_w;
    const action_buttons_h: f32 = if (stacked_actions)
        (button_height * 2.0 + t.spacing.xs + t.spacing.sm)
    else
        (button_height + t.spacing.sm);

    // Rough layout: a handful of fixed lines plus a few lists.
    const templates = theme_runtime.getWindowTemplates();
    const template_lines: f32 = @floatFromInt(@min(templates.len, 6));

    const layout_profiles: f32 = 4.0;
    const base_lines: f32 = 12.0; // status/root/meta/defaults + headings

    const height = padding + line_height + t.spacing.xs +
        (base_lines + template_lines + layout_profiles) * (line_height + t.spacing.xs) +
        action_buttons_h + // inspector actions
        button_height + padding; // scroll-to-top
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Theme Pack Inspector");
    const left = rect.min[0] + padding;

    // Status + root.
    {
        const st = theme_runtime.getPackStatus();
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "Status: {s}  msg: {s}",
            .{ @tagName(st.kind), if (st.msg.len > 0) st.msg else "(none)" },
        ) catch "Status: (format error)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }
    {
        const root = theme_runtime.getThemePackRootPath() orelse "";
        var buf: [1024]u8 = undefined;
        const line = if (root.len > 0)
            (std.fmt.bufPrint(&buf, "Root: {s}", .{root}) catch "Root: (format error)")
        else
            "Root: (built-in)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    // Actions (for rapid iteration when editing theme packs).
    {
        var x = left;
        if (stacked_actions) {
            // If the card is narrow, stack buttons.
            const b0 = draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ max_w, button_height });
            if (widgets.button.draw(dc, b0, open_label, queue, .{ .variant = .secondary })) {
                action.open_pack_root = true;
            }
            cursor_y += button_height + t.spacing.xs;
            const b1 = draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ max_w, button_height });
            if (widgets.button.draw(dc, b1, reload_label, queue, .{ .variant = .secondary })) {
                action.reload_effective_pack = true;
            }
            cursor_y += button_height + t.spacing.sm;
        } else {
            const b0 = draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ open_w, button_height });
            if (widgets.button.draw(dc, b0, open_label, queue, .{ .variant = .secondary })) {
                action.open_pack_root = true;
            }
            x += open_w + t.spacing.sm;
            const b1 = draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ reload_w, button_height });
            if (widgets.button.draw(dc, b1, reload_label, queue, .{ .variant = .secondary })) {
                action.reload_effective_pack = true;
            }
            cursor_y += button_height + t.spacing.sm;
        }
    }

    // Manifest meta.
    if (theme_runtime.getPackMeta()) |m| {
        var buf: [1024]u8 = undefined;
        const name = if (m.name.len > 0) m.name else m.id;
        const line = std.fmt.bufPrint(
            &buf,
            "Pack: {s}  id={s}  author={s}  defaults={s}/{s}",
            .{ name, m.id, if (m.author.len > 0) m.author else "(none)", m.defaults_variant, m.defaults_profile },
        ) catch "Pack: (format error)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    } else {
        dc.drawText("Pack: (none)", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    // Render defaults.
    {
        const rd = theme_runtime.getRenderDefaults();
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "Render: image_sampling={s}  pixel_snap_textured={s}",
            .{ @tagName(rd.image_sampling), if (rd.pixel_snap_textured) "true" else "false" },
        ) catch "Render: (format error)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    // Token swatches.
    {
        dc.drawText("Tokens:", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.xs;

        const sw = @max(12.0, line_height * 0.8);
        const gap = t.spacing.xs;
        const row_h = @max(sw, line_height);
        var x = left;
        const max_x = rect.max[0] - padding;
        const items = [_]struct { name: []const u8, color: [4]f32 }{
            .{ .name = "bg", .color = t.colors.background },
            .{ .name = "surface", .color = t.colors.surface },
            .{ .name = "primary", .color = t.colors.primary },
            .{ .name = "border", .color = t.colors.border },
            .{ .name = "text", .color = t.colors.text_primary },
        };
        for (items) |it| {
            const label_w = dc.measureText(it.name, 0.0)[0];
            const need = sw + gap + label_w + t.spacing.sm;
            if (x + need > max_x) {
                x = left;
                cursor_y += row_h + t.spacing.xs;
            }
            const r = draw_context.Rect.fromMinSize(.{ x, cursor_y + (row_h - sw) * 0.5 }, .{ sw, sw });
            dc.drawRoundedRect(r, t.radius.sm, .{ .fill = it.color, .stroke = t.colors.border, .thickness = 1.0 });
            dc.drawText(it.name, .{ r.max[0] + gap, cursor_y + (row_h - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
            x += need;
        }
        cursor_y += row_h + t.spacing.xs;
    }

    // Styles summary.
    {
        const ss = theme_runtime.getStyleSheet();
        var buf: [1024]u8 = undefined;
        const frame = if (ss.panel.frame_image.isSet()) ss.panel.frame_image.slice() else "(none)";
        const line = std.fmt.bufPrint(
            &buf,
            "Styles: panel.radius={d:.1} frame={s}",
            .{ ss.panel.radius orelse t.radius.md, frame },
        ) catch "Styles: (format error)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
        cursor_y += line_height + t.spacing.xs;
    }

    // Window templates.
    {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Window templates: {d}", .{templates.len}) catch "Window templates: (format error)";
        dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.xs;

        for (templates[0..@min(templates.len, 6)]) |tpl| {
            var buf2: [512]u8 = undefined;
            const title = if (tpl.title.len > 0) tpl.title else tpl.id;
            const line2 = std.fmt.bufPrint(&buf2, " - {s}  ({d}x{d})", .{ title, tpl.width, tpl.height }) catch " - (format error)";
            dc.drawText(line2, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
            cursor_y += line_height + t.spacing.xs;
        }
    }

    // Workspace layout presets.
    {
        dc.drawText("Workspace layouts:", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
        cursor_y += line_height + t.spacing.xs;

        const ids = [_]theme_runtime.ProfileId{ .desktop, .phone, .tablet, .fullscreen };
        for (ids) |pid| {
            const preset = theme_runtime.getWorkspaceLayout(pid);
            var buf: [768]u8 = undefined;
            const line = if (preset) |p| blk: {
                const open = p.openPanels();
                var tmp: [256]u8 = undefined;
                var written: usize = 0;
                for (open) |k| {
                    if (written >= tmp.len) break;
                    const name = @tagName(k);
                    const add = std.fmt.bufPrint(tmp[written..], "{s}{s}", .{ if (written == 0) "" else ",", name }) catch break;
                    written += add.len;
                }
                const list = tmp[0..written];
                break :blk std.fmt.bufPrint(
                    &buf,
                    " - {s}: open=[{s}] focus={s} close_others={s}",
                    .{
                        @tagName(pid),
                        list,
                        if (p.focused) |fk| @tagName(fk) else "(none)",
                        if (p.close_others) "true" else "false",
                    },
                ) catch " - (format error)";
            } else blk: {
                break :blk std.fmt.bufPrint(&buf, " - {s}: (none)", .{@tagName(pid)}) catch " - (format error)";
            };
            dc.drawText(line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
            cursor_y += line_height + t.spacing.xs;
        }
    }

    // A small “clip” button to reduce noise when testing reloads (keeps the inspector near the top).
    const btn_label = if (scroll_y > 0.0) "Scroll to top" else "Scroll to top";
    const bw = dc.measureText(btn_label, 0.0)[0] + t.spacing.md * 2.0;
    const brect = draw_context.Rect.fromMinSize(.{ left, rect.max[1] - padding - button_height }, .{ bw, button_height });
    if (widgets.button.draw(dc, brect, btn_label, input_router.getQueue(), .{ .variant = .ghost })) {
        scroll_y = 0.0;
    }

    return height;
}

fn ensureEditor(slot: *?widgets.text_editor.TextEditor, allocator: std.mem.Allocator) *widgets.text_editor.TextEditor {
    if (slot.* == null) {
        slot.* = widgets.text_editor.TextEditor.init(allocator) catch unreachable;
    }
    return &slot.*.?;
}

fn themePreviewCard(
    allocator: std.mem.Allocator,
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    const row_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const input_height = widgets.text_input.defaultHeight(t, line_height);

    const chrome_h: f32 = 148.0;
    const height =
        padding + line_height + t.spacing.xs +
        row_height + t.spacing.xs + // disabled toggle
        button_height + t.spacing.sm + // buttons row
        row_height + t.spacing.xs + // checkbox row
        (line_height + t.spacing.xs + input_height) + t.spacing.sm + // text input
        (if (preview_focus_ring) (line_height + t.spacing.xs + 42.0 + t.spacing.sm) else (line_height + t.spacing.xs + 42.0 + t.spacing.sm)) +
        chrome_h +
        padding;

    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });
    var cursor_y = drawCardBase(dc, rect, "Theme Preview");
    const left = rect.min[0] + padding;
    const content_w = rect.size()[0] - padding * 2.0;

    // Isolate widget ids inside this card.
    nav_router.pushScope(std.hash.Wyhash.hash(0, "showcase_theme_preview"));
    defer nav_router.popScope();

    // Disabled toggle.
    {
        var disabled = preview_disabled;
        _ = widgets.checkbox.draw(
            dc,
            draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_w, row_height }),
            "Disable controls (preview)",
            &disabled,
            queue,
            .{},
        );
        preview_disabled = disabled;
        cursor_y += row_height + t.spacing.xs;
    }

    // Buttons row (primary/secondary/ghost).
    {
        const labels = [_][]const u8{ "Primary", "Secondary", "Ghost" };
        const variants = [_]widgets.button.Variant{ .primary, .secondary, .ghost };
        var x = left;
        const max_x = rect.max[0] - padding;
        var i: usize = 0;
        while (i < labels.len) : (i += 1) {
            const w = buttonWidth(dc, labels[i], t);
            if (x + w > max_x and x != left) break;
            _ = widgets.button.draw(
                dc,
                draw_context.Rect.fromMinSize(.{ x, cursor_y }, .{ w, button_height }),
                labels[i],
                queue,
                .{ .variant = variants[i], .disabled = preview_disabled },
            );
            x += w + t.spacing.sm;
        }
        cursor_y += button_height + t.spacing.sm;
    }

    // Checkbox preview.
    {
        var checked = preview_checked;
        _ = widgets.checkbox.draw(
            dc,
            draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_w, row_height }),
            "Checkbox (preview)",
            &checked,
            queue,
            .{ .disabled = preview_disabled },
        );
        preview_checked = checked;
        cursor_y += row_height + t.spacing.xs;
    }

    // Text input preview.
    {
        dc.drawText("Text input (preview)", .{ left, cursor_y }, .{ .color = t.colors.text_primary });
        const input_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y + line_height + t.spacing.xs }, .{ content_w, input_height });
        const ed = ensureEditor(&preview_text_editor, allocator);
        _ = widgets.text_input.draw(ed, allocator, dc, input_rect, queue, .{
            .placeholder = "Type to test cursor, selection, focus ring, etc.",
            .read_only = preview_disabled,
        });
        cursor_y += line_height + t.spacing.xs + input_height + t.spacing.sm;
    }

    // Focus ring preview (forced-on).
    {
        var focus_on = preview_focus_ring;
        _ = widgets.checkbox.draw(
            dc,
            draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_w, row_height }),
            "Show focus ring (preview)",
            &focus_on,
            queue,
            .{ .disabled = preview_disabled },
        );
        preview_focus_ring = focus_on;
        cursor_y += row_height + t.spacing.xs;

        const ring_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ @min(260.0, content_w), 42.0 });
        panel_chrome.draw(dc, ring_rect, .{ .radius = t.radius.sm, .draw_shadow = false, .draw_frame = false });
        dc.drawText("focus target", .{ ring_rect.min[0] + t.spacing.sm, ring_rect.min[1] + (ring_rect.size()[1] - line_height) * 0.5 }, .{ .color = t.colors.text_secondary });
        if (preview_focus_ring and !preview_disabled) {
            widgets.focus_ring.draw(dc, ring_rect, t.radius.sm);
        }
        cursor_y += ring_rect.size()[1] + t.spacing.sm;
    }

    // Panel chrome preview (shadow/frame/9-slice).
    {
        const chrome_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ content_w, chrome_h });
        const ss = theme_runtime.getStyleSheet();
        const radius = ss.panel.radius orelse t.radius.md;
        panel_chrome.draw(dc, chrome_rect, .{
            .radius = radius,
            .draw_shadow = true,
            .draw_frame = true,
            .draw_border = true,
        });
        dc.drawText("Panel chrome (shadow + optional 9-slice frame image)", .{ chrome_rect.min[0] + t.spacing.sm, chrome_rect.min[1] + t.spacing.sm }, .{ .color = t.colors.text_primary });
    }

    return height;
}

fn inputDebugCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const toggle_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const lines: f32 = 7.0;
    const content_height = toggle_height + t.spacing.sm + (if (input_debug_enabled) (lines * (line_height + t.spacing.xs)) else 0.0);
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Input Diagnostics");
    const left = rect.min[0] + padding;

    var enabled = input_debug_enabled;
    _ = widgets.checkbox.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, toggle_height }),
        "Show input + nav debug",
        &enabled,
        queue,
        .{},
    );
    input_debug_enabled = enabled;
    cursor_y += toggle_height + t.spacing.sm;

    if (!input_debug_enabled) return height;

    const p = theme_runtime.getProfile();
    var buf0: [256]u8 = undefined;
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var buf3: [256]u8 = undefined;
    var buf4: [256]u8 = undefined;
    var buf5: [256]u8 = undefined;

    const profile_line = std.fmt.bufPrint(
        &buf0,
        "Profile: {s}  modality: {s}  hit_target_min_px: {d}",
        .{ @tagName(p.id), @tagName(p.modality), @as(u32, @intFromFloat(p.hit_target_min_px)) },
    ) catch "Profile: (format error)";
    dc.drawText(profile_line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    const pointer_line = std.fmt.bufPrint(
        &buf1,
        "Pointer: {s}  dragging: {s}  drag_delta: ({d:.1},{d:.1})",
        .{
            @tagName(queue.state.pointer_kind),
            if (queue.state.pointer_dragging) "true" else "false",
            queue.state.pointer_drag_delta[0],
            queue.state.pointer_drag_delta[1],
        },
    ) catch "Pointer: (format error)";
    dc.drawText(pointer_line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    const mouse_line = std.fmt.bufPrint(
        &buf2,
        "Mouse: pos=({d:.1},{d:.1})  down_left={s}",
        .{
            queue.state.mouse_pos[0],
            queue.state.mouse_pos[1],
            if (queue.state.mouse_down_left) "true" else "false",
        },
    ) catch "Mouse: (format error)";
    dc.drawText(mouse_line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    const nav_state = nav_router.get();
    const nav_active = if (nav_state) |nav| nav.isActive() else false;
    const focused_id = if (nav_state) |nav| nav.focused_id else null;
    const nav_items_prev = if (nav_state) |nav| nav.prev_items.items.len else 0;
    const nav_line = std.fmt.bufPrint(
        &buf3,
        "Nav: active={s}  focused_id={s}  prev_items={d}",
        .{
            if (nav_active) "true" else "false",
            if (focused_id) |id| (std.fmt.bufPrint(&buf4, "0x{x}", .{id}) catch "0x?") else "(none)",
            nav_items_prev,
        },
    ) catch "Nav: (format error)";
    dc.drawText(nav_line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    const events_line = std.fmt.bufPrint(&buf5, "Events this frame: {d}", .{queue.events.items.len}) catch "Events: (format error)";
    dc.drawText(events_line, .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    cursor_y += line_height + t.spacing.xs;

    dc.drawText("Touch/pen scroll starts after ~8px drag.", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });

    return height;
}

fn sdfDebugCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const toggle_height = @max(line_height + t.spacing.xs * 2.0, theme_runtime.getProfile().hit_target_min_px);
    const demo_h: f32 = 220.0;
    const content_height = toggle_height + t.spacing.sm + (if (sdf_debug_enabled) demo_h else 0.0);
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "SDF Effects Lab");
    const left = rect.min[0] + padding;

    var enabled = sdf_debug_enabled;
    _ = widgets.checkbox.draw(
        dc,
        draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, toggle_height }),
        "Show SDF debug shapes",
        &enabled,
        queue,
        .{},
    );
    sdf_debug_enabled = enabled;
    cursor_y += toggle_height + t.spacing.sm;

    if (!sdf_debug_enabled) return height;

    const demo_rect = draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ rect.size()[0] - padding * 2.0, demo_h });
    drawSdfDemos(dc, demo_rect, t);
    return height;
}

fn drawSdfDemos(dc: *draw_context.DrawContext, rect: draw_context.Rect, t: *const theme.Theme) void {
    // Background for the demo area.
    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = false,
        .draw_frame = false,
    });

    const pad = t.spacing.md;
    const col_w = (rect.size()[0] - pad) * 0.5;
    const row_h = (rect.size()[1] - pad) * 0.5;
    const a = draw_context.Rect.fromMinSize(.{ rect.min[0] + pad, rect.min[1] + pad }, .{ col_w - pad, row_h - pad });
    const b = draw_context.Rect.fromMinSize(.{ rect.min[0] + col_w + pad, rect.min[1] + pad }, .{ col_w - pad, row_h - pad });
    const c = draw_context.Rect.fromMinSize(.{ rect.min[0] + pad, rect.min[1] + row_h + pad }, .{ col_w - pad, row_h - pad });
    const d = draw_context.Rect.fromMinSize(.{ rect.min[0] + col_w + pad, rect.min[1] + row_h + pad }, .{ col_w - pad, row_h - pad });

    // 1) Soft shadow
    {
        const base = draw_context.Rect.fromMinSize(.{ a.min[0] + 10, a.min[1] + 18 }, .{ a.size()[0] - 20, a.size()[1] - 36 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 24, base.min[1] - 24 },
            .max = .{ base.max[0] + 24, base.max[1] + 24 },
        };
        dc.drawSoftRoundedRect(draw_rect, base, 10.0, .fill_soft, 0.0, 18.0, 1.0, .{ 0, 0, 0, 0.55 }, true, .alpha);
        dc.drawRoundedRect(base, 10.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("shadow (soft fill)", .{ a.min[0] + 10, a.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 2) Glow stroke
    {
        const base = draw_context.Rect.fromMinSize(.{ b.min[0] + 10, b.min[1] + 18 }, .{ b.size()[0] - 20, b.size()[1] - 36 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 26, base.min[1] - 26 },
            .max = .{ base.max[0] + 26, base.max[1] + 26 },
        };
        // Additive makes glows "pop" and is a common game-UI trick.
        dc.drawSoftRoundedRect(draw_rect, base, 12.0, .stroke_soft, 10.0, 16.0, 1.0, .{ t.colors.primary[0], t.colors.primary[1], t.colors.primary[2], 0.9 }, true, .additive);
        dc.drawRoundedRect(base, 12.0, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("glow (soft stroke)", .{ b.min[0] + 10, b.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 3) Falloff exponent (alpha curve)
    {
        const left_w = (c.size()[0] - 30) * 0.5;
        const base0 = draw_context.Rect.fromMinSize(.{ c.min[0] + 10, c.min[1] + 18 }, .{ left_w, c.size()[1] - 36 });
        const base1 = draw_context.Rect.fromMinSize(.{ base0.max[0] + 10, c.min[1] + 18 }, .{ left_w, c.size()[1] - 36 });
        const blur: f32 = 18.0;
        const draw0 = draw_context.Rect{ .min = .{ base0.min[0] - 26, base0.min[1] - 26 }, .max = .{ base0.max[0] + 26, base0.max[1] + 26 } };
        const draw1 = draw_context.Rect{ .min = .{ base1.min[0] - 26, base1.min[1] - 26 }, .max = .{ base1.max[0] + 26, base1.max[1] + 26 } };
        dc.drawSoftRoundedRect(draw0, base0, 14.0, .fill_soft, 0.0, blur, 0.6, .{ 0, 0, 0, 0.45 }, true, .alpha);
        dc.drawSoftRoundedRect(draw1, base1, 14.0, .fill_soft, 0.0, blur, 2.4, .{ 0, 0, 0, 0.45 }, true, .alpha);
        dc.drawRoundedRect(base0, 14.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawRoundedRect(base1, 14.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.drawText("falloff exp: 0.6 | 2.4", .{ c.min[0] + 10, c.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }

    // 4) Clip stack behavior (respect vs ignore)
    {
        const clip_rect = draw_context.Rect.fromMinSize(.{ d.min[0] + 10, d.min[1] + 18 }, .{ d.size()[0] - 20, d.size()[1] - 36 });
        dc.drawRoundedRect(clip_rect, 12.0, .{ .fill = t.colors.background, .stroke = t.colors.border, .thickness = 1.0 });

        const base = draw_context.Rect.fromMinSize(.{ clip_rect.min[0] + 10, clip_rect.min[1] + 10 }, .{ clip_rect.size()[0] * 0.75, clip_rect.size()[1] * 0.55 });
        const draw_rect = draw_context.Rect{
            .min = .{ base.min[0] - 32, base.min[1] - 32 },
            .max = .{ base.max[0] + 32, base.max[1] + 32 },
        };

        // A) Respect clip
        dc.pushClip(clip_rect);
        dc.drawSoftRoundedRect(draw_rect, base, 12.0, .fill_soft, 0.0, 22.0, 1.0, .{ 0, 0, 0, 0.55 }, true, .alpha);
        dc.drawRoundedRect(base, 12.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.popClip();

        // B) Ignore clip (draws outside the clip_rect)
        const base2 = draw_context.Rect.fromMinSize(.{ base.min[0] + 18, base.min[1] + 34 }, .{ base.size()[0], base.size()[1] });
        const draw_rect2 = draw_context.Rect{
            .min = .{ base2.min[0] - 32, base2.min[1] - 32 },
            .max = .{ base2.max[0] + 32, base2.max[1] + 32 },
        };
        dc.pushClip(clip_rect);
        dc.drawSoftRoundedRect(draw_rect2, base2, 12.0, .fill_soft, 0.0, 22.0, 1.0, .{ 0, 0, 0, 0.45 }, false, .alpha);
        dc.drawRoundedRect(base2, 12.0, .{ .fill = t.colors.surface, .stroke = t.colors.border, .thickness = 1.0 });
        dc.popClip();

        dc.drawText("clip: respect | ignore", .{ d.min[0] + 10, d.min[1] + 6 }, .{ .color = t.colors.text_secondary });
    }
}

fn drawContextDemoCard(
    dc: *draw_context.DrawContext,
    queue: *input_state.InputQueue,
    pos: [2]f32,
    width: f32,
    t: *const theme.Theme,
) f32 {
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();
    const button_height = widgets.button.defaultHeight(t, line_height);
    const button_label = "Context Button";
    const button_width = buttonWidth(dc, button_label, t);
    const content_height = button_height + t.spacing.sm + line_height;
    const height = padding + line_height + t.spacing.xs + content_height + padding;
    const rect = draw_context.Rect.fromMinSize(pos, .{ width, height });

    var cursor_y = drawCardBase(dc, rect, "Draw Context Demo");
    const left = rect.min[0] + padding;
    if (widgets.button.draw(dc, draw_context.Rect.fromMinSize(.{ left, cursor_y }, .{ button_width, button_height }), button_label, queue, .{
        .variant = if (draw_ctx_toggle) .primary else .secondary,
    })) {
        draw_ctx_toggle = !draw_ctx_toggle;
    }
    cursor_y += button_height + t.spacing.sm;
    dc.drawText("State: ", .{ left, cursor_y }, .{ .color = t.colors.text_secondary });
    const state_offset = dc.measureText("State: ", 0.0)[0];
    dc.drawText(if (draw_ctx_toggle) "on" else "off", .{ left + state_offset, cursor_y }, .{ .color = t.colors.text_primary });
    return height;
}

fn drawCardBase(dc: *draw_context.DrawContext, rect: draw_context.Rect, title: []const u8) f32 {
    const t = dc.theme;
    const padding = t.spacing.md;
    const line_height = dc.lineHeight();

    panel_chrome.draw(dc, rect, .{
        .radius = t.radius.md,
        .draw_shadow = true,
        .draw_frame = false,
    });
    theme.pushFor(t, .heading);
    dc.drawText(title, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
    theme.pop();

    return rect.min[1] + padding + line_height + t.spacing.xs;
}

fn buttonWidth(ctx: *draw_context.DrawContext, label: []const u8, t: *const theme.Theme) f32 {
    return ctx.measureText(label, 0.0)[0] + t.spacing.sm * 2.0;
}

fn handleWheelScroll(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_value: *f32,
    max_scroll: f32,
    step: f32,
) void {
    widgets.kinetic_scroll.apply(queue, rect, scroll_value, max_scroll, step);
}
