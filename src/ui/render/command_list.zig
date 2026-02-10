const std = @import("std");

pub const Vec2 = [2]f32;
pub const Color = [4]f32;
pub const Texture = u64;

pub const FontRole = enum {
    body,
    heading,
    title,
};

pub const Rect = struct {
    min: Vec2,
    max: Vec2,
};

pub const RectStyle = struct {
    fill: ?Color = null,
    stroke: ?Color = null,
    thickness: f32 = 1.0,
};

pub const RectCmd = struct {
    rect: Rect,
    style: RectStyle,
};

pub const Gradient4 = struct {
    tl: Color,
    tr: Color,
    bl: Color,
    br: Color,
};

pub const RectGradientCmd = struct {
    rect: Rect,
    colors: Gradient4,
};

pub const RoundedRectCmd = struct {
    rect: Rect,
    radius: f32,
    style: RectStyle,
};

pub const RoundedRectGradientCmd = struct {
    rect: Rect,
    radius: f32,
    colors: Gradient4,
};

pub const SoftFxKind = enum(u8) {
    // Filled rounded rect with a soft edge (used for drop shadows).
    fill_soft = 0,
    // Soft stroke around rounded rect edge (used for glow/focus effects).
    stroke_soft = 1,
};

pub const BlendMode = enum(u8) {
    alpha = 0,
    additive = 1,
};

pub const ImageSampling = enum(u8) {
    linear = 0,
    nearest = 1,
};

pub const Meta = struct {
    image_sampling: ImageSampling = .linear,
    pixel_snap_textured: bool = false,
};

pub const SoftRoundedRectCmd = struct {
    // The quad we render (usually expanded to cover blur).
    draw_rect: Rect,
    // The rounded-rect boundary the SDF is computed against.
    rect: Rect,
    radius: f32,
    kind: SoftFxKind,
    thickness: f32 = 0.0,
    blur_px: f32 = 0.0,
    falloff_exp: f32 = 1.0,
    color: Color,
    respect_clip: bool = true,
    blend: BlendMode = .alpha,
};

pub const TextCmd = struct {
    text_offset: usize,
    text_len: usize,
    pos: Vec2,
    color: Color,
    role: FontRole,
    size_px: u16,
};

pub const LineCmd = struct {
    from: Vec2,
    to: Vec2,
    width: f32,
    color: Color,
};

pub const ImageCmd = struct {
    texture: Texture,
    rect: Rect,
    // Texture coordinates. Values outside 0..1 only work when the sampler is set to repeat.
    uv0: Vec2 = .{ 0.0, 0.0 },
    uv1: Vec2 = .{ 1.0, 1.0 },
    tint: Color = .{ 1.0, 1.0, 1.0, 1.0 },
    repeat: bool = false,
};

pub const NineSliceCmd = struct {
    texture: Texture,
    rect: Rect,
    // Pixel slice sizes: left, top, right, bottom (source texture px, applied to destination).
    slices_px: [4]f32,
    tint: Color,
    draw_center: bool = true,
    tile_center: bool = false,
    tile_center_x: bool = true,
    tile_center_y: bool = true,
    // When tiling the center, controls where any partial tile remainder lands:
    // false = remainder on right/bottom (start-anchored), true = remainder on left/top (end-anchored).
    tile_anchor_end: bool = false,
};

pub const ClipCmd = struct {
    rect: Rect,
};

pub const Command = union(enum) {
    rect: RectCmd,
    rect_gradient: RectGradientCmd,
    rounded_rect: RoundedRectCmd,
    rounded_rect_gradient: RoundedRectGradientCmd,
    soft_rounded_rect: SoftRoundedRectCmd,
    text: TextCmd,
    line: LineCmd,
    image: ImageCmd,
    nine_slice: NineSliceCmd,
    clip_push: ClipCmd,
    clip_pop: void,
};

