const std = @import("std");
const types = @import("text_metrics_types.zig");
const font_system = @import("font_system.zig");
const theme = @import("theme.zig");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

var lib_ready = false;
var lib: c.FT_Library = undefined;

var face_body_ready = false;
var face_heading_ready = false;
var face_body: c.FT_Face = undefined;
var face_heading: c.FT_Face = undefined;
var size_body: u32 = 0;
var size_heading: u32 = 0;
var face_emoji_color_ready = false;
var face_emoji_mono_ready = false;
var face_emoji_color: c.FT_Face = undefined;
var face_emoji_mono: c.FT_Face = undefined;
var size_emoji_color: u32 = 0;
var size_emoji_mono: u32 = 0;
var scale_emoji_color: f32 = 1.0;
var scale_emoji_mono: f32 = 1.0;

fn isEmojiCodepoint(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF);
}

fn ensureLibrary() bool {
    if (lib_ready) return true;
    if (c.FT_Init_FreeType(&lib) != 0) return false;
    lib_ready = true;
    return true;
}

fn ensureFace(role: theme.FontRole, size_px: u32) ?c.FT_Face {
    if (!ensureLibrary()) return null;
    switch (role) {
        .body => {
            if (!face_body_ready) {
                const data = font_system.fontDataFor(.body);
                const data_ptr: [*c]const c.FT_Byte = @ptrCast(data.ptr);
                const data_len: c.FT_Long = @intCast(data.len);
                if (c.FT_New_Memory_Face(lib, data_ptr, data_len, 0, &face_body) != 0) return null;
                face_body_ready = true;
            }
            if (size_body != size_px) {
                setFaceSize(face_body, size_px);
                size_body = size_px;
            }
            return face_body;
        },
        .heading, .title => {
            if (!face_heading_ready) {
                const data = font_system.fontDataFor(.heading);
                const data_ptr: [*c]const c.FT_Byte = @ptrCast(data.ptr);
                const data_len: c.FT_Long = @intCast(data.len);
                if (c.FT_New_Memory_Face(lib, data_ptr, data_len, 0, &face_heading) != 0) return null;
                face_heading_ready = true;
            }
            if (size_heading != size_px) {
                setFaceSize(face_heading, size_px);
                size_heading = size_px;
            }
            return face_heading;
        },
    }
}

fn ensureEmojiColorFace(size_px: u32) ?c.FT_Face {
    if (!ensureLibrary()) return null;
    if (!face_emoji_color_ready) {
        const data = font_system.emojiFontData();
        if (data.len == 0) return null;
        const data_ptr: [*c]const c.FT_Byte = @ptrCast(data.ptr);
        const data_len: c.FT_Long = @intCast(data.len);
        if (c.FT_New_Memory_Face(lib, data_ptr, data_len, 0, &face_emoji_color) != 0) return null;
        face_emoji_color_ready = true;
    }
    if (size_emoji_color != size_px) {
        scale_emoji_color = setFaceSizeWithScale(face_emoji_color, size_px);
        size_emoji_color = size_px;
    }
    return face_emoji_color;
}

fn ensureEmojiMonoFace(size_px: u32) ?c.FT_Face {
    if (!ensureLibrary()) return null;
    if (!face_emoji_mono_ready) {
        const data = font_system.emojiMonoFontData();
        if (data.len == 0) return null;
        const data_ptr: [*c]const c.FT_Byte = @ptrCast(data.ptr);
        const data_len: c.FT_Long = @intCast(data.len);
        if (c.FT_New_Memory_Face(lib, data_ptr, data_len, 0, &face_emoji_mono) != 0) return null;
        face_emoji_mono_ready = true;
    }
    if (size_emoji_mono != size_px) {
        scale_emoji_mono = setFaceSizeWithScale(face_emoji_mono, size_px);
        size_emoji_mono = size_px;
    }
    return face_emoji_mono;
}

fn setFaceSize(face: c.FT_Face, size_px: u32) void {
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

fn setFaceSizeWithScale(face: c.FT_Face, size_px: u32) f32 {
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

fn currentSizePx() u32 {
    const t = theme.activeTheme();
    const size = font_system.currentFontSize(t);
    if (size <= 0.0) return 1;
    const px: u32 = @intFromFloat(size);
    return if (px == 0) 1 else px;
}

fn lineHeightFor(face: c.FT_Face, size_px: u32) f32 {
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

fn glyphAdvance(face: c.FT_Face, codepoint: u21, size_px: u32) f32 {
    if (isEmojiCodepoint(codepoint)) {
        if (ensureEmojiColorFace(size_px)) |emoji_face| {
            const emoji_index = c.FT_Get_Char_Index(emoji_face, @as(c.FT_ULong, codepoint));
            if (emoji_index != 0) {
                if (c.FT_Load_Glyph(emoji_face, emoji_index, c.FT_LOAD_DEFAULT) == 0) {
                    const advance = emoji_face.*.glyph.*.advance.x;
                    return (@as(f32, @floatFromInt(advance)) / 64.0) * scale_emoji_color;
                }
            }
        }
        if (ensureEmojiMonoFace(size_px)) |emoji_face| {
            const emoji_index = c.FT_Get_Char_Index(emoji_face, @as(c.FT_ULong, codepoint));
            if (emoji_index != 0) {
                if (c.FT_Load_Glyph(emoji_face, emoji_index, c.FT_LOAD_DEFAULT) == 0) {
                    const advance = emoji_face.*.glyph.*.advance.x;
                    return (@as(f32, @floatFromInt(advance)) / 64.0) * scale_emoji_mono;
                }
            }
        }
    }
    const index = c.FT_Get_Char_Index(face, @as(c.FT_ULong, codepoint));
    if (index == 0) {
        return @as(f32, @floatFromInt(size_px)) * 0.6;
    }
    if (c.FT_Load_Glyph(face, index, c.FT_LOAD_DEFAULT) != 0) {
        return @as(f32, @floatFromInt(size_px)) * 0.6;
    }
    const advance = face.*.glyph.*.advance.x;
    return @as(f32, @floatFromInt(advance)) / 64.0;
}

fn measure(text: []const u8, wrap_width: f32) types.Vec2 {
    const size_px = currentSizePx();
    const role = font_system.currentRole();
    const face = ensureFace(role, size_px) orelse return .{ 0.0, 0.0 };
    const line_height = lineHeightFor(face, size_px);
    var max_width: f32 = 0.0;
    var line_width: f32 = 0.0;
    var lines: usize = 1;

    var view = std.unicode.Utf8View.init(text) catch return .{ 0.0, line_height };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            max_width = @max(max_width, line_width);
            line_width = 0.0;
            lines += 1;
            continue;
        }
        if (cp == '\r') continue;
        const adv = glyphAdvance(face, cp, size_px);
        if (wrap_width > 0.0 and line_width > 0.0 and (line_width + adv) > wrap_width) {
            max_width = @max(max_width, line_width);
            line_width = adv;
            lines += 1;
            continue;
        }
        line_width += adv;
    }
    max_width = @max(max_width, line_width);
    return .{ max_width, line_height * @as(f32, @floatFromInt(lines)) };
}

fn lineHeight() f32 {
    const size_px = currentSizePx();
    const role = font_system.currentRole();
    const face = ensureFace(role, size_px) orelse return @as(f32, @floatFromInt(size_px));
    return lineHeightFor(face, size_px);
}

pub const metrics = types.Metrics{
    .measure = measure,
    .line_height = lineHeight,
};
