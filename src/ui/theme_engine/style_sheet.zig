const std = @import("std");

const theme_tokens = @import("../theme/theme.zig");

pub const Color = [4]f32;

pub const BlendMode = enum {
    alpha,
    additive,
};

pub const Gradient4 = struct {
    tl: Color,
    tr: Color,
    bl: Color,
    br: Color,
};

pub const ImagePaintMode = enum {
    stretch,
    tile,
};

pub const ImagePaint = struct {
    path: AssetPath = .{},
    mode: ImagePaintMode = .stretch,
    // For tiling: how many source pixels map to 1 destination pixel.
    // 1.0 = 1:1. Smaller => denser tiling.
    scale: ?f32 = null,
    // Optional tint multiply (defaults to white).
    tint: ?Color = null,
    // Optional pixel offset for tiling origin.
    offset_px: ?[2]f32 = null,
};

pub const Paint = union(enum) {
    solid: Color,
    gradient4: Gradient4,
    image: ImagePaint,
};

pub const AssetPath = struct {
    // Theme asset paths are authored inside packs and should be short; keep this allocation-free.
    len: u16 = 0,
    buf: [256]u8 = undefined,

    pub fn isSet(self: *const AssetPath) bool {
        return self.len != 0;
    }

    pub fn slice(self: *const AssetPath) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *AssetPath, s: []const u8) void {
        const n: usize = @min(s.len, self.buf.len);
        if (n == 0) {
            self.len = 0;
            return;
        }
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = @intCast(n);
    }
};

pub const ButtonVariantStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    text: ?Color = null,
    border: ?Color = null,
    states: ButtonVariantStates = .{},
};

pub const ButtonVariantStateStyle = struct {
    fill: ?Paint = null,
    text: ?Color = null,
    border: ?Color = null,

    pub fn isSet(self: *const ButtonVariantStateStyle) bool {
        return self.fill != null or self.text != null or self.border != null;
    }
};

pub const ButtonVariantStates = struct {
    hover: ButtonVariantStateStyle = .{},
    pressed: ButtonVariantStateStyle = .{},
    disabled: ButtonVariantStateStyle = .{},
    focused: ButtonVariantStateStyle = .{},
};

pub const ButtonStyles = struct {
    primary: ButtonVariantStyle = .{},
    secondary: ButtonVariantStyle = .{},
    ghost: ButtonVariantStyle = .{},
};

pub const CheckboxStateStyle = struct {
    fill: ?Paint = null,
    fill_checked: ?Paint = null,
    border: ?Color = null,
    border_checked: ?Color = null,
    check: ?Color = null,

    pub fn isSet(self: *const CheckboxStateStyle) bool {
        return self.fill != null or self.fill_checked != null or self.border != null or self.border_checked != null or self.check != null;
    }
};

pub const CheckboxStates = struct {
    hover: CheckboxStateStyle = .{},
    pressed: CheckboxStateStyle = .{},
    disabled: CheckboxStateStyle = .{},
    focused: CheckboxStateStyle = .{},
};

pub const CheckboxStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    fill_checked: ?Paint = null,
    border: ?Color = null,
    border_checked: ?Color = null,
    check: ?Color = null,
    states: CheckboxStates = .{},
};

pub const TextInputStateStyle = struct {
    fill: ?Paint = null,
    border: ?Color = null,
    text: ?Color = null,
    placeholder: ?Color = null,
    selection: ?Color = null,
    caret: ?Color = null,

    pub fn isSet(self: *const TextInputStateStyle) bool {
        return self.fill != null or self.border != null or self.text != null or self.placeholder != null or self.selection != null or self.caret != null;
    }
};

pub const TextInputStates = struct {
    hover: TextInputStateStyle = .{},
    pressed: TextInputStateStyle = .{},
    disabled: TextInputStateStyle = .{},
    focused: TextInputStateStyle = .{},
};

pub const TextInputStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    border: ?Color = null,
    text: ?Color = null,
    placeholder: ?Color = null,
    selection: ?Color = null,
    caret: ?Color = null,
    states: TextInputStates = .{},
};

pub const SurfacesStyle = struct {
    // Paint overrides for the common "background" and "surface" rectangular fills used across views.
    // If unset, the engine falls back to theme tokens (colors.background/colors.surface).
    background: ?Paint = null,
    surface: ?Paint = null,
};

