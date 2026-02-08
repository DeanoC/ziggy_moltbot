const std = @import("std");
const nav = @import("nav.zig");

// Per-window navigation state is stored by the caller (WindowUiState).
// During drawing we set a global pointer so widgets can register focusable rects
// without threading a nav pointer through every call site.

var active_nav: ?*nav.NavState = null;

var scope_stack: [16]u64 = .{0} ** 16;
var scope_len: usize = 0;

pub fn set(nav_state: ?*nav.NavState) void {
    active_nav = nav_state;
    scope_len = 0;
}

pub fn get() ?*nav.NavState {
    return active_nav;
}

pub fn pushScope(scope: u64) void {
    if (scope_len >= scope_stack.len) return;
    scope_stack[scope_len] = scope;
    scope_len += 1;
}

pub fn popScope() void {
    if (scope_len == 0) return;
    scope_len -= 1;
}

fn scopeSeed() u64 {
    var seed: u64 = 0;
    var i: usize = 0;
    while (i < scope_len) : (i += 1) {
        seed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&scope_stack[i]));
    }
    return seed;
}

pub fn makeWidgetId(ra: usize, kind: []const u8, label: []const u8) u64 {
    var seed = scopeSeed();
    seed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&ra));
    seed = std.hash.Wyhash.hash(seed, kind);
    seed = std.hash.Wyhash.hash(seed, label);
    return seed;
}

pub fn wasActivated(queue: anytype, id: u64) bool {
    for (queue.events.items) |evt| {
        if (evt == .nav_activate and evt.nav_activate == id) return true;
    }
    return false;
}
