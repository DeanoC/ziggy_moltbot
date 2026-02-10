const std = @import("std");

const input_router = @import("input/input_router.zig");
const command_list = @import("render/command_list.zig");
const theme = @import("theme.zig");
const text_metrics = @import("text_metrics.zig");
const font_system = @import("font_system.zig");

pub const Vec2 = [2]f32;
pub const Color = [4]f32;
pub const Texture = u64;
pub const TextMetrics = text_metrics.Metrics;

pub const Gradient4 = struct {
    tl: Color,
    tr: Color,
    bl: Color,
    br: Color,
};

pub const SoftFxKind = enum(u8) {
    fill_soft = 0,
    stroke_soft = 1,
};

pub const BlendMode = enum(u8) {
    alpha = 0,
    additive = 1,
};

pub const RenderBackend = struct {
    drawRect: *const fn (ctx: *DrawContext, rect: Rect, style: RectStyle) void,
    drawRectGradient: *const fn (ctx: *DrawContext, rect: Rect, colors: Gradient4) void,
    drawRoundedRect: *const fn (ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void,
    drawRoundedRectGradient: *const fn (ctx: *DrawContext, rect: Rect, radius: f32, colors: Gradient4) void,
    drawSoftRoundedRect: *const fn (
        ctx: *DrawContext,
        draw_rect: Rect,
        rect: Rect,
        radius: f32,
        kind: SoftFxKind,
        thickness: f32,
        blur_px: f32,
        falloff_exp: f32,
        color: Color,
        respect_clip: bool,
        blend: BlendMode,
    ) void,
    drawText: *const fn (ctx: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void,
    drawLine: *const fn (ctx: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void,
    drawImage: *const fn (ctx: *DrawContext, texture: Texture, rect: Rect) void,
    drawImageUv: *const fn (ctx: *DrawContext, texture: Texture, rect: Rect, uv0: Vec2, uv1: Vec2, tint: Color, repeat: bool) void,
    drawNineSlice: *const fn (
        ctx: *DrawContext,
        texture: Texture,
        rect: Rect,
        slices_px: [4]f32,
        tint: Color,
        draw_center: bool,
        tile_center: bool,
        tile_center_x: bool,
        tile_center_y: bool,
        tile_anchor_end: bool,
    ) void,
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

pub const DirectBackend = struct {};

pub const Backend = union(enum) {
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
        _ = backend;
        font_system.setCurrentTheme(theme_ref);

        var render_backend: RenderBackend = null_render_backend;
        var list_ptr: ?*command_list.CommandList = null;
        if (global_command_list) |list| {
            render_backend = record_render_backend;
            list_ptr = list;
        }

        return .{
            .backend = .{ .direct = .{} },
            .theme = theme_ref,
            .viewport = viewport,
            .clip_stack = .empty,
            .allocator = allocator,
            .text_metrics = text_metrics.default,
            .render = render_backend,
            .input = basic_input_backend,
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
        font_system.setCurrentTheme(theme_ref);
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

    pub fn drawRectGradient(self: *DrawContext, rect: Rect, colors: Gradient4) void {
        self.render.drawRectGradient(self, rect, colors);
    }

    pub fn drawRoundedRect(self: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
        self.render.drawRoundedRect(self, rect, radius, style);
    }

    pub fn drawRoundedRectGradient(self: *DrawContext, rect: Rect, radius: f32, colors: Gradient4) void {
        self.render.drawRoundedRectGradient(self, rect, radius, colors);
    }

    pub fn drawSoftRoundedRect(
        self: *DrawContext,
        draw_rect: Rect,
        rect: Rect,
        radius: f32,
        kind: SoftFxKind,
        thickness: f32,
        blur_px: f32,
        falloff_exp: f32,
        color: Color,
        respect_clip: bool,
        blend: BlendMode,
    ) void {
        self.render.drawSoftRoundedRect(self, draw_rect, rect, radius, kind, thickness, blur_px, falloff_exp, color, respect_clip, blend);
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

    pub fn drawImageUv(self: *DrawContext, texture: Texture, rect: Rect, uv0: Vec2, uv1: Vec2, tint: Color, repeat: bool) void {
        self.render.drawImageUv(self, texture, rect, uv0, uv1, tint, repeat);
    }

    pub fn drawNineSlice(
        self: *DrawContext,
        texture: Texture,
        rect: Rect,
        slices_px: [4]f32,
        tint: Color,
        draw_center: bool,
        tile_center: bool,
        tile_center_x: bool,
        tile_center_y: bool,
        tile_anchor_end: bool,
    ) void {
        self.render.drawNineSlice(self, texture, rect, slices_px, tint, draw_center, tile_center, tile_center_x, tile_center_y, tile_anchor_end);
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
        .fill = .{ t.colors.surface[0], t.colors.surface[1], t.colors.surface[2], 0.95 },
        .stroke = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], 0.8 },
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

fn nullDrawRect(_: *DrawContext, _: Rect, _: RectStyle) void {}
fn nullDrawRectGradient(_: *DrawContext, _: Rect, _: Gradient4) void {}
fn nullDrawRoundedRect(_: *DrawContext, _: Rect, _: f32, _: RectStyle) void {}
fn nullDrawRoundedRectGradient(_: *DrawContext, _: Rect, _: f32, _: Gradient4) void {}
fn nullDrawSoftRoundedRect(_: *DrawContext, _: Rect, _: Rect, _: f32, _: SoftFxKind, _: f32, _: f32, _: f32, _: Color, _: bool, _: BlendMode) void {}
fn nullDrawText(_: *DrawContext, _: []const u8, _: Vec2, _: TextStyle) void {}
fn nullDrawLine(_: *DrawContext, _: Vec2, _: Vec2, _: f32, _: Color) void {}
fn nullDrawImage(_: *DrawContext, _: Texture, _: Rect) void {}
fn nullDrawImageUv(_: *DrawContext, _: Texture, _: Rect, _: Vec2, _: Vec2, _: Color, _: bool) void {}
fn nullDrawNineSlice(_: *DrawContext, _: Texture, _: Rect, _: [4]f32, _: Color, _: bool, _: bool, _: bool, _: bool, _: bool) void {}
fn nullPushClip(_: *DrawContext, _: Rect) void {}
fn nullPopClip(_: *DrawContext) void {}

const null_render_backend = RenderBackend{
    .drawRect = nullDrawRect,
    .drawRectGradient = nullDrawRectGradient,
    .drawRoundedRect = nullDrawRoundedRect,
    .drawRoundedRectGradient = nullDrawRoundedRectGradient,
    .drawSoftRoundedRect = nullDrawSoftRoundedRect,
    .drawText = nullDrawText,
    .drawLine = nullDrawLine,
    .drawImage = nullDrawImage,
    .drawImageUv = nullDrawImageUv,
    .drawNineSlice = nullDrawNineSlice,
    .pushClip = nullPushClip,
    .popClip = nullPopClip,
};

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

fn recordDrawRectGradient(ctx: *DrawContext, rect: Rect, colors: Gradient4) void {
    const list = ctx.command_list orelse return;
    list.pushRectGradient(.{ .min = rect.min, .max = rect.max }, .{
        .tl = colors.tl,
        .tr = colors.tr,
        .bl = colors.bl,
        .br = colors.br,
    });
}

fn recordDrawRoundedRect(ctx: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
    const list = ctx.command_list orelse return;
    list.pushRoundedRect(.{ .min = rect.min, .max = rect.max }, radius, recordRectStyle(style));
}

fn recordDrawRoundedRectGradient(ctx: *DrawContext, rect: Rect, radius: f32, colors: Gradient4) void {
    const list = ctx.command_list orelse return;
    list.pushRoundedRectGradient(.{ .min = rect.min, .max = rect.max }, radius, .{
        .tl = colors.tl,
        .tr = colors.tr,
        .bl = colors.bl,
        .br = colors.br,
    });
}

fn recordDrawSoftRoundedRect(
    ctx: *DrawContext,
    draw_rect: Rect,
    rect: Rect,
    radius: f32,
    kind: SoftFxKind,
    thickness: f32,
    blur_px: f32,
    falloff_exp: f32,
    color: Color,
    respect_clip: bool,
    blend: BlendMode,
) void {
    const list = ctx.command_list orelse return;
    const cmd_kind: command_list.SoftFxKind = switch (kind) {
        .fill_soft => .fill_soft,
        .stroke_soft => .stroke_soft,
    };
    const cmd_blend: command_list.BlendMode = switch (blend) {
        .alpha => .alpha,
        .additive => .additive,
    };
    list.pushSoftRoundedRect(
        .{ .min = draw_rect.min, .max = draw_rect.max },
        .{ .min = rect.min, .max = rect.max },
        radius,
        cmd_kind,
        thickness,
        blur_px,
        falloff_exp,
        color,
        respect_clip,
        cmd_blend,
    );
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

fn recordDrawImageUv(ctx: *DrawContext, texture: Texture, rect: Rect, uv0: Vec2, uv1: Vec2, tint: Color, repeat: bool) void {
    const list = ctx.command_list orelse return;
    list.pushImageUv(texture, .{ .min = rect.min, .max = rect.max }, uv0, uv1, tint, repeat);
}

fn recordDrawNineSlice(
    ctx: *DrawContext,
    texture: Texture,
    rect: Rect,
    slices_px: [4]f32,
    tint: Color,
    draw_center: bool,
    tile_center: bool,
    tile_center_x: bool,
    tile_center_y: bool,
    tile_anchor_end: bool,
) void {
    const list = ctx.command_list orelse return;
    list.pushNineSliceEx(texture, .{ .min = rect.min, .max = rect.max }, slices_px, tint, draw_center, tile_center, tile_center_x, tile_center_y, tile_anchor_end);
}

fn recordPushClip(ctx: *DrawContext, rect: Rect) void {
    const list = ctx.command_list orelse return;
    list.pushClip(.{ .min = rect.min, .max = rect.max });
}

fn recordPopClip(ctx: *DrawContext) void {
    const list = ctx.command_list orelse return;
    list.popClip();
}

const record_render_backend = RenderBackend{
    .drawRect = recordDrawRect,
    .drawRectGradient = recordDrawRectGradient,
    .drawRoundedRect = recordDrawRoundedRect,
    .drawRoundedRectGradient = recordDrawRoundedRectGradient,
    .drawSoftRoundedRect = recordDrawSoftRoundedRect,
    .drawText = recordDrawText,
    .drawLine = recordDrawLine,
    .drawImage = recordDrawImage,
    .drawImageUv = recordDrawImageUv,
    .drawNineSlice = recordDrawNineSlice,
    .pushClip = recordPushClip,
    .popClip = recordPopClip,
};

fn basicIsHovered(_: *DrawContext, rect: Rect) bool {
    const queue = input_router.getQueue();
    return rect.contains(queue.state.mouse_pos);
}

fn basicIsClicked(_: *DrawContext, rect: Rect) bool {
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

fn basicIsDragging(_: *DrawContext, rect: Rect) bool {
    const queue = input_router.getQueue();
    if (!queue.state.mouse_down_left or !rect.contains(queue.state.mouse_pos)) return false;
    for (queue.events.items) |evt| {
        if (evt == .mouse_move) return true;
    }
    return false;
}

const basic_input_backend = InputBackend{
    .isHovered = basicIsHovered,
    .isClicked = basicIsClicked,
    .isDragging = basicIsDragging,
};
