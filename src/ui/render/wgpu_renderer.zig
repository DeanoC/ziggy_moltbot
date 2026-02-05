const std = @import("std");
const zgpu = @import("zgpu");
const command_list = @import("command_list.zig");
const image_cache = @import("../image_cache.zig");
const font_system = @import("../font_system.zig");
const logger = @import("../../utils/logger.zig");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const Vec2 = command_list.Vec2;
const Color = command_list.Color;
const Rect = command_list.Rect;
const FontRole = command_list.FontRole;

const ShapeVertex = struct {
    pos: Vec2,
    color: [4]f32,
};

const TexVertex = struct {
    pos: Vec2,
    uv: Vec2,
    color: [4]f32,
};

const Scissor = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const PipelineKind = enum { shape, textured };

const RenderItem = struct {
    kind: PipelineKind,
    first_vertex: u32,
    vertex_count: u32,
    scissor: Scissor,
    bind_group: ?zgpu.wgpu.BindGroup = null,
};

const Uniforms = extern struct {
    screen_size: [2]f32,
    _pad: [2]f32 = .{ 0.0, 0.0 },
};

const GlyphInfo = struct {
    page_index: u16,
    size: Vec2,
    bearing: Vec2,
    advance: f32,
    uv_min: Vec2,
    uv_max: Vec2,
    visible: bool,
    color_glyph: bool,
};

fn isEmojiCodepoint(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF);
}

const AtlasPage = struct {
    texture: zgpu.wgpu.Texture,
    view: zgpu.wgpu.TextureView,
    sampler: zgpu.wgpu.Sampler,
    bind_group: zgpu.wgpu.BindGroup,
    width: u32,
    height: u32,
    next_x: u32,
    next_y: u32,
    row_height: u32,
};

const FontKey = struct {
    role: FontRole,
    size_px: u16,
};

const FontAtlas = struct {
    role: FontRole,
    size_px: u16,
    face_primary: c.FT_Face,
    face_emoji_color: ?c.FT_Face,
    face_emoji_mono: ?c.FT_Face,
    emoji_scale_color: f32,
    emoji_scale_mono: f32,
    line_height: f32,
    ascent: f32,
    pages: std.ArrayList(AtlasPage) = .empty,
    glyphs: std.AutoHashMap(u21, GlyphInfo),

    fn deinit(self: *FontAtlas, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| {
            page.bind_group.release();
            page.sampler.release();
            page.view.release();
            page.texture.release();
        }
        self.pages.deinit(allocator);
        self.glyphs.deinit();
        _ = c.FT_Done_Face(self.face_primary);
        if (self.face_emoji_color) |face| {
            _ = c.FT_Done_Face(face);
        }
        if (self.face_emoji_mono) |face| {
            _ = c.FT_Done_Face(face);
        }
    }
};

