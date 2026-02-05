const std = @import("std");
const ui_build = @import("ui_build.zig");
const use_imgui = ui_build.use_imgui;
const zgui = if (use_imgui) @import("zgui") else struct {};
const input_router = @import("input/input_router.zig");
const command_list = @import("render/command_list.zig");
const theme = @import("theme.zig");
const colors = @import("theme/colors.zig");
const text_metrics = @import("text_metrics.zig");
const font_system = @import("font_system.zig");

pub const Vec2 = [2]f32;
pub const Color = [4]f32;
pub const Texture = u64;
pub const TextMetrics = text_metrics.Metrics;

pub const RenderBackend = struct {
    drawRect: *const fn (ctx: *DrawContext, rect: Rect, style: RectStyle) void,
    drawRoundedRect: *const fn (ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void,
    drawText: *const fn (ctx: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void,
    drawLine: *const fn (ctx: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void,
    drawImage: *const fn (ctx: *DrawContext, texture: Texture, rect: Rect) void,
    pushClip: *const fn (ctx: *DrawContext, rect: Rect) void,
    popClip: *const fn (ctx: *DrawContext) void,
};

pub const InputBackend = struct {
    isHovered: *const fn (ctx: *DrawContext, rect: Rect) bool,
    isClicked: *const fn (ctx: *DrawContext, rect: Rect) bool,
    isDragging: *const fn (ctx: *DrawContext, rect: Rect) bool,
};

pub const Rect = struct {
    min: Vec2,
    max: Vec2,

    pub fn fromMinSize(min: Vec2, extent: Vec2) Rect {
        return .{
            .min = min,
            .max = .{ min[0] + extent[0], min[1] + extent[1] },
        };
    }

    pub fn size(self: Rect) Vec2 {
        return .{ self.max[0] - self.min[0], self.max[1] - self.min[1] };
    }

    pub fn contains(self: Rect, point: Vec2) bool {
        return point[0] >= self.min[0] and point[0] <= self.max[0] and point[1] >= self.min[1] and point[1] <= self.max[1];
    }
};

pub const ImGuiBackend = struct {};
pub const DirectBackend = struct {};

pub const Backend = union(enum) {
    imgui: ImGuiBackend,
    direct: DirectBackend,
};

pub const RectStyle = struct {
    fill: ?Color = null,
    stroke: ?Color = null,
    thickness: f32 = 1.0,
};

pub const TextStyle = struct {
    color: Color,
};

pub const DrawContext = struct {
    backend: Backend,
    theme: *const theme.Theme,
    viewport: Rect,
    clip_stack: std.ArrayList(Rect),
    allocator: std.mem.Allocator,
    text_metrics: TextMetrics,
    render: RenderBackend,
    input: InputBackend,
    command_list: ?*command_list.CommandList,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: Backend,
        theme_ref: *const theme.Theme,
        viewport: Rect,
    ) DrawContext {
        const resolved_backend: Backend = if (use_imgui) backend else switch (backend) {
            .imgui => .{ .direct = .{} },
            .direct => backend,
        };
        var render_backend = switch (resolved_backend) {
            .imgui => imgui_render_backend,
            .direct => null_render_backend,
        };
        const metrics = switch (resolved_backend) {
            .imgui => text_metrics.imgui,
            .direct => text_metrics.default,
        };
        const input_backend = switch (resolved_backend) {
            .imgui => imgui_input_backend,
            .direct => null_input_backend,
        };
        var list_ptr: ?*command_list.CommandList = null;
        if (global_command_list) |list| {
            render_backend = record_render_backend;
            list_ptr = list;
        }

        return .{
            .backend = resolved_backend,
            .theme = theme_ref,
            .viewport = viewport,
            .clip_stack = .empty,
            .allocator = allocator,
            .text_metrics = metrics,
            .render = render_backend,
            .input = input_backend,
            .command_list = list_ptr,
        };
    }

    pub fn deinit(self: *DrawContext) void {
        self.clip_stack.deinit(self.allocator);
    }

    pub fn setViewport(self: *DrawContext, viewport: Rect) void {
        self.viewport = viewport;
    }

    pub fn setTheme(self: *DrawContext, theme_ref: *const theme.Theme) void {
        self.theme = theme_ref;
    }

    pub fn setTextMetrics(self: *DrawContext, metrics: TextMetrics) void {
        self.text_metrics = metrics;
    }

    pub fn setRenderBackend(self: *DrawContext, backend: RenderBackend) void {
        self.render = backend;
    }

    pub fn setInputBackend(self: *DrawContext, backend: InputBackend) void {
        self.input = backend;
    }

    pub fn setCommandList(self: *DrawContext, list: ?*command_list.CommandList) void {
        self.command_list = list;
    }

    pub fn drawRect(self: *DrawContext, rect: Rect, style: RectStyle) void {
        self.render.drawRect(self, rect, style);
    }

    pub fn drawRoundedRect(self: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
        self.render.drawRoundedRect(self, rect, radius, style);
    }

    pub fn drawText(self: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void {
        self.render.drawText(self, text, pos, style);
    }

    pub fn lineHeight(self: *DrawContext) f32 {
        return self.text_metrics.line_height();
    }

    pub fn measureText(self: *DrawContext, text: []const u8, wrap_width: f32) Vec2 {
        return self.text_metrics.measure(text, wrap_width);
    }

    pub fn drawLine(self: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void {
        self.render.drawLine(self, from, to, width, color);
    }

    pub fn drawImage(self: *DrawContext, texture: Texture, rect: Rect) void {
        self.render.drawImage(self, texture, rect);
    }

    pub fn textureFromId(id: u64) Texture {
        return id;
    }

    pub fn pushClip(self: *DrawContext, rect: Rect) void {
        self.render.pushClip(self, rect);
        _ = self.clip_stack.append(self.allocator, rect) catch {};
    }

    pub fn popClip(self: *DrawContext) void {
        if (self.clip_stack.items.len == 0) return;
        _ = self.clip_stack.pop();
        self.render.popClip(self);
    }

    pub fn isHovered(self: *DrawContext, rect: Rect) bool {
        return self.input.isHovered(self, rect);
    }

    pub fn isClicked(self: *DrawContext, rect: Rect) bool {
        return self.input.isClicked(self, rect);
    }

    pub fn isDragging(self: *DrawContext, rect: Rect) bool {
        return self.input.isDragging(self, rect);
    }
};

pub fn drawOverlayLabel(dc: *DrawContext, label: []const u8, pos: Vec2) void {
    const t = dc.theme;
    const padding = t.spacing.xs;
    const text_size = dc.measureText(label, 0.0);
    const rect_min = .{ pos[0] + 12.0, pos[1] + 12.0 };
    const rect = Rect.fromMinSize(
        rect_min,
        .{ text_size[0] + padding * 2.0, text_size[1] + padding * 2.0 },
    );
    dc.drawRoundedRect(rect, t.radius.sm, .{
        .fill = colors.withAlpha(t.colors.surface, 0.95),
        .stroke = colors.withAlpha(t.colors.border, 0.8),
        .thickness = 1.0,
    });
    dc.drawText(label, .{ rect.min[0] + padding, rect.min[1] + padding }, .{ .color = t.colors.text_primary });
}

var global_command_list: ?*command_list.CommandList = null;

pub fn setGlobalCommandList(list: *command_list.CommandList) void {
    global_command_list = list;
}

pub fn clearGlobalCommandList() void {
    global_command_list = null;
}

fn imguiDrawRect(ctx: *DrawContext, rect: Rect, style: RectStyle) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    if (style.fill) |fill| {
        draw_list.addRectFilled(.{
            .pmin = rect.min,
            .pmax = rect.max,
            .col = zgui.colorConvertFloat4ToU32(fill),
        });
    }
    if (style.stroke) |stroke| {
        draw_list.addRect(.{
            .pmin = rect.min,
            .pmax = rect.max,
            .col = zgui.colorConvertFloat4ToU32(stroke),
            .thickness = style.thickness,
        });
    }
}

fn imguiDrawRoundedRect(ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    if (style.fill) |fill| {
        draw_list.addRectFilled(.{
            .pmin = rect.min,
            .pmax = rect.max,
            .col = zgui.colorConvertFloat4ToU32(fill),
            .rounding = radius,
        });
    }
    if (style.stroke) |stroke| {
        draw_list.addRect(.{
            .pmin = rect.min,
            .pmax = rect.max,
            .col = zgui.colorConvertFloat4ToU32(stroke),
            .rounding = radius,
            .thickness = style.thickness,
        });
    }
}

fn imguiDrawText(ctx: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    draw_list.addText(pos, zgui.colorConvertFloat4ToU32(style.color), "{s}", .{text});
}

fn imguiDrawLine(ctx: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    draw_list.addLine(.{
        .p1 = from,
        .p2 = to,
        .col = zgui.colorConvertFloat4ToU32(color),
        .thickness = width,
    });
}

fn imguiDrawImage(ctx: *DrawContext, texture: Texture, rect: Rect) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    const tex_ref: zgui.TextureRef = .{
        .tex_data = null,
        .tex_id = @enumFromInt(texture),
    };
    draw_list.addImage(tex_ref, .{
        .pmin = rect.min,
        .pmax = rect.max,
    });
}

fn imguiPushClip(ctx: *DrawContext, rect: Rect) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    draw_list.pushClipRect(.{
        .pmin = rect.min,
        .pmax = rect.max,
        .intersect_with_current = true,
    });
}

fn imguiPopClip(ctx: *DrawContext) void {
    _ = ctx;
    const draw_list = zgui.getWindowDrawList();
    draw_list.popClipRect();
}

fn nullDrawRect(ctx: *DrawContext, rect: Rect, style: RectStyle) void {
    _ = ctx;
    _ = rect;
    _ = style;
}

fn nullDrawRoundedRect(ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
    _ = ctx;
    _ = rect;
    _ = radius;
    _ = style;
}

fn nullDrawText(ctx: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void {
    _ = ctx;
    _ = text;
    _ = pos;
    _ = style;
}

fn nullDrawLine(ctx: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void {
    _ = ctx;
    _ = from;
    _ = to;
    _ = width;
    _ = color;
}

fn nullDrawImage(ctx: *DrawContext, texture: Texture, rect: Rect) void {
    _ = ctx;
    _ = texture;
    _ = rect;
}

fn nullPushClip(ctx: *DrawContext, rect: Rect) void {
    _ = ctx;
    _ = rect;
}

fn nullPopClip(ctx: *DrawContext) void {
    _ = ctx;
}

fn recordRectStyle(style: RectStyle) command_list.RectStyle {
    return .{
        .fill = style.fill,
        .stroke = style.stroke,
        .thickness = style.thickness,
    };
}

fn recordDrawRect(ctx: *DrawContext, rect: Rect, style: RectStyle) void {
    const list = ctx.command_list orelse return;
    list.pushRect(.{ .min = rect.min, .max = rect.max }, recordRectStyle(style));
}

fn recordDrawRoundedRect(ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
    const list = ctx.command_list orelse return;
    list.pushRoundedRect(.{ .min = rect.min, .max = rect.max }, radius, recordRectStyle(style));
}

fn recordDrawText(ctx: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void {
    const list = ctx.command_list orelse return;
    const role = font_system.currentRole();
    const role_cmd: command_list.FontRole = switch (role) {
        .body => .body,
        .heading => .heading,
        .title => .title,
    };
    const size_f = font_system.currentFontSize(ctx.theme);
    const size_px = if (size_f <= 1.0) 1 else @as(u16, @intCast(@min(@as(u32, @intFromFloat(size_f)), 65535)));
    list.pushText(text, pos, style.color, role_cmd, size_px);
}

fn recordDrawLine(ctx: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void {
    const list = ctx.command_list orelse return;
    list.pushLine(from, to, width, color);
}

fn recordDrawImage(ctx: *DrawContext, texture: Texture, rect: Rect) void {
    const list = ctx.command_list orelse return;
    list.pushImage(texture, .{ .min = rect.min, .max = rect.max });
}

fn recordPushClip(ctx: *DrawContext, rect: Rect) void {
    const list = ctx.command_list orelse return;
    list.pushClip(.{ .min = rect.min, .max = rect.max });
}

fn recordPopClip(ctx: *DrawContext) void {
    const list = ctx.command_list orelse return;
    list.popClip();
}

const imgui_render_backend = if (use_imgui)
    RenderBackend{
        .drawRect = imguiDrawRect,
        .drawRoundedRect = imguiDrawRoundedRect,
        .drawText = imguiDrawText,
        .drawLine = imguiDrawLine,
        .drawImage = imguiDrawImage,
        .pushClip = imguiPushClip,
        .popClip = imguiPopClip,
    }
else
    null_render_backend;

const record_render_backend = RenderBackend{
    .drawRect = recordDrawRect,
    .drawRoundedRect = recordDrawRoundedRect,
    .drawText = recordDrawText,
    .drawLine = recordDrawLine,
    .drawImage = recordDrawImage,
    .pushClip = recordPushClip,
    .popClip = recordPopClip,
};

const null_render_backend = RenderBackend{
    .drawRect = nullDrawRect,
    .drawRoundedRect = nullDrawRoundedRect,
    .drawText = nullDrawText,
    .drawLine = nullDrawLine,
    .drawImage = nullDrawImage,
    .pushClip = nullPushClip,
    .popClip = nullPopClip,
};

fn imguiIsHovered(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    const queue = input_router.getQueue();
    return rect.contains(queue.state.mouse_pos);
}

fn imguiIsClicked(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    const queue = input_router.getQueue();
    if (!rect.contains(queue.state.mouse_pos)) return false;
    for (queue.events.items) |evt| {
        if (evt == .mouse_down) {
            const md = evt.mouse_down;
            if (md.button == .left and rect.contains(md.pos)) return true;
        }
    }
    return false;
}

fn imguiIsDragging(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    const queue = input_router.getQueue();
    if (!queue.state.mouse_down_left or !rect.contains(queue.state.mouse_pos)) return false;
    for (queue.events.items) |evt| {
        if (evt == .mouse_move) return true;
    }
    return false;
}

fn nullIsHovered(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    _ = rect;
    return false;
}

fn nullIsClicked(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    _ = rect;
    return false;
}

fn nullIsDragging(ctx: *DrawContext, rect: Rect) bool {
    _ = ctx;
    _ = rect;
    return false;
}

const imgui_input_backend = if (use_imgui)
    InputBackend{
        .isHovered = imguiIsHovered,
        .isClicked = imguiIsClicked,
        .isDragging = imguiIsDragging,
    }
else
    null_input_backend;

const null_input_backend = InputBackend{
    .isHovered = nullIsHovered,
    .isClicked = nullIsClicked,
    .isDragging = nullIsDragging,
};
