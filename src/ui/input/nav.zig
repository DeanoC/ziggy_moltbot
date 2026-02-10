const std = @import("std");

const draw_context = @import("../draw_context.zig");
const input_events = @import("input_events.zig");
const input_state = @import("input_state.zig");
const theme_runtime = @import("../theme_engine/runtime.zig");

pub const NavItem = struct {
    id: u64,
    rect: draw_context.Rect,
    enabled: bool = true,

    pub fn center(self: NavItem) [2]f32 {
        return .{
            (self.rect.min[0] + self.rect.max[0]) * 0.5,
            (self.rect.min[1] + self.rect.max[1]) * 0.5,
        };
    }
};

pub const MoveDir = enum {
    left,
    right,
    up,
    down,
};

pub const FrameActions = struct {
    activate: bool = false,
    back: bool = false,
    menu: bool = false,
};

pub const NavState = struct {
    // When true, we override mouse position and generate synthetic clicks.
    active: bool = false,

    // Selection state based on the previous frame's registered items.
    focused_id: ?u64 = null,
    focused_idx_fallback: usize = 0,
    cursor_pos: [2]f32 = .{ 0.0, 0.0 },

    // Simple time-based repeat for stick/dpad.
    last_move_ms: i64 = 0,
    last_axis_ms: i64 = 0,
    axis_held_dir: ?MoveDir = null,

    // Trigger-based fast scroll (mapped to synthetic mouse wheel events).
    left_trigger: i16 = 0,
    right_trigger: i16 = 0,
    trigger_scroll_accum: f32 = 0.0,
    last_frame_ms: i64 = 0,

    // Items are collected during drawing (curr) and used next frame (prev).
    prev_items: std.ArrayList(NavItem) = .empty,
    curr_items: std.ArrayList(NavItem) = .empty,

    // Latched actions for the current frame (consumed by the caller).
    actions: FrameActions = .{},

    pub fn deinit(self: *NavState, allocator: std.mem.Allocator) void {
        self.prev_items.deinit(allocator);
        self.curr_items.deinit(allocator);
        self.* = undefined;
    }

    pub fn isActive(self: *const NavState) bool {
        return self.active;
    }

    pub fn beginFrame(self: *NavState, allocator: std.mem.Allocator, viewport: draw_context.Rect, queue: *input_state.InputQueue) void {
        const now_ms = std.time.milliTimestamp();
        const dt_s: f32 = blk: {
            if (self.last_frame_ms == 0) break :blk 1.0 / 60.0;
            const raw: f32 = @as(f32, @floatFromInt(now_ms - self.last_frame_ms)) / 1000.0;
            break :blk std.math.clamp(raw, 1.0 / 240.0, 0.2);
        };
        self.last_frame_ms = now_ms;

        // Default: keep the previous state, but always enable in controller-first profiles.
        const p = theme_runtime.getProfile();
        if (p.modality == .controller) self.active = true;

        // If the user uses the mouse/touch this frame, don't fight them.
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_move, .mouse_down, .mouse_up, .mouse_wheel => {
                    if (p.modality != .controller) self.active = false;
                },
                else => {},
            }
        }

        self.actions = .{};
        self.handleInputs(queue);

        // Apply current selection to the input queue before widgets look at it.
        if (self.active) {
            if (self.prev_items.items.len == 0) {
                self.cursor_pos = .{
                    (viewport.min[0] + viewport.max[0]) * 0.5,
                    (viewport.min[1] + viewport.max[1]) * 0.5,
                };
            } else {
                if (self.focused_id) |id| {
                    if (findItemById(self.prev_items.items, id)) |it| {
                        self.cursor_pos = it.center();
                    } else {
                        // Focused item disappeared; fall back to a stable index in draw order.
                        self.focused_idx_fallback = @min(self.focused_idx_fallback, self.prev_items.items.len - 1);
                        const it = self.prev_items.items[self.focused_idx_fallback];
                        self.focused_id = it.id;
                        self.cursor_pos = it.center();
                    }
                } else {
                    self.focused_idx_fallback = @min(self.focused_idx_fallback, self.prev_items.items.len - 1);
                    const it = self.prev_items.items[self.focused_idx_fallback];
                    self.focused_id = it.id;
                    self.cursor_pos = it.center();
                }
            }

            queue.state.mouse_pos = self.cursor_pos;
            queue.state.pointer_kind = .nav;
            queue.state.pointer_drag_delta = .{ 0.0, 0.0 };
            queue.state.pointer_dragging = false;

            if (self.actions.activate) {
                if (self.focused_id) |id| {
                    queue.push(allocator, .{ .nav_activate = id });
                }
            }

            // Fast scroll using triggers (LT/RT). This is implemented as synthetic mouse wheel
            // events so existing scroll handlers (hover-only) work with the nav cursor.
            //
            // We only enable this in controller-first profiles to avoid surprising desktop users.
            if (p.modality == .controller and self.prev_items.items.len != 0 and self.focused_id != null) {
                const dead: i16 = 6000;
                const lt: i16 = if (self.left_trigger > dead) self.left_trigger else 0;
                const rt: i16 = if (self.right_trigger > dead) self.right_trigger else 0;
                var dir: i32 = 0;
                if (rt != 0 and lt == 0) dir = 1; // page/scroll down
                if (lt != 0 and rt == 0) dir = -1; // page/scroll up

                if (dir != 0) {
                    const mag: f32 = if (dir > 0) @as(f32, @floatFromInt(rt)) else @as(f32, @floatFromInt(lt));
                    const maxv: f32 = 32767.0;
                    const intensity = std.math.clamp((mag - @as(f32, @floatFromInt(dead))) / (maxv - @as(f32, @floatFromInt(dead))), 0.0, 1.0);
                    const notches_per_s: f32 = 26.0 + 22.0 * intensity; // ~26..48 wheel notches/sec
                    self.trigger_scroll_accum += @as(f32, @floatFromInt(dir)) * notches_per_s * dt_s;

                    // Convert accumulated notches into wheel events.
                    while (self.trigger_scroll_accum >= 1.0) : (self.trigger_scroll_accum -= 1.0) {
                        // Down scroll increases scroll_y, so wheel delta must be negative.
                        queue.push(allocator, .{ .mouse_wheel = .{ .delta = .{ 0.0, -1.0 } } });
                    }
                    while (self.trigger_scroll_accum <= -1.0) : (self.trigger_scroll_accum += 1.0) {
                        queue.push(allocator, .{ .mouse_wheel = .{ .delta = .{ 0.0, 1.0 } } });
                    }
                } else {
                    // Reset accumulator so swapping directions doesn't cause a jump.
                    self.trigger_scroll_accum = 0.0;
                }
            }
        }

        self.curr_items.clearRetainingCapacity();
    }

    pub fn endFrame(self: *NavState, allocator: std.mem.Allocator) void {
        _ = allocator;
        // Swap item lists for next frame.
        std.mem.swap(@TypeOf(self.prev_items), &self.prev_items, &self.curr_items);
    }

    pub fn registerItem(self: *NavState, allocator: std.mem.Allocator, id: u64, rect: draw_context.Rect) void {
        _ = self.curr_items.append(allocator, .{ .id = id, .rect = rect }) catch {};
    }

    pub fn isFocusedRect(self: *const NavState, rect: draw_context.Rect, queue: *const input_state.InputQueue) bool {
        if (!self.active) return false;
        return rect.contains(queue.state.mouse_pos);
    }

    pub fn isFocusedId(self: *const NavState, id: u64) bool {
        if (!self.active) return false;
        return self.focused_id != null and self.focused_id.? == id;
    }

    fn handleInputs(self: *NavState, queue: *input_state.InputQueue) void {
        const now_ms = std.time.milliTimestamp();

        for (queue.events.items) |evt| {
            switch (evt) {
                .gamepad_button_down => |gb| {
                    _ = gb;
                    // Any gamepad activity implies nav intent.
                    self.active = true;
                },
                .gamepad_axis => |ga| {
                    _ = ga;
                    self.active = true;
                },
                else => {},
            }
        }

        // Digital: D-pad and common buttons.
        for (queue.events.items) |evt| {
            switch (evt) {
                .gamepad_button_down => |gb| switch (gb.button) {
                    .dpad_left => self.move(.left, now_ms),
                    .dpad_right => self.move(.right, now_ms),
                    .dpad_up => self.move(.up, now_ms),
                    .dpad_down => self.move(.down, now_ms),
                    .south => self.actions.activate = true,
                    .east => self.actions.back = true,
                    .start => self.actions.menu = true,
                    .left_shoulder => self.cycle(-1),
                    .right_shoulder => self.cycle(1),
                    else => {},
                },
                .key_down => |kd| switch (kd.key) {
                    .left_arrow => self.move(.left, now_ms),
                    .right_arrow => self.move(.right, now_ms),
                    .up_arrow => self.move(.up, now_ms),
                    .down_arrow => self.move(.down, now_ms),
                    .enter, .keypad_enter => self.actions.activate = true,
                    .back_space => self.actions.back = true,
                    else => {},
                },
                .gamepad_axis => |ga| {
                    // Light stick support: if the axis is held, emit repeat moves.
                    switch (ga.axis) {
                        .left_x, .left_y => self.handleLeftStick(ga, now_ms),
                        .left_trigger => self.left_trigger = ga.value,
                        .right_trigger => self.right_trigger = ga.value,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn handleLeftStick(self: *NavState, ga: input_events.GamepadAxisEvent, now_ms: i64) void {
        // Deadzone and repeat gating.
        const v = ga.value;
        const dead: i16 = 14000;
        const repeat_ms: i64 = 140;

        const dir: ?MoveDir = switch (ga.axis) {
            .left_x => if (v < -dead) .left else if (v > dead) .right else null,
            .left_y => if (v < -dead) .up else if (v > dead) .down else null,
            else => null,
        };

        if (dir == null) {
            self.axis_held_dir = null;
            return;
        }

        if (self.axis_held_dir == null or self.axis_held_dir.? != dir.?) {
            self.axis_held_dir = dir;
            self.last_axis_ms = 0;
        }

        if (self.last_axis_ms == 0 or (now_ms - self.last_axis_ms) >= repeat_ms) {
            self.last_axis_ms = now_ms;
            self.move(dir.?, now_ms);
        }
    }

    fn cycle(self: *NavState, delta: i32) void {
        if (self.prev_items.items.len == 0) return;
        const len_i = @as(i32, @intCast(self.prev_items.items.len));
        var idx_i = @as(i32, @intCast(@min(self.focused_idx_fallback, self.prev_items.items.len - 1)));
        idx_i = @mod(idx_i + delta, len_i);
        self.focused_idx_fallback = @as(usize, @intCast(idx_i));
        self.focused_id = self.prev_items.items[self.focused_idx_fallback].id;
    }

    fn move(self: *NavState, dir: MoveDir, now_ms: i64) void {
        // Rate limit repeated moves (dpad/key repeat can be fast).
        const repeat_ms: i64 = 90;
        if (self.last_move_ms != 0 and (now_ms - self.last_move_ms) < repeat_ms) return;
        self.last_move_ms = now_ms;

        if (self.prev_items.items.len == 0) return;

        const from = if (self.focused_id) |id|
            (findItemById(self.prev_items.items, id) orelse self.prev_items.items[@min(self.focused_idx_fallback, self.prev_items.items.len - 1)]).center()
        else
            self.prev_items.items[@min(self.focused_idx_fallback, self.prev_items.items.len - 1)].center();

        var best_idx: ?usize = null;
        var best_score: f32 = 0.0;

        for (self.prev_items.items, 0..) |it, idx| {
            if (self.focused_id != null and it.id == self.focused_id.?) continue;
            const c = it.center();
            const dx = c[0] - from[0];
            const dy = c[1] - from[1];

            const ok = switch (dir) {
                .left => dx < -0.001,
                .right => dx > 0.001,
                .up => dy < -0.001,
                .down => dy > 0.001,
            };
            if (!ok) continue;

            const score: f32 = switch (dir) {
                .left, .right => @abs(dx) + @abs(dy) * 0.5,
                .up, .down => @abs(dy) + @abs(dx) * 0.5,
            };

            if (best_idx == null or score < best_score) {
                best_idx = idx;
                best_score = score;
            }
        }

        if (best_idx) |idx| {
            self.focused_idx_fallback = idx;
            self.focused_id = self.prev_items.items[idx].id;
        }
    }
};

fn findItemById(items: []const NavItem, id: u64) ?NavItem {
    for (items) |it| {
        if (it.id == id) return it;
    }
    return null;
}