const ImageTexture = struct {
    texture: zgpu.wgpu.Texture,
    view: zgpu.wgpu.TextureView,
    sampler: zgpu.wgpu.Sampler,
    bind_group: zgpu.wgpu.BindGroup,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: zgpu.wgpu.Device,
    queue: zgpu.wgpu.Queue,
    uniform_buffer: zgpu.wgpu.Buffer,
    shape_pipeline: zgpu.wgpu.RenderPipeline,
    shape_bind_group_layout: zgpu.wgpu.BindGroupLayout,
    shape_bind_group: zgpu.wgpu.BindGroup,
    texture_pipeline: zgpu.wgpu.RenderPipeline,
    texture_bind_group_layout: zgpu.wgpu.BindGroupLayout,
    shape_vertex_buffer: zgpu.wgpu.Buffer,
    shape_vertex_capacity: usize,
    textured_vertex_buffer: zgpu.wgpu.Buffer,
    textured_vertex_capacity: usize,
    shape_vertices: std.ArrayList(ShapeVertex) = .empty,
    textured_vertices: std.ArrayList(TexVertex) = .empty,
    render_items: std.ArrayList(RenderItem) = .empty,
    scratch_points: std.ArrayList(Vec2) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,
    font_atlases: std.AutoHashMap(FontKey, FontAtlas),
    image_textures: std.AutoHashMap(u32, ImageTexture),
    screen_width: u32 = 1,
    screen_height: u32 = 1,
    ft_ready: bool = false,
    ft_lib: c.FT_Library = undefined,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) !Renderer {
        const device = gctx.device;
        const queue = gctx.queue;
        const swapchain_format = gctx.swapchain_descriptor.format;

        const uniform_buffer = device.createBuffer(.{
            .label = "ui.uniforms",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(Uniforms),
        });

        const shape_bgl_entries = [_]zgpu.wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true },
                .buffer = .{
                    .binding_type = .uniform,
                    .has_dynamic_offset = .false,
                    .min_binding_size = @sizeOf(Uniforms),
                },
            },
        };
        const shape_bind_group_layout = device.createBindGroupLayout(.{
            .label = "ui.shape_bgl",
            .entry_count = shape_bgl_entries.len,
            .entries = &shape_bgl_entries,
        });
        const shape_bind_group_entries = [_]zgpu.wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = uniform_buffer,
                .offset = 0,
                .size = @sizeOf(Uniforms),
            },
        };
        const shape_bind_group = device.createBindGroup(.{
            .label = "ui.shape_bg",
            .layout = shape_bind_group_layout,
            .entry_count = shape_bind_group_entries.len,
            .entries = &shape_bind_group_entries,
        });

        const texture_bgl_entries = [_]zgpu.wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true },
                .buffer = .{
                    .binding_type = .uniform,
                    .has_dynamic_offset = .false,
                    .min_binding_size = @sizeOf(Uniforms),
                },
            },
            .{
                .binding = 1,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .filtering },
            },
            .{
                .binding = 2,
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d, .multisampled = false },
            },
        };
        const texture_bind_group_layout = device.createBindGroupLayout(.{
            .label = "ui.texture_bgl",
            .entry_count = texture_bgl_entries.len,
            .entries = &texture_bgl_entries,
        });

        const shape_pipeline_layout = device.createPipelineLayout(.{
            .label = "ui.shape_pipeline_layout",
            .bind_group_layout_count = 1,
            .bind_group_layouts = &[_]zgpu.wgpu.BindGroupLayout{shape_bind_group_layout},
        });
        defer shape_pipeline_layout.release();

        const texture_pipeline_layout = device.createPipelineLayout(.{
            .label = "ui.texture_pipeline_layout",
            .bind_group_layout_count = 1,
            .bind_group_layouts = &[_]zgpu.wgpu.BindGroupLayout{texture_bind_group_layout},
        });
        defer texture_pipeline_layout.release();

        const shape_shader_src: [:0]const u8 =
            \\struct Uniforms {
            \\    screen_size: vec2<f32>,
            \\}
            \\
            \\@group(0) @binding(0) var<uniform> u: Uniforms;
            \\
            \\struct VertexInput {
            \\    @location(0) pos: vec2<f32>,
            \\    @location(1) color: vec4<f32>,
            \\};
            \\
            \\struct VertexOutput {
            \\    @builtin(position) pos: vec4<f32>,
            \\    @location(0) color: vec4<f32>,
            \\};
            \\
            \\@vertex
            \\fn vs_main(input: VertexInput) -> VertexOutput {
            \\    var out: VertexOutput;
            \\    let ndc_x = (input.pos.x / u.screen_size.x) * 2.0 - 1.0;
            \\    let ndc_y = 1.0 - (input.pos.y / u.screen_size.y) * 2.0;
            \\    out.pos = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
            \\    out.color = input.color;
            \\    return out;
            \\}
            \\
            \\@fragment
            \\fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
            \\    return input.color;
            \\}
        ;
        const shape_shader = zgpu.createWgslShaderModule(device, shape_shader_src, "ui.shape.wgsl");
        defer shape_shader.release();

        const textured_shader_src: [:0]const u8 =
            \\struct Uniforms {
            \\    screen_size: vec2<f32>,
            \\}
            \\
            \\@group(0) @binding(0) var<uniform> u: Uniforms;
            \\@group(0) @binding(1) var tex_sampler: sampler;
            \\@group(0) @binding(2) var tex: texture_2d<f32>;
            \\
            \\struct VertexInput {
            \\    @location(0) pos: vec2<f32>,
            \\    @location(1) uv: vec2<f32>,
            \\    @location(2) color: vec4<f32>,
            \\};
            \\
            \\struct VertexOutput {
            \\    @builtin(position) pos: vec4<f32>,
            \\    @location(0) uv: vec2<f32>,
            \\    @location(1) color: vec4<f32>,
            \\};
            \\
            \\@vertex
            \\fn vs_main(input: VertexInput) -> VertexOutput {
            \\    var out: VertexOutput;
            \\    let ndc_x = (input.pos.x / u.screen_size.x) * 2.0 - 1.0;
            \\    let ndc_y = 1.0 - (input.pos.y / u.screen_size.y) * 2.0;
            \\    out.pos = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
            \\    out.uv = input.uv;
            \\    out.color = input.color;
            \\    return out;
            \\}
            \\
            \\@fragment
            \\fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
            \\    let texel = textureSample(tex, tex_sampler, input.uv);
            \\    return texel * input.color;
            \\}
        ;
        const textured_shader = zgpu.createWgslShaderModule(device, textured_shader_src, "ui.texture.wgsl");
        defer textured_shader.release();

        const shape_vertex_attrs = [_]zgpu.wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = @sizeOf(Vec2), .shader_location = 1 },
        };
        const shape_vertex_buffers = [_]zgpu.wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(ShapeVertex),
            .attribute_count = shape_vertex_attrs.len,
            .attributes = &shape_vertex_attrs,
        }};

        const textured_vertex_attrs = [_]zgpu.wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = @sizeOf(Vec2), .shader_location = 1 },
            .{ .format = .float32x4, .offset = @sizeOf(Vec2) * 2, .shader_location = 2 },
        };
        const textured_vertex_buffers = [_]zgpu.wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(TexVertex),
            .attribute_count = textured_vertex_attrs.len,
            .attributes = &textured_vertex_attrs,
        }};

        const blend = zgpu.wgpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
            },
        };

        const color_target = [_]zgpu.wgpu.ColorTargetState{.{
            .format = swapchain_format,
            .blend = &blend,
            .write_mask = zgpu.wgpu.ColorWriteMask.all,
        }};

        const shape_pipeline = device.createRenderPipeline(.{
            .label = "ui.shape.pipeline",
            .layout = shape_pipeline_layout,
            .vertex = .{
                .module = shape_shader,
                .entry_point = "vs_main",
                .buffer_count = shape_vertex_buffers.len,
                .buffers = &shape_vertex_buffers,
            },
            .fragment = &.{
                .module = shape_shader,
                .entry_point = "fs_main",
                .target_count = color_target.len,
                .targets = &color_target,
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        });

        const texture_pipeline = device.createRenderPipeline(.{
            .label = "ui.texture.pipeline",
            .layout = texture_pipeline_layout,
            .vertex = .{
                .module = textured_shader,
                .entry_point = "vs_main",
                .buffer_count = textured_vertex_buffers.len,
                .buffers = &textured_vertex_buffers,
            },
            .fragment = &.{
                .module = textured_shader,
                .entry_point = "fs_main",
                .target_count = color_target.len,
                .targets = &color_target,
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        });

        const initial_capacity: usize = 4096;
        const shape_vertex_buffer = device.createBuffer(.{
            .label = "ui.shape.vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = initial_capacity * @sizeOf(ShapeVertex),
        });
        const textured_vertex_buffer = device.createBuffer(.{
            .label = "ui.texture.vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = initial_capacity * @sizeOf(TexVertex),
        });

        return .{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .uniform_buffer = uniform_buffer,
            .shape_pipeline = shape_pipeline,
            .shape_bind_group_layout = shape_bind_group_layout,
            .shape_bind_group = shape_bind_group,
            .texture_pipeline = texture_pipeline,
            .texture_bind_group_layout = texture_bind_group_layout,
            .shape_vertex_buffer = shape_vertex_buffer,
            .shape_vertex_capacity = initial_capacity,
            .textured_vertex_buffer = textured_vertex_buffer,
            .textured_vertex_capacity = initial_capacity,
            .font_atlases = std.AutoHashMap(FontKey, FontAtlas).init(allocator),
            .image_textures = std.AutoHashMap(u32, ImageTexture).init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.font_atlases.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.font_atlases.deinit();

        var img_it = self.image_textures.iterator();
        while (img_it.next()) |entry| {
            entry.value_ptr.bind_group.release();
            entry.value_ptr.sampler.release();
            entry.value_ptr.view.release();
            entry.value_ptr.texture.release();
        }
        self.image_textures.deinit();

        if (self.ft_ready) {
            _ = c.FT_Done_FreeType(self.ft_lib);
            self.ft_ready = false;
        }

        self.shape_vertex_buffer.release();
        self.textured_vertex_buffer.release();
        self.uniform_buffer.release();
        self.shape_bind_group.release();
        self.shape_bind_group_layout.release();
        self.texture_bind_group_layout.release();
        self.shape_pipeline.release();
        self.texture_pipeline.release();
        self.shape_vertices.deinit(self.allocator);
        self.textured_vertices.deinit(self.allocator);
        self.render_items.deinit(self.allocator);
        self.scratch_points.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Renderer, width: u32, height: u32) void {
        self.screen_width = if (width > 0) width else 1;
        self.screen_height = if (height > 0) height else 1;
        self.shape_vertices.clearRetainingCapacity();
        self.textured_vertices.clearRetainingCapacity();
        self.render_items.clearRetainingCapacity();
        self.scratch_points.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
    }

    pub fn record(self: *Renderer, list: *command_list.CommandList) void {
        self.shape_vertices.clearRetainingCapacity();
        self.textured_vertices.clearRetainingCapacity();
        self.render_items.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();

        const full_scissor = Scissor{
            .x = 0,
            .y = 0,
            .width = self.screen_width,
            .height = self.screen_height,
        };
        var current_scissor = full_scissor;

        for (list.commands.items) |cmd| {
            switch (cmd) {
                .clip_push => |clip_cmd| {
                    const next_rect = if (self.clip_stack.items.len == 0)
                        clip_cmd.rect
                    else
                        intersectRect(self.clip_stack.items[self.clip_stack.items.len - 1], clip_cmd.rect);
                    _ = self.clip_stack.append(self.allocator, next_rect) catch {};
                    current_scissor = rectToScissor(next_rect, self.screen_width, self.screen_height) orelse Scissor{
                        .x = 0,
                        .y = 0,
                        .width = 0,
                        .height = 0,
                    };
                },
                .clip_pop => {
                    if (self.clip_stack.items.len > 0) {
                        _ = self.clip_stack.pop();
                    }
                    if (self.clip_stack.items.len > 0) {
                        current_scissor = rectToScissor(
                            self.clip_stack.items[self.clip_stack.items.len - 1],
                            self.screen_width,
                            self.screen_height,
                        ) orelse Scissor{ .x = 0, .y = 0, .width = 0, .height = 0 };
                    } else {
                        current_scissor = full_scissor;
                    }
                },
                .rect => |rect_cmd| {
                    if (current_scissor.width == 0 or current_scissor.height == 0) continue;
                    if (rect_cmd.style.fill) |fill| {
                        self.pushFilledRect(rect_cmd.rect, fill, current_scissor);
                    }
                    if (rect_cmd.style.stroke) |stroke| {
                        self.pushRectStroke(rect_cmd.rect, rect_cmd.style.thickness, stroke, current_scissor);
                    }
                },
                .rounded_rect => |rect_cmd| {
                    if (current_scissor.width == 0 or current_scissor.height == 0) continue;
                    if (rect_cmd.style.fill) |fill| {
                        self.pushRoundedRect(rect_cmd.rect, rect_cmd.radius, fill, current_scissor);
                    }
                    if (rect_cmd.style.stroke) |stroke| {
                        self.pushRoundedRectStroke(rect_cmd.rect, rect_cmd.radius, rect_cmd.style.thickness, stroke, current_scissor);
                    }
                },
                .line => |line_cmd| {
                    if (current_scissor.width == 0 or current_scissor.height == 0) continue;
                    self.pushLine(line_cmd.from, line_cmd.to, line_cmd.width, line_cmd.color, current_scissor);
                },
                .text => |text_cmd| {
                    if (current_scissor.width == 0 or current_scissor.height == 0) continue;
                    self.pushText(list, text_cmd, current_scissor);
                },
                .image => |image_cmd| {
                    if (current_scissor.width == 0 or current_scissor.height == 0) continue;
                    self.pushImage(image_cmd, current_scissor);
                },
            }
        }
    }

    pub fn render(self: *Renderer, pass: zgpu.wgpu.RenderPassEncoder) void {
        if (self.render_items.items.len == 0) return;

        self.ensureShapeCapacity(self.shape_vertices.items.len);
        self.ensureTexturedCapacity(self.textured_vertices.items.len);

        const uniforms = Uniforms{
            .screen_size = .{
                @floatFromInt(self.screen_width),
                @floatFromInt(self.screen_height),
            },
        };
        self.queue.writeBuffer(self.uniform_buffer, 0, Uniforms, &[_]Uniforms{uniforms});
        if (self.shape_vertices.items.len > 0) {
            self.queue.writeBuffer(self.shape_vertex_buffer, 0, ShapeVertex, self.shape_vertices.items);
        }
        if (self.textured_vertices.items.len > 0) {
            self.queue.writeBuffer(self.textured_vertex_buffer, 0, TexVertex, self.textured_vertices.items);
        }

        var current_kind: ?PipelineKind = null;
        var current_scissor: ?Scissor = null;
        var current_bind: ?zgpu.wgpu.BindGroup = null;

        for (self.render_items.items) |item| {
            if (item.kind != current_kind) {
                current_kind = item.kind;
                current_bind = null;
                switch (item.kind) {
                    .shape => {
                        pass.setPipeline(self.shape_pipeline);
                        pass.setBindGroup(0, self.shape_bind_group, null);
                        const shape_bytes: u64 = @intCast(self.shape_vertices.items.len * @sizeOf(ShapeVertex));
                        pass.setVertexBuffer(0, self.shape_vertex_buffer, 0, shape_bytes);
                    },
                    .textured => {
                        pass.setPipeline(self.texture_pipeline);
                        const textured_bytes: u64 = @intCast(self.textured_vertices.items.len * @sizeOf(TexVertex));
                        pass.setVertexBuffer(0, self.textured_vertex_buffer, 0, textured_bytes);
                    },
                }
            }

            if (item.kind == .textured) {
                if (item.bind_group) |bg| {
                    if (current_bind == null or current_bind.? != bg) {
                        pass.setBindGroup(0, bg, null);
                        current_bind = bg;
                    }
                }
            }

            if (current_scissor == null or !scissorEqual(current_scissor.?, item.scissor)) {
                pass.setScissorRect(item.scissor.x, item.scissor.y, item.scissor.width, item.scissor.height);
                current_scissor = item.scissor;
            }
            if (item.vertex_count > 0) {
                pass.draw(item.vertex_count, 1, item.first_vertex, 0);
            }
        }
    }

    fn ensureShapeCapacity(self: *Renderer, needed: usize) void {
        if (needed <= self.shape_vertex_capacity) return;
        var next_capacity = if (self.shape_vertex_capacity > 0) self.shape_vertex_capacity else 1024;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        self.shape_vertex_buffer.release();
        self.shape_vertex_buffer = self.device.createBuffer(.{
            .label = "ui.shape.vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = next_capacity * @sizeOf(ShapeVertex),
        });
        self.shape_vertex_capacity = next_capacity;
    }

    fn ensureTexturedCapacity(self: *Renderer, needed: usize) void {
        if (needed <= self.textured_vertex_capacity) return;
        var next_capacity = if (self.textured_vertex_capacity > 0) self.textured_vertex_capacity else 1024;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        self.textured_vertex_buffer.release();
        self.textured_vertex_buffer = self.device.createBuffer(.{
            .label = "ui.texture.vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = next_capacity * @sizeOf(TexVertex),
        });
        self.textured_vertex_capacity = next_capacity;
    }

    fn pushFilledRect(self: *Renderer, rect: Rect, color: Color, scissor: Scissor) void {
        const start = self.shape_vertices.items.len;
        const p0 = rect.min;
        const p1 = .{ rect.max[0], rect.min[1] };
        const p2 = rect.max;
        const p3 = .{ rect.min[0], rect.max[1] };
        self.appendShapeQuad(p0, p1, p2, p3, color);
        self.pushRenderItem(.shape, start, self.shape_vertices.items.len - start, scissor, null);
    }

    fn pushRectStroke(self: *Renderer, rect: Rect, thickness: f32, color: Color, scissor: Scissor) void {
        if (thickness <= 0.0) return;
        const points = [_]Vec2{
            rect.min,
            .{ rect.max[0], rect.min[1] },
            rect.max,
            .{ rect.min[0], rect.max[1] },
        };
        self.strokePolyline(points[0..], thickness, color, scissor, true);
    }

    fn pushRoundedRect(self: *Renderer, rect: Rect, radius: f32, color: Color, scissor: Scissor) void {
        if (radius <= 0.0) {
            self.pushFilledRect(rect, color, scissor);
            return;
        }
        const points = self.buildRoundedRectPoints(rect, radius);
        if (points.len < 3) return;
        const center = .{
            (rect.min[0] + rect.max[0]) * 0.5,
            (rect.min[1] + rect.max[1]) * 0.5,
        };
        const start = self.shape_vertices.items.len;
        var i: usize = 0;
        while (i < points.len) : (i += 1) {
            const a = points[i];
            const b = points[(i + 1) % points.len];
            self.appendShapeTriangle(center, a, b, color);
        }
        self.pushRenderItem(.shape, start, self.shape_vertices.items.len - start, scissor, null);
    }

    fn pushRoundedRectStroke(
        self: *Renderer,
        rect: Rect,
        radius: f32,
        thickness: f32,
        color: Color,
        scissor: Scissor,
    ) void {
        if (thickness <= 0.0) return;
        if (radius <= 0.0) {
            self.pushRectStroke(rect, thickness, color, scissor);
            return;
        }
        const points = self.buildRoundedRectPoints(rect, radius);
        self.strokePolyline(points, thickness, color, scissor, true);
    }

    fn pushLine(self: *Renderer, from: Vec2, to: Vec2, width: f32, color: Color, scissor: Scissor) void {
        if (width <= 0.0) return;
        const start = self.shape_vertices.items.len;
        self.appendShapeLineQuad(from, to, width, color);
        self.pushRenderItem(.shape, start, self.shape_vertices.items.len - start, scissor, null);
    }

    fn pushText(
        self: *Renderer,
        list: *const command_list.CommandList,
        text_cmd: command_list.TextCmd,
        scissor: Scissor,
    ) void {
        const text = list.textSlice(text_cmd);
        if (text.len == 0) return;
        const atlas = self.getFontAtlas(text_cmd.role, text_cmd.size_px) orelse return;
        const line_height = atlas.line_height;
        const baseline = text_cmd.pos[1] + atlas.ascent;

        var pen_x = text_cmd.pos[0];
        var pen_y = baseline;
        var batch_start: ?usize = null;
        var batch_bind_group: ?zgpu.wgpu.BindGroup = null;

        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == '\n') {
                flushTextBatch(self, &batch_start, &batch_bind_group, scissor);
                pen_x = text_cmd.pos[0];
                pen_y += line_height;
                continue;
            }
            if (cp == '\r') continue;
            const glyph = self.getGlyph(atlas, cp) orelse continue;
            if (!glyph.visible) {
                pen_x += glyph.advance;
                continue;
            }

            const bg = atlas.pages.items[glyph.page_index].bind_group;
            if (batch_bind_group == null or batch_bind_group.? != bg) {
                flushTextBatch(self, &batch_start, &batch_bind_group, scissor);
                batch_bind_group = bg;
                batch_start = self.textured_vertices.items.len;
            }

            const x0 = pen_x + glyph.bearing[0];
            const y0 = pen_y - glyph.bearing[1];
            const x1 = x0 + glyph.size[0];
            const y1 = y0 + glyph.size[1];
            const glyph_color = if (glyph.color_glyph)
                .{ 1.0, 1.0, 1.0, 1.0 }
            else
                text_cmd.color;
            self.appendTexturedQuad(
                .{ x0, y0 },
                .{ x1, y0 },
                .{ x1, y1 },
                .{ x0, y1 },
                glyph.uv_min,
                glyph.uv_max,
                glyph_color,
            );
            pen_x += glyph.advance;
        }
        flushTextBatch(self, &batch_start, &batch_bind_group, scissor);
    }

    fn pushImage(self: *Renderer, image_cmd: command_list.ImageCmd, scissor: Scissor) void {
        const tex_id: u32 = @intCast(image_cmd.texture);
        const texture = self.ensureImageTexture(tex_id) orelse return;
        const start = self.textured_vertices.items.len;
        const rect = image_cmd.rect;
        self.appendTexturedQuad(
            rect.min,
            .{ rect.max[0], rect.min[1] },
            rect.max,
            .{ rect.min[0], rect.max[1] },
            .{ 0.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0, 1.0 },
        );
        self.pushRenderItem(.textured, start, self.textured_vertices.items.len - start, scissor, texture.bind_group);
    }

    fn appendShapeTriangle(self: *Renderer, a: Vec2, b: Vec2, c_point: Vec2, color: Color) void {
        _ = self.shape_vertices.append(self.allocator, .{ .pos = a, .color = color }) catch {};
        _ = self.shape_vertices.append(self.allocator, .{ .pos = b, .color = color }) catch {};
        _ = self.shape_vertices.append(self.allocator, .{ .pos = c_point, .color = color }) catch {};
    }

    fn appendShapeQuad(self: *Renderer, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, color: Color) void {
        self.appendShapeTriangle(p0, p1, p2, color);
        self.appendShapeTriangle(p0, p2, p3, color);
    }

    fn appendShapeLineQuad(self: *Renderer, from: Vec2, to: Vec2, width: f32, color: Color) void {
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        const len_sq = dx * dx + dy * dy;
        if (len_sq <= 0.0001) return;
        const len = std.math.sqrt(len_sq);
        const half = width * 0.5;
        const nx = -dy / len * half;
        const ny = dx / len * half;
        const p0 = .{ from[0] + nx, from[1] + ny };
        const p1 = .{ from[0] - nx, from[1] - ny };
        const p2 = .{ to[0] - nx, to[1] - ny };
        const p3 = .{ to[0] + nx, to[1] + ny };
        self.appendShapeQuad(p0, p1, p2, p3, color);
    }

    fn appendTexturedQuad(
        self: *Renderer,
        p0: Vec2,
        p1: Vec2,
        p2: Vec2,
        p3: Vec2,
        uv_min: Vec2,
        uv_max: Vec2,
        color: Color,
    ) void {
        const uv0 = uv_min;
        const uv1 = .{ uv_max[0], uv_min[1] };
        const uv2 = uv_max;
        const uv3 = .{ uv_min[0], uv_max[1] };
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p0, .uv = uv0, .color = color }) catch {};
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p1, .uv = uv1, .color = color }) catch {};
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p2, .uv = uv2, .color = color }) catch {};
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p0, .uv = uv0, .color = color }) catch {};
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p2, .uv = uv2, .color = color }) catch {};
        _ = self.textured_vertices.append(self.allocator, .{ .pos = p3, .uv = uv3, .color = color }) catch {};
    }

    fn strokePolyline(
        self: *Renderer,
        points: []const Vec2,
        width: f32,
        color: Color,
        scissor: Scissor,
        closed: bool,
    ) void {
        if (points.len < 2) return;
        const start = self.shape_vertices.items.len;
        const last = if (closed) points.len else points.len - 1;
        var i: usize = 0;
        while (i < last) : (i += 1) {
            const a = points[i];
            const b = points[(i + 1) % points.len];
            self.appendShapeLineQuad(a, b, width, color);
        }
        self.pushRenderItem(.shape, start, self.shape_vertices.items.len - start, scissor, null);
    }

    fn buildRoundedRectPoints(self: *Renderer, rect: Rect, radius: f32) []const Vec2 {
        self.scratch_points.clearRetainingCapacity();
        const width = rect.max[0] - rect.min[0];
        const height = rect.max[1] - rect.min[1];
        const max_radius = @min(width, height) * 0.5;
        const r = @max(0.0, @min(radius, max_radius));
        if (r <= 0.0) {
            _ = self.scratch_points.append(self.allocator, rect.min) catch {};
            _ = self.scratch_points.append(self.allocator, .{ rect.max[0], rect.min[1] }) catch {};
            _ = self.scratch_points.append(self.allocator, rect.max) catch {};
            _ = self.scratch_points.append(self.allocator, .{ rect.min[0], rect.max[1] }) catch {};
            return self.scratch_points.items;
        }

        const segments: usize = 6;
        const tl = .{ rect.min[0] + r, rect.min[1] + r };
        const tr = .{ rect.max[0] - r, rect.min[1] + r };
        const bl = .{ rect.min[0] + r, rect.max[1] - r };

        _ = self.scratch_points.append(self.allocator, .{ rect.min[0] + r, rect.min[1] }) catch {};
        _ = self.scratch_points.append(self.allocator, .{ rect.max[0] - r, rect.min[1] }) catch {};
        appendArc(&self.scratch_points, self.allocator, tr, r, 270.0, 360.0, segments, false);
        _ = self.scratch_points.append(self.allocator, .{ rect.max[0], rect.max[1] - r }) catch {};
        appendArc(&self.scratch_points, self.allocator, .{ rect.max[0] - r, rect.max[1] - r }, r, 0.0, 90.0, segments, false);
        _ = self.scratch_points.append(self.allocator, .{ rect.min[0] + r, rect.max[1] }) catch {};
        appendArc(&self.scratch_points, self.allocator, bl, r, 90.0, 180.0, segments, false);
        _ = self.scratch_points.append(self.allocator, .{ rect.min[0], rect.min[1] + r }) catch {};
        appendArc(&self.scratch_points, self.allocator, tl, r, 180.0, 270.0, segments, false);

        return self.scratch_points.items;
    }

    fn pushRenderItem(
        self: *Renderer,
        kind: PipelineKind,
        start: usize,
        count: usize,
        scissor: Scissor,
        bind_group: ?zgpu.wgpu.BindGroup,
    ) void {
        if (count == 0) return;
        _ = self.render_items.append(self.allocator, .{
            .kind = kind,
            .first_vertex = @intCast(start),
            .vertex_count = @intCast(count),
            .scissor = scissor,
            .bind_group = bind_group,
        }) catch {};
    }

    fn ensureFreeType(self: *Renderer) bool {
        if (self.ft_ready) return true;
        if (c.FT_Init_FreeType(&self.ft_lib) != 0) return false;
        self.ft_ready = true;
        return true;
    }

    fn setFaceSize(face: c.FT_Face, size_px: u16) void {
        if (face.*.num_fixed_sizes > 0 and face.*.available_sizes != null) {
            var best_index: c_int = 0;
            var best_delta: i32 = std.math.maxInt(i32);
            var idx: c_int = 0;
            while (idx < face.*.num_fixed_sizes) : (idx += 1) {
                const entry = face.*.available_sizes[@intCast(idx)];
                var px: i32 = 0;
                if (entry.y_ppem != 0) {
                    px = @intCast(@divTrunc(@as(i32, @intCast(entry.y_ppem)), 64));
                } else {
                    px = entry.height;
                }
                const delta = @abs(px - @as(i32, @intCast(size_px)));
                if (delta < best_delta) {
                    best_delta = @intCast(delta);
                    best_index = idx;
                }
            }
            _ = c.FT_Select_Size(face, best_index);
        } else {
            _ = c.FT_Set_Pixel_Sizes(face, 0, @as(c.FT_UInt, @intCast(size_px)));
        }
    }

    fn setFaceSizeWithScale(face: c.FT_Face, size_px: u16) f32 {
        if (face.*.num_fixed_sizes > 0 and face.*.available_sizes != null) {
            var best_index: c_int = 0;
            var best_delta: i32 = std.math.maxInt(i32);
            var best_px: i32 = 0;
            var idx: c_int = 0;
            while (idx < face.*.num_fixed_sizes) : (idx += 1) {
                const entry = face.*.available_sizes[@intCast(idx)];
                var px: i32 = 0;
                if (entry.y_ppem != 0) {
                    px = @intCast(@divTrunc(@as(i32, @intCast(entry.y_ppem)), 64));
                } else {
                    px = entry.height;
                }
                const delta = @abs(px - @as(i32, @intCast(size_px)));
                if (delta < best_delta) {
                    best_delta = @intCast(delta);
                    best_index = idx;
                    best_px = px;
                }
            }
            _ = c.FT_Select_Size(face, best_index);
            if (best_px <= 0) return 1.0;
            const target = @as(f32, @floatFromInt(size_px));
            const actual = @as(f32, @floatFromInt(best_px));
            if (actual <= 0.0) return 1.0;
            const scale = target / actual;
            return if (scale < 1.0) scale else 1.0;
        }
        _ = c.FT_Set_Pixel_Sizes(face, 0, @as(c.FT_UInt, @intCast(size_px)));
        return 1.0;
    }

    fn getFontAtlas(self: *Renderer, role: FontRole, size_px: u16) ?*FontAtlas {
        const key = FontKey{ .role = role, .size_px = size_px };
        if (self.font_atlases.getPtr(key)) |atlas| return atlas;
        if (!self.ensureFreeType()) return null;

        const font_data = switch (role) {
            .body => font_system.fontDataFor(.body),
            .heading, .title => font_system.fontDataFor(.heading),
        };
        var face_primary: c.FT_Face = undefined;
        const data_ptr: [*c]const c.FT_Byte = @ptrCast(font_data.ptr);
        const data_len: c.FT_Long = @intCast(font_data.len);
        if (c.FT_New_Memory_Face(self.ft_lib, data_ptr, data_len, 0, &face_primary) != 0) return null;
        setFaceSize(face_primary, size_px);

        var face_emoji_color: ?c.FT_Face = null;
        var face_emoji_mono: ?c.FT_Face = null;
        var emoji_scale_color: f32 = 1.0;
        var emoji_scale_mono: f32 = 1.0;
        const emoji_data = font_system.emojiFontData();
        if (emoji_data.len > 0) {
            var emoji_face: c.FT_Face = undefined;
            const emoji_ptr: [*c]const c.FT_Byte = @ptrCast(emoji_data.ptr);
            const emoji_len: c.FT_Long = @intCast(emoji_data.len);
            const load_err = c.FT_New_Memory_Face(self.ft_lib, emoji_ptr, emoji_len, 0, &emoji_face);
            logger.debug("emoji color font bytes={d} load_err={d}", .{ emoji_data.len, load_err });
            if (load_err == 0) {
                emoji_scale_color = setFaceSizeWithScale(emoji_face, size_px);
                face_emoji_color = emoji_face;
            } else {
                logger.warn("Emoji color font load failed (size={d} bytes).", .{emoji_data.len});
            }
        }

        const emoji_mono_data = font_system.emojiMonoFontData();
        if (emoji_mono_data.len > 0) {
            var emoji_face: c.FT_Face = undefined;
            const emoji_ptr: [*c]const c.FT_Byte = @ptrCast(emoji_mono_data.ptr);
            const emoji_len: c.FT_Long = @intCast(emoji_mono_data.len);
            const load_err = c.FT_New_Memory_Face(self.ft_lib, emoji_ptr, emoji_len, 0, &emoji_face);
            logger.debug("emoji mono font bytes={d} load_err={d}", .{ emoji_mono_data.len, load_err });
            if (load_err == 0) {
                emoji_scale_mono = setFaceSizeWithScale(emoji_face, size_px);
                face_emoji_mono = emoji_face;
            } else {
                logger.warn("Emoji mono font load failed (size={d} bytes).", .{emoji_mono_data.len});
            }
        }

        const ascender = @as(f32, @floatFromInt(face_primary.*.size.*.metrics.ascender)) / 64.0;
        const line_height = lineHeightFor(face_primary, size_px);

        var atlas = FontAtlas{
            .role = role,
            .size_px = size_px,
            .face_primary = face_primary,
            .face_emoji_color = face_emoji_color,
            .face_emoji_mono = face_emoji_mono,
            .emoji_scale_color = emoji_scale_color,
            .emoji_scale_mono = emoji_scale_mono,
            .line_height = line_height,
            .ascent = ascender,
            .pages = .empty,
            .glyphs = std.AutoHashMap(u21, GlyphInfo).init(self.allocator),
        };
        const page = self.createAtlasPage();
        if (page) |pg| {
            _ = atlas.pages.append(self.allocator, pg) catch {};
        }

        self.font_atlases.put(key, atlas) catch {
            atlas.deinit(self.allocator);
            return null;
        };
        return self.font_atlases.getPtr(key);
    }

    fn createAtlasPage(self: *Renderer) ?AtlasPage {
        const size: u32 = 2048;
        const texture = self.device.createTexture(.{
            .label = "ui.atlas",
            .size = .{ .width = size, .height = size, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .tdim_2d,
        });
        const view = texture.createView(.{ .format = .rgba8_unorm, .dimension = .tvdim_2d });
        const sampler = self.device.createSampler(.{
            .label = "ui.atlas.sampler",
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        });

        const entries = [_]zgpu.wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = self.uniform_buffer,
                .offset = 0,
                .size = @sizeOf(Uniforms),
            },
            .{
                .binding = 1,
                .sampler = sampler,
                .size = 0,
            },
            .{
                .binding = 2,
                .texture_view = view,
                .size = 0,
            },
        };
        const bind_group = self.device.createBindGroup(.{
            .label = "ui.atlas.bg",
            .layout = self.texture_bind_group_layout,
            .entry_count = entries.len,
            .entries = &entries,
        });

        return .{
            .texture = texture,
            .view = view,
            .sampler = sampler,
            .bind_group = bind_group,
            .width = size,
            .height = size,
            .next_x = 1,
            .next_y = 1,
            .row_height = 0,
        };
    }

    fn getGlyph(self: *Renderer, atlas: *FontAtlas, cp: u21) ?GlyphInfo {
        if (atlas.glyphs.get(cp)) |existing| {
            return existing;
        }

        var face = atlas.face_primary;
        var using_emoji = false;
        var using_color_emoji = false;
        const color_load_flags: c_int = c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR;
        const mono_load_flags: c_int = c.FT_LOAD_DEFAULT;
        var index = c.FT_Get_Char_Index(face, @as(c.FT_ULong, cp));
        const primary_index = index;
        var mono_face: ?c.FT_Face = null;
        var mono_index: c_uint = 0;
        if (isEmojiCodepoint(cp)) {
            if (atlas.face_emoji_color) |emoji_face| {
                const emoji_index = c.FT_Get_Char_Index(emoji_face, @as(c.FT_ULong, cp));
                if (emoji_index != 0) {
                    face = emoji_face;
                    index = emoji_index;
                    using_emoji = true;
                    using_color_emoji = true;
                }
            }
            if (atlas.face_emoji_mono) |emoji_face| {
                const emoji_index = c.FT_Get_Char_Index(emoji_face, @as(c.FT_ULong, cp));
                if (emoji_index != 0) {
                    mono_face = emoji_face;
                    mono_index = emoji_index;
                    if (!using_emoji) {
                        face = emoji_face;
                        index = emoji_index;
                        using_emoji = true;
                        using_color_emoji = false;
                    }
                }
            }
            logger.debug(
                "emoji glyph cp=U+{X:0>4} primary_index={d} color_face={} mono_face={} using_emoji={} color={} chosen_index={d}",
                .{ cp, primary_index, atlas.face_emoji_color != null, atlas.face_emoji_mono != null, using_emoji, using_color_emoji, index },
            );
        }
        if (index == 0) {
            const fallback = GlyphInfo{
                .page_index = 0,
                .size = .{ 0.0, 0.0 },
                .bearing = .{ 0.0, 0.0 },
                .advance = @as(f32, @floatFromInt(atlas.size_px)) * 0.5,
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
                .visible = false,
                .color_glyph = false,
            };
            atlas.glyphs.put(cp, fallback) catch {};
            return fallback;
        }

        var load_result = c.FT_Load_Glyph(face, index, if (using_color_emoji) color_load_flags else mono_load_flags);
        if (load_result != 0 and using_color_emoji and mono_face != null and mono_index != 0) {
            face = mono_face.?;
            index = mono_index;
            using_color_emoji = false;
            using_emoji = true;
            load_result = c.FT_Load_Glyph(face, index, mono_load_flags);
        }
        if (load_result != 0) {
            if (isEmojiCodepoint(cp)) {
                logger.warn("emoji load failed cp=U+{X:0>4} using_emoji={} color={} err={d}", .{ cp, using_emoji, using_color_emoji, load_result });
            }
            return null;
        }
        const glyph = face.*.glyph;
        if (glyph.*.format != c.FT_GLYPH_FORMAT_BITMAP or glyph.*.bitmap.buffer == null) {
            if (c.FT_Render_Glyph(glyph, c.FT_RENDER_MODE_NORMAL) != 0) {
                return null;
            }
        }
        const bitmap = glyph.*.bitmap;
        const width = @as(u32, @intCast(bitmap.width));
        const height = @as(u32, @intCast(bitmap.rows));
        const bearing_x = @as(f32, @floatFromInt(glyph.*.bitmap_left));
        const bearing_y = @as(f32, @floatFromInt(glyph.*.bitmap_top));
        const advance = @as(f32, @floatFromInt(glyph.*.advance.x)) / 64.0;
        var emoji_scale: f32 = 1.0;
        if (using_emoji) {
            emoji_scale = if (using_color_emoji) atlas.emoji_scale_color else atlas.emoji_scale_mono;
        }
        const scaled_bearing_x = bearing_x * emoji_scale;
        const scaled_bearing_y = bearing_y * emoji_scale;
        const scaled_advance = advance * emoji_scale;
        const is_color_glyph = using_color_emoji and bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA;
        if (bitmap.buffer == null) {
            if (isEmojiCodepoint(cp)) {
                logger.warn("emoji bitmap missing cp=U+{X:0>4} format={d} mode={d}", .{ cp, glyph.*.format, bitmap.pixel_mode });
            }
            const info = GlyphInfo{
                .page_index = 0,
                .size = .{ 0.0, 0.0 },
                .bearing = .{ scaled_bearing_x, scaled_bearing_y },
                .advance = scaled_advance,
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
                .visible = false,
                .color_glyph = is_color_glyph,
            };
            atlas.glyphs.put(cp, info) catch {};
            return info;
        }
        if (isEmojiCodepoint(cp)) {
            logger.debug(
                "emoji bitmap cp=U+{X:0>4} format={d} pixel_mode={d} size={d}x{d} using_emoji={}",
                .{ cp, glyph.*.format, bitmap.pixel_mode, width, height, using_emoji },
            );
        }

        if (width == 0 or height == 0) {
            const info = GlyphInfo{
                .page_index = 0,
                .size = .{ 0.0, 0.0 },
                .bearing = .{ scaled_bearing_x, scaled_bearing_y },
                .advance = scaled_advance,
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
                .visible = false,
                .color_glyph = is_color_glyph,
            };
            atlas.glyphs.put(cp, info) catch {};
            return info;
        }

        var page_index: usize = 0;
        const pos = self.allocateGlyph(atlas, width, height, &page_index) orelse {
            const info = GlyphInfo{
                .page_index = 0,
                .size = .{ 0.0, 0.0 },
                .bearing = .{ scaled_bearing_x, scaled_bearing_y },
                .advance = scaled_advance,
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
                .visible = false,
                .color_glyph = is_color_glyph,
            };
            atlas.glyphs.put(cp, info) catch {};
            return info;
        };

        const rgba = self.buildGlyphBitmap(bitmap, width, height) orelse return null;
        defer self.allocator.free(rgba);

        const page = &atlas.pages.items[page_index];
        const layout = zgpu.wgpu.TextureDataLayout{
            .offset = 0,
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        };
        const destination = zgpu.wgpu.ImageCopyTexture{
            .texture = page.texture,
            .mip_level = 0,
            .origin = .{ .x = pos[0], .y = pos[1], .z = 0 },
            .aspect = .all,
        };
        const size = zgpu.wgpu.Extent3D{ .width = width, .height = height, .depth_or_array_layers = 1 };
        self.queue.writeTexture(destination, layout, size, u8, rgba);

        const u_min = @as(f32, @floatFromInt(pos[0])) / @as(f32, @floatFromInt(page.width));
        const v_min = @as(f32, @floatFromInt(pos[1])) / @as(f32, @floatFromInt(page.height));
        const u_max = @as(f32, @floatFromInt(pos[0] + width)) / @as(f32, @floatFromInt(page.width));
        const v_max = @as(f32, @floatFromInt(pos[1] + height)) / @as(f32, @floatFromInt(page.height));

        const info = GlyphInfo{
            .page_index = @intCast(page_index),
            .size = .{
                @as(f32, @floatFromInt(width)) * emoji_scale,
                @as(f32, @floatFromInt(height)) * emoji_scale,
            },
            .bearing = .{ scaled_bearing_x, scaled_bearing_y },
            .advance = scaled_advance,
            .uv_min = .{ u_min, v_min },
            .uv_max = .{ u_max, v_max },
            .visible = true,
            .color_glyph = is_color_glyph,
        };
        atlas.glyphs.put(cp, info) catch {};
        return info;
    }

    fn allocateGlyph(
        self: *Renderer,
        atlas: *FontAtlas,
        width: u32,
        height: u32,
        page_index: *usize,
    ) ?[2]u32 {
        var idx: usize = 0;
        while (idx < atlas.pages.items.len) : (idx += 1) {
            if (allocateInPage(&atlas.pages.items[idx], width, height)) |pos| {
                page_index.* = idx;
                return pos;
            }
        }
        if (self.createAtlasPage()) |page| {
            _ = atlas.pages.append(self.allocator, page) catch {};
            const new_idx = atlas.pages.items.len - 1;
            if (allocateInPage(&atlas.pages.items[new_idx], width, height)) |pos| {
                page_index.* = new_idx;
                return pos;
            }
        }
        return null;
    }

    fn buildGlyphBitmap(self: *Renderer, bitmap: c.FT_Bitmap, width: u32, height: u32) ?[]u8 {
        const pixel_len = @as(usize, width) * @as(usize, height) * 4;
        const rgba = self.allocator.alloc(u8, pixel_len) catch return null;
        const buf: [*]u8 = @ptrCast(bitmap.buffer);
        const pitch = @as(usize, @intCast(@abs(bitmap.pitch)));
        switch (bitmap.pixel_mode) {
            c.FT_PIXEL_MODE_BGRA => {
                var y: usize = 0;
                while (y < height) : (y += 1) {
                    const row = buf + y * pitch;
                    var x: usize = 0;
                    while (x < width) : (x += 1) {
                        const src = row + x * 4;
                        const dst_idx = (y * @as(usize, width) + x) * 4;
                        const b = src[0];
                        const g = src[1];
                        const r = src[2];
                        const a = src[3];
                        rgba[dst_idx] = r;
                        rgba[dst_idx + 1] = g;
                        rgba[dst_idx + 2] = b;
                        rgba[dst_idx + 3] = a;
                    }
                }
            },
            c.FT_PIXEL_MODE_GRAY => {
                var y: usize = 0;
                while (y < height) : (y += 1) {
                    const row = buf + y * pitch;
                    var x: usize = 0;
                    while (x < width) : (x += 1) {
                        const a = row[x];
                        const dst_idx = (y * @as(usize, width) + x) * 4;
                        rgba[dst_idx] = 255;
                        rgba[dst_idx + 1] = 255;
                        rgba[dst_idx + 2] = 255;
                        rgba[dst_idx + 3] = a;
                    }
                }
            },
            c.FT_PIXEL_MODE_MONO => {
                var y: usize = 0;
                while (y < height) : (y += 1) {
                    const row = buf + y * pitch;
                    var x: usize = 0;
                    while (x < width) : (x += 1) {
                        const byte = row[x / 8];
                        const mask = @as(u8, 0x80) >> @intCast(x % 8);
                        const a: u8 = if ((byte & mask) != 0) 255 else 0;
                        const dst_idx = (y * @as(usize, width) + x) * 4;
                        rgba[dst_idx] = 255;
                        rgba[dst_idx + 1] = 255;
                        rgba[dst_idx + 2] = 255;
                        rgba[dst_idx + 3] = a;
                    }
                }
            },
            else => {
                self.allocator.free(rgba);
                return null;
            },
        }
        return rgba;
    }

    fn ensureImageTexture(self: *Renderer, id: u32) ?*ImageTexture {
        const entry_opt = image_cache.getById(id);
        if (entry_opt == null) {
            if (self.image_textures.fetchRemove(id)) |removed| {
                removed.value.bind_group.release();
                removed.value.sampler.release();
                removed.value.view.release();
                removed.value.texture.release();
            }
            return null;
        }
        if (self.image_textures.getPtr(id)) |tex| {
            if (entry_opt.?.state == .ready) return tex;
            return null;
        }
        const entry = entry_opt.?;
        if (entry.state != .ready or entry.pixels == null) return null;
        const pixels = entry.pixels.?;
        if (entry.width == 0 or entry.height == 0) return null;

        const texture = self.device.createTexture(.{
            .label = "ui.image",
            .size = .{ .width = entry.width, .height = entry.height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .mip_level_count = 1,
            .sample_count = 1,
            .dimension = .tdim_2d,
        });
        const view = texture.createView(.{ .format = .rgba8_unorm, .dimension = .tvdim_2d });
        const sampler = self.device.createSampler(.{
            .label = "ui.image.sampler",
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        });

        const layout = zgpu.wgpu.TextureDataLayout{
            .offset = 0,
            .bytes_per_row = entry.width * 4,
            .rows_per_image = entry.height,
        };
        const destination = zgpu.wgpu.ImageCopyTexture{
            .texture = texture,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = .all,
        };
        const size = zgpu.wgpu.Extent3D{ .width = entry.width, .height = entry.height, .depth_or_array_layers = 1 };
        self.queue.writeTexture(destination, layout, size, u8, pixels);

        const entries = [_]zgpu.wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = self.uniform_buffer,
                .offset = 0,
                .size = @sizeOf(Uniforms),
            },
            .{
                .binding = 1,
                .sampler = sampler,
                .size = 0,
            },
            .{
                .binding = 2,
                .texture_view = view,
                .size = 0,
            },
        };
        const bind_group = self.device.createBindGroup(.{
            .label = "ui.image.bg",
            .layout = self.texture_bind_group_layout,
            .entry_count = entries.len,
            .entries = &entries,
        });

        image_cache.releasePixels(id);
        self.image_textures.put(id, .{
            .texture = texture,
            .view = view,
            .sampler = sampler,
            .bind_group = bind_group,
        }) catch {
            bind_group.release();
            sampler.release();
            view.release();
            texture.release();
            return null;
        };
        return self.image_textures.getPtr(id);
    }
};