pub const PanelStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    border: ?Color = null,
    // Optional inset applied to layouts that place content "inside" a panel.
    // This is separate from visual padding and is meant to keep content out of thick frame borders.
    // Order: left, top, right, bottom (pixels).
    content_inset_px: ?[4]f32 = null,
    // Optional paint drawn over the entire panel rect after fill+frame (useful for lighting layers).
    overlay: ?Paint = null,
    shadow: EffectStyle = .{},
    frame_image: AssetPath = .{},
    frame_slices_px: ?[4]f32 = null,
    frame_tint: ?Color = null,
    // If false, the 9-slice center cell is not drawn (useful when the source image has
    // an opaque center but you want it to behave like a border/frame).
    frame_draw_center: bool = true,
    // Optional paint drawn into the 9-slice interior rect (x1..x2, y1..y2) after the frame.
    // Intended for "lighting" overlays (eg brushed-metal spotlight) layered over a tileable base.
    frame_center_overlay: ?Paint = null,
    // If true, the 9-slice center cell is tiled (pixel-perfect) instead of stretched.
    frame_tile_center: bool = false,
    // When tiling the 9-slice center, choose which axes are tiled.
    // Defaults to true for both so `center_mode: "tile"` behaves like "tile_xy".
    frame_tile_center_x: bool = true,
    frame_tile_center_y: bool = true,
    // If true and frame_tile_center is enabled, anchor tiling to the end so any partial remainder
    // lands on the left/top instead of the right/bottom.
    frame_tile_anchor_end: bool = false,
};

pub const FocusRingStyle = struct {
    thickness: ?f32 = null,
    color: ?Color = null,
    glow: EffectStyle = .{},
};

pub const EffectStyle = struct {
    // Generic effect params used for panel shadows and focus ring glows.
    // All fields optional so themes can partially specify.
    color: ?Color = null,
    blur_px: ?f32 = null,
    spread_px: ?f32 = null,
    offset: ?[2]f32 = null,
    steps: ?u8 = null,
    blend: ?BlendMode = null,
    // Shapes the alpha falloff for blur/glow/shadow:
    // 1.0 = default, >1.0 = tighter edge, <1.0 = softer spread.
    falloff_exp: ?f32 = null,
    // If true, the effect ignores the current clip stack (useful for drop shadows).
    ignore_clip: ?bool = null,
};

/// Resolved style sheet (no allocations).
pub const StyleSheet = struct {
    surfaces: SurfacesStyle = .{},
    button: ButtonStyles = .{},
    checkbox: CheckboxStyle = .{},
    text_input: TextInputStyle = .{},
    panel: PanelStyle = .{},
    focus_ring: FocusRingStyle = .{},
};

/// Optional on-disk style sheet payload (keeps raw JSON for debug/hot-reload later).
pub const StyleSheetStore = struct {
    allocator: std.mem.Allocator,
    raw_json: []u8,
    resolved: StyleSheet,

    pub fn initEmpty(allocator: std.mem.Allocator) StyleSheetStore {
        return .{ .allocator = allocator, .raw_json = &[_]u8{}, .resolved = .{} };
    }

    pub fn deinit(self: *StyleSheetStore) void {
        if (self.raw_json.len > 0) self.allocator.free(self.raw_json);
        self.* = undefined;
    }
};

pub fn loadRawFromDirectoryMaybe(
    allocator: std.mem.Allocator,
    root_path: []const u8,
) !StyleSheetStore {
    var dir = std.fs.cwd().openDir(root_path, .{}) catch {
        return StyleSheetStore.initEmpty(allocator);
    };
    defer dir.close();

    const f = dir.openFile("styles/components.json", .{}) catch {
        return StyleSheetStore.initEmpty(allocator);
    };
    defer f.close();

    const bytes = try f.readToEndAlloc(allocator, 512 * 1024);
    return .{ .allocator = allocator, .raw_json = bytes, .resolved = .{} };
}

pub fn loadFromDirectoryMaybe(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    theme: *const theme_tokens.Theme,
) !StyleSheetStore {
    var store = try loadRawFromDirectoryMaybe(allocator, root_path);
    if (store.raw_json.len == 0) return store;
    const resolved = try parseResolved(allocator, store.raw_json, theme);
    store.resolved = resolved;
    return store;
}

