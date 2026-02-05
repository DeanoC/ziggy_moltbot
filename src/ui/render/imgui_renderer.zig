const zgui = @import("zgui");
const draw_context = @import("../draw_context.zig");
const command_list = @import("command_list.zig");

pub const RenderFilter = struct {
    rect: bool = true,
    rounded_rect: bool = true,
    text: bool = true,
    line: bool = true,
    image: bool = true,
    clip: bool = true,

    pub fn all() RenderFilter {
        return .{};
    }

    pub fn textAndImages() RenderFilter {
        return .{
            .rect = false,
            .rounded_rect = false,
            .text = true,
            .line = false,
            .image = true,
            .clip = true,
        };
    }

    pub fn none() RenderFilter {
        return .{
            .rect = false,
            .rounded_rect = false,
            .text = false,
            .line = false,
            .image = false,
            .clip = false,
        };
    }
};

pub fn draw(list: *command_list.CommandList, filter: RenderFilter) void {
    const draw_list = zgui.getWindowDrawList();
    for (list.commands.items) |cmd| {
        switch (cmd) {
            .rect => |rect_cmd| {
                if (!filter.rect) continue;
                if (rect_cmd.style.fill) |fill| {
                    draw_list.addRectFilled(.{
                        .pmin = rect_cmd.rect.min,
                        .pmax = rect_cmd.rect.max,
                        .col = zgui.colorConvertFloat4ToU32(fill),
                    });
                }
                if (rect_cmd.style.stroke) |stroke| {
                    draw_list.addRect(.{
                        .pmin = rect_cmd.rect.min,
                        .pmax = rect_cmd.rect.max,
                        .col = zgui.colorConvertFloat4ToU32(stroke),
                        .thickness = rect_cmd.style.thickness,
                    });
                }
            },
            .rounded_rect => |rect_cmd| {
                if (!filter.rounded_rect) continue;
                if (rect_cmd.style.fill) |fill| {
                    draw_list.addRectFilled(.{
                        .pmin = rect_cmd.rect.min,
                        .pmax = rect_cmd.rect.max,
                        .col = zgui.colorConvertFloat4ToU32(fill),
                        .rounding = rect_cmd.radius,
                    });
                }
                if (rect_cmd.style.stroke) |stroke| {
                    draw_list.addRect(.{
                        .pmin = rect_cmd.rect.min,
                        .pmax = rect_cmd.rect.max,
                        .col = zgui.colorConvertFloat4ToU32(stroke),
                        .thickness = rect_cmd.style.thickness,
                        .rounding = rect_cmd.radius,
                    });
                }
            },
            .text => |text_cmd| {
                if (!filter.text) continue;
                const text = list.textSlice(text_cmd);
                if (text.len == 0) continue;
                draw_list.addText(text_cmd.pos, zgui.colorConvertFloat4ToU32(text_cmd.color), "{s}", .{text});
            },
            .line => |line_cmd| {
                if (!filter.line) continue;
                draw_list.addLine(.{
                    .p1 = line_cmd.from,
                    .p2 = line_cmd.to,
                    .col = zgui.colorConvertFloat4ToU32(line_cmd.color),
                    .thickness = line_cmd.width,
                });
            },
            .image => |image_cmd| {
                if (!filter.image) continue;
                const tex_ref: zgui.TextureRef = .{
                    .tex_data = null,
                    .tex_id = @enumFromInt(draw_context.DrawContext.textureFromId(image_cmd.texture)),
                };
                draw_list.addImage(tex_ref, .{
                    .pmin = image_cmd.rect.min,
                    .pmax = image_cmd.rect.max,
                });
            },
            .clip_push => |clip_cmd| {
                if (!filter.clip) continue;
                draw_list.pushClipRect(.{
                    .pmin = clip_cmd.rect.min,
                    .pmax = clip_cmd.rect.max,
                    .intersect_with_current = true,
                });
            },
            .clip_pop => {
                if (!filter.clip) continue;
                draw_list.popClipRect();
            },
        }
    }
}
