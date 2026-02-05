const std = @import("std");
const systems = @import("systems/systems.zig");
const input_router = @import("input/input_router.zig");
const draw_context = @import("draw_context.zig");

var global_systems: ?systems.Systems = null;

pub fn beginFrame() *systems.Systems {
    const sys = get();
    sys.beginFrame();
    sys.keyboard.clear();
    sys.keyboard.setFocus(null);
    return sys;
}

pub fn endFrame(dc: *draw_context.DrawContext) void {
    if (global_systems) |*sys| {
        sys.keyboard.handle();
        const queue = input_router.getQueue();
        sys.drag_drop.drawPreview(dc, queue.state.mouse_pos);
        if (sys.drag_drop.active_drag != null) {
            var released = false;
            for (queue.events.items) |evt| {
                if (evt == .mouse_up and evt.mouse_up.button == .left) {
                    released = true;
                    break;
                }
            }
            if (released) {
                _ = sys.drag_drop.endDrag(queue.state.mouse_pos);
            }
        }
    }
}

pub fn get() *systems.Systems {
    if (global_systems == null) {
        global_systems = systems.Systems.init(std.heap.page_allocator);
    }
    return &global_systems.?;
}