pub fn parseResolved(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    theme: *const theme_tokens.Theme,
) !StyleSheet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var out: StyleSheet = .{};
    if (parsed.value != .object) return out;
    const root = parsed.value.object;

    if (root.get("surfaces")) |sv| {
        parseSurfaces(&out.surfaces, sv, theme);
    }
    if (root.get("button")) |btn_val| {
        parseButtons(&out.button, btn_val, theme);
    }
    if (root.get("checkbox")) |cb_val| {
        parseCheckbox(&out.checkbox, cb_val, theme);
    }
    if (root.get("text_input")) |ti_val| {
        parseTextInput(&out.text_input, ti_val, theme);
    }
    if (root.get("panel")) |panel_val| {
        parsePanel(&out.panel, panel_val, theme);
    }
    if (root.get("focus_ring")) |focus_val| {
        parseFocusRing(&out.focus_ring, focus_val, theme);
    }
    return out;
}

fn parseSurfaces(out: *SurfacesStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("background")) |bv| out.background = parsePaint(bv, theme) orelse out.background;
    if (obj.get("surface")) |sv| out.surface = parsePaint(sv, theme) orelse out.surface;
}

fn parseButtons(out: *ButtonStyles, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("primary")) |val| parseButtonVariant(&out.primary, val, theme);
    if (obj.get("secondary")) |val| parseButtonVariant(&out.secondary, val, theme);
    if (obj.get("ghost")) |val| parseButtonVariant(&out.ghost, val, theme);
}

fn parseButtonVariant(out: *ButtonVariantStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("radius")) |rv| out.radius = parseRadius(rv, theme) orelse out.radius;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("text")) |cv| out.text = parseColor(cv, theme) orelse out.text;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("states")) |sv| parseButtonStates(&out.states, sv, theme);
}

fn parseButtonStates(out: *ButtonVariantStates, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("hover")) |hv| parseButtonStateStyle(&out.hover, hv, theme);
    if (obj.get("pressed")) |pv| parseButtonStateStyle(&out.pressed, pv, theme);
    if (obj.get("disabled")) |dv| parseButtonStateStyle(&out.disabled, dv, theme);
    if (obj.get("focused")) |fv| parseButtonStateStyle(&out.focused, fv, theme);
}

fn parseButtonStateStyle(out: *ButtonVariantStateStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("text")) |cv| out.text = parseColor(cv, theme) orelse out.text;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
}

fn parseCheckbox(out: *CheckboxStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("radius")) |rv| out.radius = parseRadius(rv, theme) orelse out.radius;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("fill_checked")) |cv| out.fill_checked = parsePaint(cv, theme) orelse out.fill_checked;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("border_checked")) |cv| out.border_checked = parseColor(cv, theme) orelse out.border_checked;
    if (obj.get("check")) |cv| out.check = parseColor(cv, theme) orelse out.check;
    if (obj.get("states")) |sv| parseCheckboxStates(&out.states, sv, theme);
}

fn parseCheckboxStates(out: *CheckboxStates, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("hover")) |hv| parseCheckboxStateStyle(&out.hover, hv, theme);
    if (obj.get("pressed")) |pv| parseCheckboxStateStyle(&out.pressed, pv, theme);
    if (obj.get("disabled")) |dv| parseCheckboxStateStyle(&out.disabled, dv, theme);
    if (obj.get("focused")) |fv| parseCheckboxStateStyle(&out.focused, fv, theme);
}

fn parseCheckboxStateStyle(out: *CheckboxStateStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("fill_checked")) |cv| out.fill_checked = parsePaint(cv, theme) orelse out.fill_checked;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("border_checked")) |cv| out.border_checked = parseColor(cv, theme) orelse out.border_checked;
    if (obj.get("check")) |cv| out.check = parseColor(cv, theme) orelse out.check;
}

