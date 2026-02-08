const std = @import("std");
const draw_context = @import("../draw_context.zig");
const input_state = @import("../input/input_state.zig");
const ui_systems = @import("../ui_systems.zig");

// Kinetic / inertial scrolling for touch + pen drag scrolling.
//
// This is intentionally global and keyed by the scroll pointer address so views can
// stay immediate-mode while still getting persistent inertia state.

const State = struct {
    // Scroll velocity in "scroll units per second" (typically pixels/sec).
    velocity_y: f32 = 0.0,
    // When true, inertia continues applying even if the pointer is no longer over `rect`.
    inertia_active: bool = false,
    // Capture touch/pen drags that started inside this rect until pointer-up.
    drag_captured: bool = false,
    // Tracks whether we were dragging last frame (used for release detection).
    was_dragging: bool = false,
    last_seen_ms: i64 = 0,
};

var states: std.AutoHashMapUnmanaged(usize, State) = .{};
var gc_counter: u32 = 0;

fn keyForScroll(scroll_y: *f32) usize {
    return @intFromPtr(scroll_y);
}

fn getState(scroll_y: *f32) *State {
    const k = keyForScroll(scroll_y);
    const gpa = std.heap.page_allocator;
    const entry = states.getOrPut(gpa, k) catch {
        // Best-effort: if we can't allocate, fall back to no inertia state.
        // Returning a pointer requires storage, so just use a static.
        // This disables inertia under allocation pressure.
        return &fallback_state;
    };
    if (!entry.found_existing) {
        entry.value_ptr.* = .{};
    }
    entry.value_ptr.last_seen_ms = ui_systems.frameNowMs();
    return entry.value_ptr;
}

var fallback_state: State = .{};

fn clampScroll(scroll_y: *f32, max_scroll: f32) void {
    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
    if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
}

fn gcMaybe(now_ms: i64) void {
    // Remove abandoned states to avoid pointer-reuse collisions if panels are destroyed/recreated.
    // Run occasionally to keep overhead low.
    gc_counter +%= 1;
    if ((gc_counter & 0x7f) != 0) return; // every 128 calls

    const stale_after_ms: i64 = 10_000;
    var to_remove: [64]usize = undefined;
    var remove_len: usize = 0;

    var it = states.iterator();
    while (it.next()) |entry| {
        const st = entry.value_ptr.*;
        if (st.inertia_active or st.drag_captured or st.was_dragging) continue;
        if (now_ms - st.last_seen_ms <= stale_after_ms) continue;
        if (remove_len < to_remove.len) {
            to_remove[remove_len] = entry.key_ptr.*;
            remove_len += 1;
        }
    }
    if (remove_len == 0) return;

    var i: usize = 0;
    while (i < remove_len) : (i += 1) {
        _ = states.remove(to_remove[i]);
    }
}

pub fn apply(
    queue: *input_state.InputQueue,
    rect: draw_context.Rect,
    scroll_y: *f32,
    max_scroll: f32,
    wheel_step: f32,
) void {
    const now_ms = ui_systems.frameNowMs();
    gcMaybe(now_ms);

    var st = getState(scroll_y);

    if (max_scroll <= 0.0) {
        scroll_y.* = 0.0;
        st.velocity_y = 0.0;
        st.inertia_active = false;
        st.drag_captured = false;
        st.was_dragging = false;
        return;
    }

    const hover = rect.contains(queue.state.mouse_pos);
    const is_touch_like = queue.state.pointer_kind == .touch or queue.state.pointer_kind == .pen;
    const has_drag_delta = queue.state.pointer_drag_delta[0] != 0.0 or queue.state.pointer_drag_delta[1] != 0.0;
    const dragging = is_touch_like and queue.state.mouse_down_left and (queue.state.pointer_dragging or has_drag_delta);

    // Mouse wheel scrolling (hover-only).
    if (hover) {
        var wheel_delta_y: f32 = 0.0;
        for (queue.events.items) |evt| {
            if (evt == .mouse_wheel) {
                wheel_delta_y += evt.mouse_wheel.delta[1];
            }
        }
        if (wheel_delta_y != 0.0) {
            scroll_y.* -= wheel_delta_y * wheel_step;
            clampScroll(scroll_y, max_scroll);
            // Wheel input cancels inertia.
            st.velocity_y = 0.0;
            st.inertia_active = false;
        }
    }

    // Touch/pen drag scrolling.
    if (dragging and (hover or st.drag_captured)) {
        // Capture on the first dragging frame that begins inside the rect.
        if (!st.drag_captured and hover) {
            st.drag_captured = true;
        }

        const delta_scroll_y: f32 = -queue.state.pointer_drag_delta[1];
        if (delta_scroll_y != 0.0) {
            const dt = ui_systems.frameDtSeconds();
            const inst_vel: f32 = delta_scroll_y / dt;
            // Smooth velocity so inertia feels less jittery on inconsistent frame deltas.
            st.velocity_y = st.velocity_y * 0.65 + inst_vel * 0.35;
        }

        scroll_y.* += delta_scroll_y;
        clampScroll(scroll_y, max_scroll);

        st.inertia_active = false;
        st.was_dragging = true;
        return;
    }

    // Release detection: we were dragging, but no longer are.
    if (st.was_dragging and !dragging) {
        st.was_dragging = false;
        st.drag_captured = false;

        const min_start_vel: f32 = 60.0; // px/s
        if (@abs(st.velocity_y) >= min_start_vel) {
            st.inertia_active = true;
        } else {
            st.velocity_y = 0.0;
            st.inertia_active = false;
        }
    }

    // Inertial scroll update.
    if (st.inertia_active) {
        const dt = ui_systems.frameDtSeconds();
        scroll_y.* += st.velocity_y * dt;

        // Exponential decay.
        const friction: f32 = 10.0; // higher = stops sooner
        st.velocity_y *= std.math.exp(-friction * dt);

        // Stop at bounds.
        if (scroll_y.* <= 0.0) {
            scroll_y.* = 0.0;
            if (st.velocity_y < 0.0) {
                st.velocity_y = 0.0;
                st.inertia_active = false;
            }
        } else if (scroll_y.* >= max_scroll) {
            scroll_y.* = max_scroll;
            if (st.velocity_y > 0.0) {
                st.velocity_y = 0.0;
                st.inertia_active = false;
            }
        }

        const stop_vel: f32 = 15.0;
        if (@abs(st.velocity_y) < stop_vel) {
            st.velocity_y = 0.0;
            st.inertia_active = false;
        }
    }
}
