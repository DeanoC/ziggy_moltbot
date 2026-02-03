const std = @import("std");
const zgui = @import("zgui");
const systems = @import("systems/systems.zig");

var global_systems: ?systems.Systems = null;

pub fn beginFrame() *systems.Systems {
    const sys = get();
    sys.beginFrame();
    sys.keyboard.clear();
    sys.keyboard.setFocus(null);
    return sys;
}

pub fn endFrame() void {
    if (global_systems) |*sys| {
        sys.keyboard.handle();
        sys.drag_drop.drawPreview();
        if (sys.drag_drop.active_drag != null and zgui.isMouseReleased(.left)) {
            _ = sys.drag_drop.endDrag();
        }
    }
}

pub fn get() *systems.Systems {
    if (global_systems == null) {
        global_systems = systems.Systems.init(std.heap.page_allocator);
    }
    return &global_systems.?;
}