fn parseTextInput(out: *TextInputStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("radius")) |rv| out.radius = parseRadius(rv, theme) orelse out.radius;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("text")) |cv| out.text = parseColor(cv, theme) orelse out.text;
    if (obj.get("placeholder")) |cv| out.placeholder = parseColor(cv, theme) orelse out.placeholder;
    if (obj.get("selection")) |cv| out.selection = parseColor(cv, theme) orelse out.selection;
    if (obj.get("caret")) |cv| out.caret = parseColor(cv, theme) orelse out.caret;
    if (obj.get("states")) |sv| parseTextInputStates(&out.states, sv, theme);
}

fn parseTextInputStates(out: *TextInputStates, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("hover")) |hv| parseTextInputStateStyle(&out.hover, hv, theme);
    if (obj.get("pressed")) |pv| parseTextInputStateStyle(&out.pressed, pv, theme);
    if (obj.get("disabled")) |dv| parseTextInputStateStyle(&out.disabled, dv, theme);
    if (obj.get("focused")) |fv| parseTextInputStateStyle(&out.focused, fv, theme);
}

fn parseTextInputStateStyle(out: *TextInputStateStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("text")) |cv| out.text = parseColor(cv, theme) orelse out.text;
    if (obj.get("placeholder")) |cv| out.placeholder = parseColor(cv, theme) orelse out.placeholder;
    if (obj.get("selection")) |cv| out.selection = parseColor(cv, theme) orelse out.selection;
    if (obj.get("caret")) |cv| out.caret = parseColor(cv, theme) orelse out.caret;
}

fn parsePanel(out: *PanelStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("radius")) |rv| out.radius = parseRadius(rv, theme) orelse out.radius;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("content_inset_px")) |iv| out.content_inset_px = parseSlicesPx(iv) orelse out.content_inset_px;
    if (obj.get("overlay")) |ov| out.overlay = parsePaint(ov, theme) orelse out.overlay;
    if (obj.get("shadow")) |sv| {
        parseEffect(&out.shadow, sv, theme);
    }
    if (obj.get("frame")) |fv| {
        parsePanelFrame(out, fv, theme);
    }
}

fn parsePanelFrame(out: *PanelStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("image")) |iv| {
        if (iv == .string) out.frame_image.set(iv.string);
    }
    if (obj.get("slices_px")) |sv| {
        out.frame_slices_px = parseSlicesPx(sv) orelse out.frame_slices_px;
    }
    if (obj.get("tint")) |tv| {
        out.frame_tint = parseColor(tv, theme) orelse out.frame_tint;
    }
    if (obj.get("draw_center")) |bv| {
        if (bv == .bool) out.frame_draw_center = bv.bool;
    }
    if (obj.get("center_overlay")) |ov| {
        out.frame_center_overlay = parsePaint(ov, theme) orelse out.frame_center_overlay;
    }
    if (obj.get("tile_center")) |bv| {
        if (bv == .bool) {
            out.frame_tile_center = bv.bool;
            if (bv.bool) {
                out.frame_tile_center_x = true;
                out.frame_tile_center_y = true;
            }
        }
    }
    if (obj.get("center_mode")) |mv| {
        if (mv == .string) {
            if (std.ascii.eqlIgnoreCase(mv.string, "stretch")) {
                out.frame_tile_center = false;
            } else if (std.ascii.eqlIgnoreCase(mv.string, "tile") or std.ascii.eqlIgnoreCase(mv.string, "tile_xy")) {
                out.frame_tile_center = true;
                out.frame_tile_center_x = true;
                out.frame_tile_center_y = true;
            } else if (std.ascii.eqlIgnoreCase(mv.string, "tile_x")) {
                out.frame_tile_center = true;
                out.frame_tile_center_x = true;
                out.frame_tile_center_y = false;
            } else if (std.ascii.eqlIgnoreCase(mv.string, "tile_y")) {
                out.frame_tile_center = true;
                out.frame_tile_center_x = false;
                out.frame_tile_center_y = true;
            }
        }
    }
    if (obj.get("center_anchor")) |av| {
        if (av == .string) {
            if (std.ascii.eqlIgnoreCase(av.string, "end")) out.frame_tile_anchor_end = true;
            if (std.ascii.eqlIgnoreCase(av.string, "start")) out.frame_tile_anchor_end = false;
        }
    }
}

