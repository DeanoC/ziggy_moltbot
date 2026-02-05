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

pub const RoundedRectCmd = struct {
    rect: Rect,
    radius: f32,
    style: RectStyle,
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
};

pub const ClipCmd = struct {
    rect: Rect,
};

pub const Command = union(enum) {
    rect: RectCmd,
    rounded_rect: RoundedRectCmd,
    text: TextCmd,
    line: LineCmd,
    image: ImageCmd,
    clip_push: ClipCmd,
    clip_pop: void,
};

pub const CommandList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    text_storage: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandList {
        return .{
            .allocator = allocator,
            .commands = .empty,
            .text_storage = .empty,
        };
    }

    pub fn deinit(self: *CommandList) void {
        self.commands.deinit(self.allocator);
        self.text_storage.deinit(self.allocator);
    }

    pub fn clear(self: *CommandList) void {
        self.commands.clearRetainingCapacity();
        self.text_storage.clearRetainingCapacity();
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

    pub fn pushRoundedRect(self: *CommandList, rect: Rect, radius: f32, style: RectStyle) void {
        _ = self.commands.append(self.allocator, .{
            .rounded_rect = .{ .rect = rect, .radius = radius, .style = style },
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
