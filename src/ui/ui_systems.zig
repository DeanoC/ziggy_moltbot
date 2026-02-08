const std = @import("std");
const systems = @import("systems/systems.zig");
const input_router = @import("input/input_router.zig");
const draw_context = @import("draw_context.zig");

var global_systems: ?systems.Systems = null;
var frame_now_ns: i128 = 0;
var last_frame_ns: i128 = 0;
var frame_dt_s: f32 = 1.0 / 60.0;

pub fn beginFrame() *systems.Systems {
    // Use a monotonic clock so time changes (NTP/manual adjustments) don't break inertial animations.
    frame_now_ns = std.time.nanoTimestamp();
    if (last_frame_ns != 0) {
        const delta_ns: i128 = frame_now_ns - last_frame_ns;
        const raw_dt: f32 = @as(f32, @floatFromInt(delta_ns)) / 1_000_000_000.0;
        // Clamp to keep physics stable across hitches and also avoid divide-by-zero.
        frame_dt_s = std.math.clamp(raw_dt, 1.0 / 240.0, 0.2);
    }
    last_frame_ns = frame_now_ns;

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

pub fn frameNowMs() i64 {
    return @intCast(@divTrunc(frame_now_ns, 1_000_000));
}

pub fn frameDtSeconds() f32 {
    return frame_dt_s;
}

pub fn get() *systems.Systems {
    if (global_systems == null) {
        global_systems = systems.Systems.init(std.heap.page_allocator);
    }
    return &global_systems.?;
}