fn parseSlicesPx(v: std.json.Value) ?[4]f32 {
    if (v != .array) return null;
    if (v.array.items.len != 4) return null;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const item = v.array.items[i];
        out[i] = switch (item) {
            .float => @floatCast(item.float),
            .integer => @floatFromInt(item.integer),
            else => return null,
        };
    }
    return out;
}

fn parseFocusRing(out: *FocusRingStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("thickness")) |tv| {
        if (tv == .float) out.thickness = @floatCast(tv.float);
        if (tv == .integer) out.thickness = @floatFromInt(tv.integer);
    }
    if (obj.get("color")) |cv| out.color = parseColor(cv, theme) orelse out.color;
    if (obj.get("glow")) |gv| {
        parseEffect(&out.glow, gv, theme);
    }
}

fn parseRadius(v: std.json.Value, theme: *const theme_tokens.Theme) ?f32 {
    switch (v) {
        .float => return @floatCast(v.float),
        .integer => return @floatFromInt(v.integer),
        .string => return resolveRadiusToken(v.string, theme),
        else => return null,
    }
}

fn resolveRadiusToken(token: []const u8, theme: *const theme_tokens.Theme) ?f32 {
    if (!std.mem.startsWith(u8, token, "radius.")) return null;
    const key = token["radius.".len..];
    if (std.ascii.eqlIgnoreCase(key, "sm")) return theme.radius.sm;
    if (std.ascii.eqlIgnoreCase(key, "md")) return theme.radius.md;
    if (std.ascii.eqlIgnoreCase(key, "lg")) return theme.radius.lg;
    if (std.ascii.eqlIgnoreCase(key, "full")) return theme.radius.full;
    return null;
}

fn parseEffect(out: *EffectStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("color")) |cv| out.color = parseColor(cv, theme) orelse out.color;
    if (obj.get("blur_px")) |fv| out.blur_px = parseFloat(fv) orelse out.blur_px;
    if (obj.get("spread_px")) |fv| out.spread_px = parseFloat(fv) orelse out.spread_px;
    if (obj.get("offset")) |ov| out.offset = parseVec2(ov) orelse out.offset;
    if (obj.get("steps")) |sv| {
        if (sv == .integer and sv.integer >= 0 and sv.integer <= 255) out.steps = @intCast(sv.integer);
    }
    if (obj.get("blend")) |bv| out.blend = parseBlendMode(bv) orelse out.blend;
    if (obj.get("falloff_exp")) |fv| out.falloff_exp = parseFloat(fv) orelse out.falloff_exp;
    if (obj.get("ignore_clip")) |bv| {
        if (bv == .bool) out.ignore_clip = bv.bool;
    }
}

fn parseBlendMode(v: std.json.Value) ?BlendMode {
    if (v != .string) return null;
    if (std.ascii.eqlIgnoreCase(v.string, "alpha")) return .alpha;
    if (std.ascii.eqlIgnoreCase(v.string, "additive")) return .additive;
    return null;
}

fn parseFloat(v: std.json.Value) ?f32 {
    switch (v) {
        .float => return @floatCast(v.float),
        .integer => return @floatFromInt(v.integer),
        else => return null,
    }
}

fn parseVec2(v: std.json.Value) ?[2]f32 {
    if (v != .array) return null;
    if (v.array.items.len != 2) return null;
    const a = parseFloat(v.array.items[0]) orelse return null;
    const b = parseFloat(v.array.items[1]) orelse return null;
    return .{ a, b };
}

fn parseColor(v: std.json.Value, theme: *const theme_tokens.Theme) ?Color {
    switch (v) {
        .array => {
            if (v.array.items.len != 4) return null;
            var out: Color = .{ 0, 0, 0, 1 };
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const item = v.array.items[i];
                out[i] = switch (item) {
                    .float => @floatCast(item.float),
                    .integer => @as(f32, @floatFromInt(item.integer)),
                    else => return null,
                };
            }
            return out;
        },
        .string => {
            if (parseHexColor(v.string)) |c| return c;
            return resolveColorToken(v.string, theme);
        },
        else => return null,
    }
}