fn flushTextBatch(
    renderer: *Renderer,
    batch_start: *?usize,
    batch_bind_group: *?zgpu.wgpu.BindGroup,
    scissor: Scissor,
) void {
    if (batch_start.*) |start| {
        const count = renderer.textured_vertices.items.len - start;
        renderer.pushRenderItem(.textured, start, count, scissor, batch_bind_group.*);
    }
    batch_start.* = null;
    batch_bind_group.* = null;
}

fn allocateInPage(page: *AtlasPage, width: u32, height: u32) ?[2]u32 {
    if (width == 0 or height == 0) return null;
    if (page.next_x + width + 1 > page.width) {
        page.next_x = 1;
        page.next_y += page.row_height + 1;
        page.row_height = 0;
    }
    if (page.next_y + height + 1 > page.height) return null;
    const x = page.next_x;
    const y = page.next_y;
    page.next_x += width + 1;
    page.row_height = @max(page.row_height, height);
    return .{ x, y };
}

fn lineHeightFor(face: c.FT_Face, size_px: u16) f32 {
    const size_metrics = face.*.size.*.metrics;
    var height = @as(f32, @floatFromInt(size_metrics.height)) / 64.0;
    if (height <= 0.0) {
        height = @as(f32, @floatFromInt(size_metrics.y_ppem));
    }
    if (height <= 0.0) {
        height = @as(f32, @floatFromInt(size_px));
    }
    return height;
}

