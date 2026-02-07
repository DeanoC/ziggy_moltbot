const std = @import("std");

const theme_tokens = @import("../theme/theme.zig");

pub const Color = [4]f32;

pub const Gradient4 = struct {
    tl: Color,
    tr: Color,
    bl: Color,
    br: Color,
};

pub const Paint = union(enum) {
    solid: Color,
    gradient4: Gradient4,
};

pub const ButtonVariantStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    text: ?Color = null,
    border: ?Color = null,
};

pub const ButtonStyles = struct {
    primary: ButtonVariantStyle = .{},
    secondary: ButtonVariantStyle = .{},
    ghost: ButtonVariantStyle = .{},
};

pub const PanelStyle = struct {
    radius: ?f32 = null,
    fill: ?Paint = null,
    border: ?Color = null,
    frame_image: ?[]const u8 = null,
    frame_slices_px: ?[4]f32 = null,
    frame_tint: ?Color = null,
};

pub const FocusRingStyle = struct {
    thickness: ?f32 = null,
    color: ?Color = null,
};

/// Resolved style sheet (no allocations).
pub const StyleSheet = struct {
    button: ButtonStyles = .{},
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

    if (root.get("button")) |btn_val| {
        parseButtons(&out.button, btn_val, theme);
    }
    if (root.get("panel")) |panel_val| {
        parsePanel(&out.panel, panel_val, theme);
    }
    if (root.get("focus_ring")) |focus_val| {
        parseFocusRing(&out.focus_ring, focus_val, theme);
    }
    return out;
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
}

fn parsePanel(out: *PanelStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("radius")) |rv| out.radius = parseRadius(rv, theme) orelse out.radius;
    if (obj.get("fill")) |cv| out.fill = parsePaint(cv, theme) orelse out.fill;
    if (obj.get("border")) |cv| out.border = parseColor(cv, theme) orelse out.border;
    if (obj.get("frame")) |fv| {
        parsePanelFrame(out, fv, theme);
    }
}

fn parsePanelFrame(out: *PanelStyle, v: std.json.Value, theme: *const theme_tokens.Theme) void {
    if (v != .object) return;
    const obj = v.object;
    if (obj.get("image")) |iv| {
        if (iv == .string) out.frame_image = iv.string;
    }
    if (obj.get("slices_px")) |sv| {
        out.frame_slices_px = parseSlicesPx(sv) orelse out.frame_slices_px;
    }
    if (obj.get("tint")) |tv| {
        out.frame_tint = parseColor(tv, theme) orelse out.frame_tint;
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

    // New: gradient object.
    if (v != .object) return null;
    const obj = v.object;
    const grad_val = obj.get("gradient4") orelse return null;
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
