const std = @import("std");
const zgui = @import("zgui");

pub const Scope = enum {
    global,
    focused,
};

pub const Shortcut = struct {
    id: []const u8,
    key: zgui.Key,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    enabled: bool = true,
    scope: Scope = .global,
    focus_id: ?[]const u8 = null,
    action: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const KeyboardManager = struct {
    shortcuts: std.ArrayList(Shortcut),
    focused_id: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeyboardManager {
        return .{
            .shortcuts = .empty,
            .focused_id = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeyboardManager) void {
        self.shortcuts.deinit(self.allocator);
    }

    pub fn beginFrame(self: *KeyboardManager) void {
        _ = self;
    }

    pub fn clear(self: *KeyboardManager) void {
        self.shortcuts.clearRetainingCapacity();
    }

    pub fn register(self: *KeyboardManager, shortcut: Shortcut) !void {
        try self.shortcuts.append(self.allocator, shortcut);
    }

    pub fn setFocus(self: *KeyboardManager, id: ?[]const u8) void {
        self.focused_id = id;
    }

    pub fn handle(self: *KeyboardManager) void {
        for (self.shortcuts.items) |shortcut| {
            if (!shortcut.enabled) continue;
            if (!scopeMatches(shortcut, self.focused_id)) continue;
            if (!modifiersMatch(shortcut)) continue;
            if (zgui.isKeyPressed(shortcut.key, false)) {
                if (shortcut.action) |action| {
                    action(shortcut.ctx);
                }
            }
        }
    }
};

fn scopeMatches(shortcut: Shortcut, focused_id: ?[]const u8) bool {
    return switch (shortcut.scope) {
        .global => true,
        .focused => blk: {
            if (focused_id == null) break :blk false;
            if (shortcut.focus_id == null) break :blk true;
            break :blk std.mem.eql(u8, shortcut.focus_id.?, focused_id.?);
        },
    };
}

fn modifiersMatch(shortcut: Shortcut) bool {
    if (shortcut.ctrl != modifierDown(.left_ctrl, .right_ctrl)) return false;
    if (shortcut.shift != modifierDown(.left_shift, .right_shift)) return false;
    if (shortcut.alt != modifierDown(.left_alt, .right_alt)) return false;
    if (shortcut.super != modifierDown(.left_super, .right_super)) return false;
    return true;
}

fn modifierDown(left: zgui.Key, right: zgui.Key) bool {
    return zgui.isKeyDown(left) or zgui.isKeyDown(right);
}
