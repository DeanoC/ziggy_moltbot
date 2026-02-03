const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");

pub const Vec2 = [2]f32;
pub const Color = [4]f32;
pub const Texture = zgui.TextureRef;

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

    pub fn init(
        allocator: std.mem.Allocator,
        backend: Backend,
        theme_ref: *const theme.Theme,
        viewport: Rect,
    ) DrawContext {
        return .{
            .backend = backend,
            .theme = theme_ref,
            .viewport = viewport,
            .clip_stack = .empty,
            .allocator = allocator,
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

    pub fn drawRect(self: *DrawContext, rect: Rect, style: RectStyle) void {
        switch (self.backend) {
            .imgui => {
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
            },
            .direct => {},
        }
    }

    pub fn drawRoundedRect(self: *DrawContext, rect: Rect, radius: f32, style: RectStyle) void {
        switch (self.backend) {
            .imgui => {
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
            },
            .direct => {},
        }
    }

    pub fn drawText(self: *DrawContext, text: []const u8, pos: Vec2, style: TextStyle) void {
        switch (self.backend) {
            .imgui => {
                const draw_list = zgui.getWindowDrawList();
                draw_list.addText(pos, zgui.colorConvertFloat4ToU32(style.color), "{s}", .{text});
            },
            .direct => {},
        }
    }

    pub fn drawLine(self: *DrawContext, from: Vec2, to: Vec2, width: f32, color: Color) void {
        switch (self.backend) {
            .imgui => {
                const draw_list = zgui.getWindowDrawList();
                draw_list.addLine(.{
                    .p1 = from,
                    .p2 = to,
                    .col = zgui.colorConvertFloat4ToU32(color),
                    .thickness = width,
                });
            },
            .direct => {},
        }
    }

    pub fn drawImage(self: *DrawContext, texture: Texture, rect: Rect) void {
        switch (self.backend) {
            .imgui => {
                const draw_list = zgui.getWindowDrawList();
                draw_list.addImage(texture, .{
                    .pmin = rect.min,
                    .pmax = rect.max,
                });
            },
            .direct => {},
        }
    }

    pub fn pushClip(self: *DrawContext, rect: Rect) void {
        switch (self.backend) {
            .imgui => {
                const draw_list = zgui.getWindowDrawList();
                draw_list.pushClipRect(.{
                    .pmin = rect.min,
                    .pmax = rect.max,
                    .intersect_with_current = true,
                });
            },
            .direct => {},
        }
        _ = self.clip_stack.append(self.allocator, rect) catch {};
    }

    pub fn popClip(self: *DrawContext) void {
        if (self.clip_stack.items.len == 0) return;
        _ = self.clip_stack.pop();
        switch (self.backend) {
            .imgui => {
                const draw_list = zgui.getWindowDrawList();
                draw_list.popClipRect();
            },
            .direct => {},
        }
    }

    pub fn isHovered(self: *DrawContext, rect: Rect) bool {
        _ = self;
        return rect.contains(zgui.getMousePos());
    }

    pub fn isClicked(self: *DrawContext, rect: Rect) bool {
        return self.isHovered(rect) and zgui.isMouseClicked(.left);
    }

    pub fn isDragging(self: *DrawContext, rect: Rect) bool {
        return self.isHovered(rect) and zgui.isMouseDragging(.left, 0.0);
    }
};