fn parsePaint(v: std.json.Value, theme: *const theme_tokens.Theme) ?Paint {
    // Back-compat: allow a color directly.
    if (parseColor(v, theme)) |c| return .{ .solid = c };

    // New: gradient/image object.
    if (v != .object) return null;
    const obj = v.object;
    if (obj.get("gradient4")) |grad_val| {
        if (grad_val != .object) return null;
        const g = grad_val.object;
        const tl = g.get("tl") orelse return null;
        const tr = g.get("tr") orelse return null;
        const bl = g.get("bl") orelse return null;
        const br = g.get("br") orelse return null;
        return .{ .gradient4 = .{
            .tl = parseColor(tl, theme) orelse return null,
            .tr = parseColor(tr, theme) orelse return null,
            .bl = parseColor(bl, theme) orelse return null,
            .br = parseColor(br, theme) orelse return null,
        } };
    }
    if (obj.get("image")) |img_val| {
        const paint = parseImagePaint(img_val, theme) orelse return null;
        return .{ .image = paint };
    }
    return null;
}

fn parseImagePaint(v: std.json.Value, theme: *const theme_tokens.Theme) ?ImagePaint {
    var out: ImagePaint = .{};
    switch (v) {
        .string => {
            out.path.set(v.string);
            return if (out.path.isSet()) out else null;
        },
        .object => {
            const obj = v.object;
            if (obj.get("path")) |pv| {
                if (pv == .string) out.path.set(pv.string);
            } else if (obj.get("image")) |iv| {
                // Allow `{ "image": { "image": "..." } }` for authoring convenience.
                if (iv == .string) out.path.set(iv.string);
            }
            if (obj.get("mode")) |mv| {
                if (mv == .string) {
                    if (std.ascii.eqlIgnoreCase(mv.string, "tile")) out.mode = .tile;
                    if (std.ascii.eqlIgnoreCase(mv.string, "stretch")) out.mode = .stretch;
                }
            }
            if (obj.get("scale")) |sv| {
                out.scale = parseFloat(sv) orelse out.scale;
            }
            if (obj.get("tint")) |tv| {
                out.tint = parseColor(tv, theme) orelse out.tint;
            }
            if (obj.get("offset_px")) |ov| {
                out.offset_px = parseVec2(ov) orelse out.offset_px;
            }
            return if (out.path.isSet()) out else null;
        },
        else => return null,
    }
}

fn resolveColorToken(token: []const u8, theme: *const theme_tokens.Theme) ?Color {
    if (!std.mem.startsWith(u8, token, "colors.")) return null;
    const key = token["colors.".len..];
    if (std.ascii.eqlIgnoreCase(key, "background")) return theme.colors.background;
    if (std.ascii.eqlIgnoreCase(key, "surface")) return theme.colors.surface;
    if (std.ascii.eqlIgnoreCase(key, "primary")) return theme.colors.primary;
    if (std.ascii.eqlIgnoreCase(key, "success")) return theme.colors.success;
    if (std.ascii.eqlIgnoreCase(key, "danger")) return theme.colors.danger;
    if (std.ascii.eqlIgnoreCase(key, "warning")) return theme.colors.warning;
    if (std.ascii.eqlIgnoreCase(key, "text_primary")) return theme.colors.text_primary;
    if (std.ascii.eqlIgnoreCase(key, "text_secondary")) return theme.colors.text_secondary;
    if (std.ascii.eqlIgnoreCase(key, "border")) return theme.colors.border;
    if (std.ascii.eqlIgnoreCase(key, "divider")) return theme.colors.divider;
    return null;
}

fn parseHexColor(s: []const u8) ?Color {
    if (s.len != 7 and s.len != 9) return null;
    if (s[0] != '#') return null;
    const rr = parseHexByte(s[1..3]) orelse return null;
    const gg = parseHexByte(s[3..5]) orelse return null;
    const bb = parseHexByte(s[5..7]) orelse return null;
    const aa: u8 = if (s.len == 9) (parseHexByte(s[7..9]) orelse return null) else 255;
    return .{
        @as(f32, @floatFromInt(rr)) / 255.0,
        @as(f32, @floatFromInt(gg)) / 255.0,
        @as(f32, @floatFromInt(bb)) / 255.0,
        @as(f32, @floatFromInt(aa)) / 255.0,
    };
}

fn parseHexByte(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = hexNibble(s[0]) orelse return null;
    const lo = hexNibble(s[1]) orelse return null;
    return (hi << 4) | lo;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}
