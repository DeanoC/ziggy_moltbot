const std = @import("std");
const input_events = @import("../input/input_events.zig");
const input_router = @import("../input/input_router.zig");
const input_state = @import("../input/input_state.zig");

pub const Scope = enum {
    global,
    focused,
};

pub const Shortcut = struct {
    id: []const u8,
    key: input_events.Key,
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
        const queue = input_router.getQueue();
        for (self.shortcuts.items) |shortcut| {
            if (!shortcut.enabled) continue;
            if (!scopeMatches(shortcut, self.focused_id)) continue;
            if (!modifiersMatch(shortcut, queue.state.modifiers)) continue;
            if (wasKeyPressed(queue, shortcut.key)) {
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

fn modifiersMatch(shortcut: Shortcut, mods: input_events.Modifiers) bool {
    if (shortcut.ctrl != mods.ctrl) return false;
    if (shortcut.shift != mods.shift) return false;
    if (shortcut.alt != mods.alt) return false;
    if (shortcut.super != mods.super) return false;
    return true;
}

fn wasKeyPressed(queue: *input_state.InputQueue, key: input_events.Key) bool {
    for (queue.events.items) |evt| {
        if (evt == .key_down) {
            const kd = evt.key_down;
            if (kd.key == key and !kd.repeat) return true;
        }
    }
    return false;
}