pub const CommandList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    text_storage: std.ArrayList(u8) = .empty,
    meta: Meta = .{},

    pub fn init(allocator: std.mem.Allocator) CommandList {
        return .{
            .allocator = allocator,
            .commands = .empty,
            .text_storage = .empty,
            .meta = .{},
        };
    }

    pub fn deinit(self: *CommandList) void {
        self.commands.deinit(self.allocator);
        self.text_storage.deinit(self.allocator);
    }

    pub fn clear(self: *CommandList) void {
        self.commands.clearRetainingCapacity();
        self.text_storage.clearRetainingCapacity();
        self.meta = .{};
    }

    fn storeText(self: *CommandList, text: []const u8) TextCmd {
        const start = self.text_storage.items.len;
        if (text.len > 0) {
            if (self.text_storage.appendSlice(self.allocator, text)) |_| {
                return .{
                    .text_offset = start,
                    .text_len = text.len,
                    .pos = .{ 0.0, 0.0 },
                    .color = .{ 1.0, 1.0, 1.0, 1.0 },
                    .role = .body,
                    .size_px = 0,
                };
            } else |_| {}
        }
        return .{
            .text_offset = 0,
            .text_len = 0,
            .pos = .{ 0.0, 0.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
            .role = .body,
            .size_px = 0,
        };
    }

    pub fn pushRect(self: *CommandList, rect: Rect, style: RectStyle) void {
        _ = self.commands.append(self.allocator, .{ .rect = .{ .rect = rect, .style = style } }) catch {};
    }

    pub fn pushRectGradient(self: *CommandList, rect: Rect, colors: Gradient4) void {
        _ = self.commands.append(self.allocator, .{ .rect_gradient = .{ .rect = rect, .colors = colors } }) catch {};
    }

    pub fn pushRoundedRect(self: *CommandList, rect: Rect, radius: f32, style: RectStyle) void {
        _ = self.commands.append(self.allocator, .{
            .rounded_rect = .{ .rect = rect, .radius = radius, .style = style },
        }) catch {};
    }

    pub fn pushRoundedRectGradient(self: *CommandList, rect: Rect, radius: f32, colors: Gradient4) void {
        _ = self.commands.append(self.allocator, .{
            .rounded_rect_gradient = .{ .rect = rect, .radius = radius, .colors = colors },
        }) catch {};
    }

    pub fn pushSoftRoundedRect(
        self: *CommandList,
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
        _ = self.commands.append(self.allocator, .{
            .soft_rounded_rect = .{
                .draw_rect = draw_rect,
                .rect = rect,
                .radius = radius,
                .kind = kind,
                .thickness = thickness,
                .blur_px = blur_px,
                .falloff_exp = falloff_exp,
                .color = color,
                .respect_clip = respect_clip,
                .blend = blend,
            },
        }) catch {};
    }

    pub fn pushText(self: *CommandList, text: []const u8, pos: Vec2, color: Color, role: FontRole, size_px: u16) void {
        var stored = self.storeText(text);
        stored.pos = pos;
        stored.color = color;
        stored.role = role;
        stored.size_px = size_px;
        _ = self.commands.append(self.allocator, .{
            .text = stored,
        }) catch {};
    }

    pub fn pushLine(self: *CommandList, from: Vec2, to: Vec2, width: f32, color: Color) void {
        _ = self.commands.append(self.allocator, .{
            .line = .{ .from = from, .to = to, .width = width, .color = color },
        }) catch {};
    }

    pub fn pushImage(self: *CommandList, texture: Texture, rect: Rect) void {
        _ = self.commands.append(self.allocator, .{ .image = .{ .texture = texture, .rect = rect } }) catch {};
    }

    pub fn pushImageUv(
        self: *CommandList,
        texture: Texture,
        rect: Rect,
        uv0: Vec2,
        uv1: Vec2,
        tint: Color,
        repeat: bool,
    ) void {
        _ = self.commands.append(self.allocator, .{
            .image = .{
                .texture = texture,
                .rect = rect,
                .uv0 = uv0,
                .uv1 = uv1,
                .tint = tint,
                .repeat = repeat,
            },
        }) catch {};
    }

    pub fn pushNineSlice(self: *CommandList, texture: Texture, rect: Rect, slices_px: [4]f32, tint: Color) void {
        _ = self.commands.append(self.allocator, .{
            .nine_slice = .{
                .texture = texture,
                .rect = rect,
                .slices_px = slices_px,
                .tint = tint,
                .draw_center = true,
                .tile_center = false,
                .tile_center_x = true,
                .tile_center_y = true,
                .tile_anchor_end = false,
            },
        }) catch {};
    }

    pub fn pushNineSliceEx(
        self: *CommandList,
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
        _ = self.commands.append(self.allocator, .{
            .nine_slice = .{
                .texture = texture,
                .rect = rect,
                .slices_px = slices_px,
                .tint = tint,
                .draw_center = draw_center,
                .tile_center = tile_center,
                .tile_center_x = tile_center_x,
                .tile_center_y = tile_center_y,
                .tile_anchor_end = tile_anchor_end,
            },
        }) catch {};
    }

    pub fn pushClip(self: *CommandList, rect: Rect) void {
        _ = self.commands.append(self.allocator, .{ .clip_push = .{ .rect = rect } }) catch {};
    }

    pub fn popClip(self: *CommandList) void {
        _ = self.commands.append(self.allocator, .{ .clip_pop = {} }) catch {};
    }

    pub fn textSlice(self: *const CommandList, cmd: TextCmd) []const u8 {
        if (cmd.text_len == 0) return "";
        if (cmd.text_offset >= self.text_storage.items.len) return "";
        const end = cmd.text_offset + cmd.text_len;
        if (end > self.text_storage.items.len) return "";
        return self.text_storage.items[cmd.text_offset..end];
    }
};