fn appendArc(
    points: *std.ArrayList(Vec2),
    allocator: std.mem.Allocator,
    center: Vec2,
    radius: f32,
    start_deg: f32,
    end_deg: f32,
    segments: usize,
    include_start: bool,
) void {
    if (segments == 0) return;
    const start = std.math.degreesToRadians(start_deg);
    const end = std.math.degreesToRadians(end_deg);
    const step = (end - start) / @as(f32, @floatFromInt(segments));
    var i: usize = 0;
    while (i <= segments) : (i += 1) {
        if (i == 0 and !include_start) continue;
        const angle = start + step * @as(f32, @floatFromInt(i));
        const x = center[0] + std.math.cos(angle) * radius;
        const y = center[1] + std.math.sin(angle) * radius;
        _ = points.append(allocator, .{ x, y }) catch {};
    }
}

fn intersectRect(a: Rect, b: Rect) Rect {
    return .{
        .min = .{ @max(a.min[0], b.min[0]), @max(a.min[1], b.min[1]) },
        .max = .{ @min(a.max[0], b.max[0]), @min(a.max[1], b.max[1]) },
    };
}

fn rectToScissor(rect: Rect, width: u32, height: u32) ?Scissor {
    const w = @as(f32, @floatFromInt(width));
    const h = @as(f32, @floatFromInt(height));
    const min_x = std.math.clamp(rect.min[0], 0.0, w);
    const min_y = std.math.clamp(rect.min[1], 0.0, h);
    const max_x = std.math.clamp(rect.max[0], 0.0, w);
    const max_y = std.math.clamp(rect.max[1], 0.0, h);
    if (max_x <= min_x or max_y <= min_y) return null;
    const x0 = @as(i32, @intFromFloat(std.math.floor(min_x)));
    const y0 = @as(i32, @intFromFloat(std.math.floor(min_y)));
    const x1 = @as(i32, @intFromFloat(std.math.ceil(max_x)));
    const y1 = @as(i32, @intFromFloat(std.math.ceil(max_y)));
    const w_int = x1 - x0;
    const h_int = y1 - y0;
    if (w_int <= 0 or h_int <= 0) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(w_int),
        .height = @intCast(h_int),
    };
}

fn scissorEqual(a: Scissor, b: Scissor) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}
