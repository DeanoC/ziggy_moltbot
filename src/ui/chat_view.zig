const std = @import("std");
const types = @import("../protocol/types.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const image_cache = @import("image_cache.zig");
const components = @import("components/components.zig");
const theme = @import("theme.zig");
const draw_context = @import("draw_context.zig");
const clipboard = @import("clipboard.zig");
const input_state = @import("input/input_state.zig");
const text_editor = @import("widgets/text_editor.zig");
const profiler = @import("../utils/profiler.zig");

pub const ChatViewOptions = struct {
    select_copy_mode: bool = false,
    show_tool_output: bool = false,
};

pub const ViewState = struct {
    scroll_y: f32 = 0.0,
    follow_tail: bool = true,
    scrollbar_dragging: bool = false,
    scrollbar_drag_anchor: f32 = 0.0,
    scrollbar_drag_scroll: f32 = 0.0,
    focused: bool = false,
    selecting: bool = false,
    selection_anchor: ?usize = null,
    selection_focus: ?usize = null,
    last_session_hash: u64 = 0,
    last_message_count: usize = 0,
    last_last_id_hash: u64 = 0,
    last_last_len: usize = 0,
    last_stream_len: usize = 0,
    last_show_tool_output: bool = false,
    select_copy_editor: ?text_editor.TextEditor = null,
    message_cache: ?std.StringHashMap(MessageCache) = null,
    virt: VirtualState = .{},
};

const Line = struct {
    start: usize,
    end: usize,
};

const WrappedLine = struct {
    start: usize,
    end: usize,
    style: LineStyle,
};

const LineStyle = enum {
    normal,
    heading,
    quote,
    list,
    code,
};

const SourceLine = struct {
    start: usize,
    end: usize,
    style: LineStyle,
};

const DisplayText = struct {
    text: []const u8,
    owned: bool,
    sources: std.ArrayList(SourceLine),

    pub fn deinit(self: *DisplayText, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.text);
        }
        self.sources.deinit(allocator);
    }
};

const MessageLayout = struct {
    height: f32,
    text_len: usize,
    hover_index: ?usize,
};

const MessageCache = struct {
    content_len: usize,
    attachments_hash: u64,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    height: f32,
    text_len: usize,
};

const VirtualItemKind = enum {
    message,
    stream,
};

const VirtualItem = struct {
    kind: VirtualItemKind,
    // For kind == .message: index into the `messages` slice this frame.
    // For kind == .stream: ignored.
    msg_index: usize = 0,
    height: f32 = 0.0,
    text_len: usize = 0,
};

const VirtualState = struct {
    items: std.ArrayListUnmanaged(VirtualItem) = .{},
    // Prefix sum of per-item vertical stride (height + gap) in content space.
    // Length is always items.len + 1, with prefix_strides[0] = 0.
    prefix_strides: std.ArrayListUnmanaged(f32) = .{},
    // Prefix sum of per-item selectable text units (text_len + separator_len).
    // Length is always items.len + 1, with prefix_doc_units[0] = 0.
    prefix_doc_units: std.ArrayListUnmanaged(usize) = .{},

    scanned_message_count: usize = 0,
    scanned_last_id_hash: u64 = 0,

    built_for_session_hash: u64 = 0,
    built_for_show_tool_output: bool = false,
    built_for_bubble_width: f32 = 0.0,
    built_for_line_height: f32 = 0.0,
    built_for_padding: f32 = 0.0,
    built_for_gap: f32 = 0.0,

    pub fn deinit(self: *VirtualState, allocator: std.mem.Allocator) void {
        self.reset(allocator);
    }

    pub fn reset(self: *VirtualState, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.prefix_strides.deinit(allocator);
        self.prefix_doc_units.deinit(allocator);
        self.items = .{};
        self.prefix_strides = .{};
        self.prefix_doc_units = .{};
        self.scanned_message_count = 0;
        self.scanned_last_id_hash = 0;
        self.built_for_session_hash = 0;
        self.built_for_show_tool_output = false;
        self.built_for_bubble_width = 0.0;
        self.built_for_line_height = 0.0;
        self.built_for_padding = 0.0;
        self.built_for_gap = 0.0;
    }
};

pub fn deinit(state: *ViewState, allocator: std.mem.Allocator) void {
    if (state.select_copy_editor) |*editor| {
        editor.deinit(allocator);
    }
    state.select_copy_editor = null;
    clearMessageCache(state, allocator);
    state.virt.deinit(allocator);
}

pub fn hasSelectCopySelection(state: *const ViewState) bool {
    if (state.select_copy_editor) |editor| {
        return editor.hasSelection();
    }
    return false;
}

pub fn copySelectCopySelectionToClipboard(allocator: std.mem.Allocator, state: *ViewState) void {
    if (state.select_copy_editor) |*editor| {
        _ = editor.copySelectionToClipboard(allocator);
    }
}

pub fn hasSelection(state: *const ViewState) bool {
    return selectionRange(state) != null;
}

pub fn copyAllToClipboard(
    allocator: std.mem.Allocator,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) void {
    if (ensureChatBuffer(allocator, messages, stream_text, inbox, show_tool_output)) {
        const zbuf = bufferZ();
        clipboard.setTextZ(zbuf);
    }
}

pub fn copySelectionToClipboard(
    allocator: std.mem.Allocator,
    state: *const ViewState,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) void {
    const range = selectionRange(state) orelse return;
    const buf = buildSelectableBuffer(allocator, messages, stream_text, inbox, show_tool_output) orelse return;
    defer allocator.free(buf);
    if (buf.len == 0) return;
    const start = @min(range[0], buf.len);
    const end = @min(range[1], buf.len);
    if (start >= end) return;
    const out = allocator.alloc(u8, end - start + 1) catch return;
    defer allocator.free(out);
    @memcpy(out[0 .. end - start], buf[start..end]);
    out[end - start] = 0;
    clipboard.setTextZ(out[0 .. end - start :0]);
}

pub fn drawSelectCopy(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    state: *ViewState,
    session_key: ?[]const u8,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    opts: ChatViewOptions,
) void {
    if (state.select_copy_editor == null) {
        state.select_copy_editor = text_editor.TextEditor.init(allocator) catch null;
    }
    if (state.select_copy_editor == null) return;
    const editor = &state.select_copy_editor.?;

    const session_hash = if (session_key) |key| std.hash.Wyhash.hash(0, key) else 0;
    const session_changed = session_hash != state.last_session_hash;
    if (session_changed) {
        state.last_session_hash = session_hash;
        state.last_message_count = 0;
        state.last_last_id_hash = 0;
        state.last_last_len = 0;
        state.last_stream_len = 0;
    }

    var content_changed = false;
    const last_id_hash = if (messages.len > 0)
        std.hash.Wyhash.hash(0, messages[messages.len - 1].id)
    else
        0;
    const last_len = if (messages.len > 0) messages[messages.len - 1].content.len else 0;
    if (messages.len != state.last_message_count or last_id_hash != state.last_last_id_hash or last_len != state.last_last_len) {
        content_changed = true;
    }
    if (stream_text) |stream| {
        if (stream.len != state.last_stream_len) {
            content_changed = true;
        }
    } else if (state.last_stream_len != 0) {
        content_changed = true;
    }
    state.last_message_count = messages.len;
    state.last_last_id_hash = last_id_hash;
    state.last_last_len = last_len;
    state.last_stream_len = if (stream_text) |stream| stream.len else 0;
    if (opts.show_tool_output != state.last_show_tool_output) {
        content_changed = true;
    }
    state.last_show_tool_output = opts.show_tool_output;

    if (content_changed or editor.isEmpty()) {
        _ = ensureChatBuffer(allocator, messages, stream_text, inbox, opts.show_tool_output);
        const zbuf = bufferZ();
        const slice = std.mem.sliceTo(zbuf, 0);
        editor.setText(allocator, slice);
    }

    _ = editor.draw(allocator, ctx, rect, queue, .{
        .submit_on_enter = false,
        .read_only = true,
    });
}

pub fn drawCustom(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    queue: *input_state.InputQueue,
    state: *ViewState,
    session_key: ?[]const u8,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    opts: ChatViewOptions,
) void {
    const zone = profiler.zone(@src(), "chat.draw");
    defer zone.end();
    const t = theme.activeTheme();
    ctx.drawRect(rect, .{
        .fill = t.colors.surface,
        .stroke = t.colors.border,
        .thickness = 1.0,
    });
    ctx.pushClip(rect);
    defer ctx.popClip();

    const mouse_pos = queue.state.mouse_pos;
    var mouse_down = false;
    var mouse_up = false;
    var copy_requested = false;
    var select_all = false;
    for (queue.events.items) |evt| {
        switch (evt) {
            .mouse_down => |md| if (md.button == .left) {
                mouse_down = true;
            },
            .mouse_up => |mu| if (mu.button == .left) {
                mouse_up = true;
            },
            .key_down => |key_evt| {
                if (key_evt.mods.ctrl) {
                    if (key_evt.key == .c) copy_requested = true;
                    if (key_evt.key == .a) select_all = true;
                }
            },
            else => {},
        }
    }

    if (mouse_down and !rect.contains(mouse_pos)) {
        state.focused = false;
        state.selecting = false;
        state.selection_anchor = null;
        state.selection_focus = null;
    }
    const pending_select = mouse_down and rect.contains(mouse_pos);

    const padding = t.spacing.sm;
    const content_width = @max(1.0, rect.size()[0] - padding * 2.0);
    const bubble_width = components.composite.message_bubble.bubbleWidth(content_width);
    const line_height = ctx.lineHeight();
    const session_hash = if (session_key) |key| std.hash.Wyhash.hash(0, key) else 0;
    const session_changed = session_hash != state.last_session_hash;
    if (session_changed) {
        state.last_session_hash = session_hash;
        state.last_message_count = 0;
        state.last_last_id_hash = 0;
        state.last_last_len = 0;
        state.last_stream_len = 0;
        state.follow_tail = true;
        state.scroll_y = 0.0;
        clearMessageCache(state, allocator);
        state.virt.reset(allocator);
    }

    var messages_changed = false;
    var stream_changed = false;
    // const prev_message_count = state.last_message_count;
    const last_id_hash = if (messages.len > 0)
        std.hash.Wyhash.hash(0, messages[messages.len - 1].id)
    else
        0;
    const last_len = if (messages.len > 0) messages[messages.len - 1].content.len else 0;
    if (messages.len != state.last_message_count or last_id_hash != state.last_last_id_hash or last_len != state.last_last_len) {
        messages_changed = true;
    }
    if (stream_text) |stream| {
        if (stream.len != state.last_stream_len) {
            stream_changed = true;
        }
    } else if (state.last_stream_len != 0) {
        stream_changed = true;
    }
    state.last_message_count = messages.len;
    state.last_last_id_hash = last_id_hash;
    state.last_last_len = last_len;
    state.last_stream_len = if (stream_text) |stream| stream.len else 0;

    const show_tool_output_changed = opts.show_tool_output != state.last_show_tool_output;
    state.last_show_tool_output = opts.show_tool_output;

    // const content_changed = messages_changed or stream_changed or show_tool_output_changed;
    if (session_changed or show_tool_output_changed) {
        state.selection_anchor = null;
        state.selection_focus = null;
        state.selecting = false;
    }

    const gap = t.spacing.sm;
    const separator_len: usize = 2;

    const now_ms = std.time.milliTimestamp();
    const selection = selectionRange(state);
    var hover_doc_index: ?usize = null;
    var visible_messages: u64 = 0;
    var measures_per_frame: u64 = 0;

    var timer = std.time.Timer.start() catch null;
    var mark0: u64 = 0;
    var mark1: u64 = 0;
    var mark2: u64 = 0;
    if (timer) |*t0| mark0 = t0.read();

    const layout_zone = profiler.zone(@src(), "chat.layout");
    ensureVirtualState(
        allocator,
        state,
        session_hash,
        messages,
        stream_text,
        inbox,
        opts.show_tool_output,
        bubble_width,
        line_height,
        padding,
        gap,
        separator_len,
        messages_changed,
        show_tool_output_changed,
        stream_changed,
    );

    var content_height = virtualContentHeight(&state.virt, padding, gap);
    const view_height = rect.size()[1];
    var max_scroll: f32 = @max(0.0, content_height - view_height);

    // If content shrank (or we just rebuilt estimates), clamp scroll before searching.
    if (state.scroll_y < 0.0) state.scroll_y = 0.0;
    if (state.scroll_y > max_scroll) state.scroll_y = max_scroll;

    // Anchor for scroll stability: if message height estimates are refined for items
    // above the viewport, keep the first visible item's top at the same screen
    // position by adjusting scroll_y by the prefix-sum delta.
    const view_top = state.scroll_y;
    var anchor_index: usize = 0;
    var anchor_top_before: f32 = 0.0;
    var have_anchor = false;
    if (!state.follow_tail and state.virt.items.items.len > 0 and
        state.virt.prefix_strides.items.len >= state.virt.items.items.len + 1)
    {
        anchor_index = findFirstVisibleIndex(&state.virt, padding, view_top);
        if (anchor_index < state.virt.items.items.len) {
            anchor_top_before = padding + state.virt.prefix_strides.items[anchor_index];
            have_anchor = true;
        }
    }

    // Windowed rendering: only walk items in an extended viewport.
    const view_bottom = state.scroll_y + rect.size()[1];
    const overscan = rect.size()[1];
    const ext_top = if (view_top > overscan) view_top - overscan else 0.0;
    const ext_bottom = view_bottom + overscan;

    const total_items: usize = state.virt.items.items.len;
    const first = findFirstVisibleIndex(&state.virt, padding, ext_top);
    const last_excl = findFirstTopAfterIndex(&state.virt, padding, ext_bottom);

    layout_zone.end();
    if (timer) |*t1| mark1 = t1.read();

    const render_zone = profiler.zone(@src(), "chat.render");

    var i: usize = first;
    while (i < last_excl and i < total_items) : (i += 1) {
        const item = state.virt.items.items[i];
        const item_top = padding + state.virt.prefix_strides.items[i];
        const item_bottom = item_top + item.height;
        const visible = !(item_bottom < view_top or item_top > view_bottom);
        if (visible) visible_messages += 1;

        const doc_base = state.virt.prefix_doc_units.items[i];

        switch (item.kind) {
            .message => {
                const msg = messages[item.msg_index];
                const align_right = std.mem.eql(u8, msg.role, "user");

                if (visible) {
                    const layout = drawMessage(
                        allocator,
                        ctx,
                        rect,
                        msg.id,
                        msg.role,
                        msg.content,
                        msg.timestamp,
                        now_ms,
                        msg.attachments,
                        align_right,
                        bubble_width,
                        line_height,
                        padding,
                        item_top,
                        state.scroll_y,
                        doc_base,
                        selection,
                        mouse_pos,
                        &measures_per_frame,
                    );
                    if (hover_doc_index == null and layout.hover_index != null) {
                        hover_doc_index = layout.hover_index;
                    }

                    if (layout.height != item.height or layout.text_len != item.text_len) {
                        virtualUpdateItemMetrics(state, i, layout.height, layout.text_len, gap, separator_len);
                    }
                    upsertMessageCacheFromLayout(allocator, state, msg, bubble_width, line_height, padding, layout.height, layout.text_len);
                } else {
                    const cache = ensureMessageCache(
                        allocator,
                        state,
                        ctx,
                        msg,
                        bubble_width,
                        line_height,
                        padding,
                        &measures_per_frame,
                    );
                    if (cache.height != item.height or cache.text_len != item.text_len) {
                        virtualUpdateItemMetrics(state, i, cache.height, cache.text_len, gap, separator_len);
                    }
                }
            },
            .stream => {
                if (stream_text) |stream| {
                    if (visible) {
                        const layout = drawMessage(
                            allocator,
                            ctx,
                            rect,
                            "streaming",
                            "assistant",
                            stream,
                            now_ms,
                            now_ms,
                            null,
                            false,
                            bubble_width,
                            line_height,
                            padding,
                            item_top,
                            state.scroll_y,
                            doc_base,
                            selection,
                            mouse_pos,
                            &measures_per_frame,
                        );
                        if (hover_doc_index == null and layout.hover_index != null) {
                            hover_doc_index = layout.hover_index;
                        }
                        if (layout.height != item.height or layout.text_len != item.text_len) {
                            virtualUpdateItemMetrics(state, i, layout.height, layout.text_len, gap, separator_len);
                        }
                    } else {
                        const layout = measureMessageLayout(
                            allocator,
                            ctx,
                            stream,
                            null,
                            bubble_width,
                            line_height,
                            padding,
                            &measures_per_frame,
                        );
                        if (layout.height != item.height or layout.text_len != item.text_len) {
                            virtualUpdateItemMetrics(state, i, layout.height, layout.text_len, gap, separator_len);
                        }
                    }
                }
            },
        }
    }
    render_zone.end();
    if (timer) |*t2| mark2 = t2.read();

    // Recompute after any height updates.
    content_height = virtualContentHeight(&state.virt, padding, gap);
    max_scroll = @max(0.0, content_height - view_height);
    if (state.virt.items.items.len == 0) {
        const pos = .{ rect.min[0] + padding, rect.min[1] + padding - state.scroll_y };
        ctx.drawText("No messages yet.", pos, .{ .color = t.colors.text_secondary });
    }

    var user_scrolled = false;
    var scrollbar_interacted = false;
    const scroll_step = @max(32.0, line_height * 3.0);
    if (rect.contains(queue.state.mouse_pos)) {
        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_wheel => |mw| {
                    if (mw.delta[1] != 0.0) {
                        state.scroll_y -= mw.delta[1] * scroll_step;
                        user_scrolled = true;
                    }
                },
                else => {},
            }
        }
    }

    if (max_scroll > 0.0) {
        const view_h = rect.size()[1];
        const track_rect = scrollbarTrackRect(rect);
        const thumb_rect = scrollbarThumbRect(rect, state.scroll_y, max_scroll);
        const thumb_h = thumb_rect.max[1] - thumb_rect.min[1];
        const mouse = queue.state.mouse_pos;

        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    const click_pos = md.pos;
                    if (thumb_rect.contains(click_pos)) {
                        state.scrollbar_dragging = true;
                        state.scrollbar_drag_anchor = click_pos[1];
                        state.scrollbar_drag_scroll = state.scroll_y;
                        user_scrolled = true;
                        scrollbar_interacted = true;
                    } else if (track_rect.contains(click_pos)) {
                        const usable = @max(1.0, view_h - thumb_h);
                        const ratio = std.math.clamp((click_pos[1] - rect.min[1] - thumb_h * 0.5) / usable, 0.0, 1.0);
                        state.scroll_y = ratio * max_scroll;
                        user_scrolled = true;
                        scrollbar_interacted = true;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) {
                        state.scrollbar_dragging = false;
                    }
                },
                else => {},
            }
        }

        if (state.scrollbar_dragging) {
            const usable = @max(1.0, view_h - thumb_h);
            const delta = mouse[1] - state.scrollbar_drag_anchor;
            state.scroll_y = state.scrollbar_drag_scroll + (delta / usable) * max_scroll;
            user_scrolled = true;
            scrollbar_interacted = true;
        }
    } else {
        state.scrollbar_dragging = false;
    }

    if (state.scroll_y < 0.0) state.scroll_y = 0.0;
    if (state.scroll_y > max_scroll) state.scroll_y = max_scroll;

    if (have_anchor and !user_scrolled and !state.follow_tail and
        state.virt.prefix_strides.items.len >= state.virt.items.items.len + 1)
    {
        const anchor_top_after = padding + state.virt.prefix_strides.items[anchor_index];
        const delta = anchor_top_after - anchor_top_before;
        if (delta != 0.0) {
            state.scroll_y += delta;
            if (state.scroll_y < 0.0) state.scroll_y = 0.0;
            if (state.scroll_y > max_scroll) state.scroll_y = max_scroll;
        }
    }

    const doc_length = virtualDocLength(&state.virt, separator_len);
    if (mouse_down and rect.contains(mouse_pos)) {
        state.focused = true;
    }
    if (pending_select and !scrollbar_interacted) {
        state.selecting = true;
        state.follow_tail = false;
        const sel_idx = hover_doc_index orelse doc_length;
        state.selection_anchor = sel_idx;
        state.selection_focus = sel_idx;
    }

    if (state.selecting and queue.state.mouse_down_left and !state.scrollbar_dragging) {
        if (hover_doc_index) |hover_idx| {
            state.selection_focus = hover_idx;
        }
    }
    if (mouse_up) {
        state.selecting = false;
    }
    if (select_all and state.focused) {
        state.selection_anchor = 0;
        state.selection_focus = doc_length;
        state.selecting = false;
    }
    if (copy_requested and state.focused) {
        copySelectionToClipboard(allocator, state, messages, stream_text, inbox, opts.show_tool_output);
    }

    const near_bottom = state.scroll_y >= max_scroll - 4.0;
    if (user_scrolled and !near_bottom) {
        state.follow_tail = false;
    } else if (near_bottom) {
        state.follow_tail = true;
    }

    // If pinned, keep pinned even when heights are updated lazily (e.g. cache fill / image load).
    // Avoid fighting the user while they are actively dragging the scrollbar.
    if (state.follow_tail and !state.scrollbar_dragging) {
        state.scroll_y = max_scroll;
    }

    const layout_ms: f64 = if (timer != null and mark1 >= mark0)
        @as(f64, @floatFromInt(mark1 - mark0)) / 1_000_000.0
    else
        0.0;
    const render_ms: f64 = if (timer != null and mark2 >= mark1)
        @as(f64, @floatFromInt(mark2 - mark1)) / 1_000_000.0
    else
        0.0;

    profiler.plotU("chat.total_messages", @intCast(messages.len));
    profiler.plotU("chat.total_items", @intCast(total_items));
    profiler.plotU("chat.window_items", @intCast(last_excl - first));
    profiler.plotU("chat.visible_messages", visible_messages);
    profiler.plotU("chat.measures_per_frame", measures_per_frame);
    profiler.plotF("chat.layout_ms", layout_ms);
    profiler.plotF("chat.render_ms", render_ms);

    drawScrollbar(ctx, rect, state.scroll_y, max_scroll);
}

fn getMessageCacheIfValid(
    state: *const ViewState,
    msg: types.ChatMessage,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
) ?MessageCache {
    if (state.message_cache) |*map| {
        if (map.getPtr(msg.id)) |cache| {
            if (cache.content_len == msg.content.len and cache.bubble_width == bubble_width and
                cache.line_height == line_height and cache.padding == padding)
            {
                if (msg.attachments == null and cache.attachments_hash == 0) {
                    return cache.*;
                }
                const attachments_hash = attachmentStateHash(msg.attachments);
                if (cache.attachments_hash == attachments_hash) {
                    return cache.*;
                }
            }
        }
    }
    return null;
}

fn upsertMessageCacheFromLayout(
    allocator: std.mem.Allocator,
    state: *ViewState,
    msg: types.ChatMessage,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    height: f32,
    text_len: usize,
) void {
    const cache = MessageCache{
        .content_len = msg.content.len,
        .attachments_hash = attachmentStateHash(msg.attachments),
        .bubble_width = bubble_width,
        .line_height = line_height,
        .padding = padding,
        .height = height,
        .text_len = text_len,
    };
    storeMessageCache(allocator, state, msg.id, cache);
}

fn ensureVirtualState(
    allocator: std.mem.Allocator,
    state: *ViewState,
    session_hash: u64,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    gap: f32,
    separator_len: usize,
    messages_changed: bool,
    show_tool_output_changed: bool,
    stream_changed: bool,
) void {
    const virt = &state.virt;

    const params_changed = virt.built_for_session_hash != session_hash or
        virt.built_for_show_tool_output != show_tool_output or
        virt.built_for_bubble_width != bubble_width or
        virt.built_for_line_height != line_height or
        virt.built_for_padding != padding or
        virt.built_for_gap != gap;

    // If something changed that could reorder/filter the list, rebuild.
    const need_rebuild = params_changed or show_tool_output_changed or virt.scanned_message_count > messages.len or
        (messages_changed and messages.len <= virt.scanned_message_count);
    if (need_rebuild) {
        virt.reset(allocator);
        virt.built_for_session_hash = session_hash;
        virt.built_for_show_tool_output = show_tool_output;
        virt.built_for_bubble_width = bubble_width;
        virt.built_for_line_height = line_height;
        virt.built_for_padding = padding;
        virt.built_for_gap = gap;
    } else if (messages.len > virt.scanned_message_count and virt.scanned_message_count > 0) {
        // Detect prepends/inserts: if indices shifted, we must rebuild to keep msg_index correct.
        const boundary_hash = std.hash.Wyhash.hash(0, messages[virt.scanned_message_count - 1].id);
        if (boundary_hash != virt.scanned_last_id_hash) {
            virt.reset(allocator);
            virt.built_for_session_hash = session_hash;
            virt.built_for_show_tool_output = show_tool_output;
            virt.built_for_bubble_width = bubble_width;
            virt.built_for_line_height = line_height;
            virt.built_for_padding = padding;
            virt.built_for_gap = gap;
        }
    }

    // Append any newly arrived messages (steady state: O(new_messages)).
    var idx: usize = virt.scanned_message_count;
    while (idx < messages.len) : (idx += 1) {
        const msg = messages[idx];
        if (shouldSkipMessage(msg, inbox, show_tool_output)) continue;

        const cached = getMessageCacheIfValid(state, msg, bubble_width, line_height, padding);
        const height = if (cached) |c| c.height else estimateMessageHeight(line_height, padding, msg.attachments);
        const text_len = if (cached) |c| c.text_len else displayTextLen(msg.content);

        virtualAppendItem(
            allocator,
            virt,
            .{ .kind = .message, .msg_index = idx, .height = height, .text_len = text_len },
            gap,
            separator_len,
        );
    }
    virt.scanned_message_count = messages.len;
    virt.scanned_last_id_hash = if (messages.len > 0) std.hash.Wyhash.hash(0, messages[messages.len - 1].id) else 0;

    // Stream item (always last if present).
    const has_stream = stream_text != null;
    const has_item_stream = virt.items.items.len > 0 and virt.items.items[virt.items.items.len - 1].kind == .stream;

    if (has_stream and !has_item_stream) {
        const stream = stream_text.?;
        virtualAppendItem(
            allocator,
            virt,
            .{
                .kind = .stream,
                .msg_index = 0,
                .height = estimateMessageHeight(line_height, padding, null),
                .text_len = displayTextLen(stream),
            },
            gap,
            separator_len,
        );
    } else if (!has_stream and has_item_stream) {
        virtualPopItem(virt);
    } else if (has_stream and has_item_stream and stream_changed) {
        // Keep selectable doc length in sync even when the stream isn't visible.
        const stream = stream_text.?;
        const idx_stream = virt.items.items.len - 1;
        const item = virt.items.items[idx_stream];
        const new_text_len = displayTextLen(stream);
        if (new_text_len != item.text_len) {
            virtualUpdateItemMetrics(state, idx_stream, item.height, new_text_len, gap, separator_len);
        }
    }
}

fn virtualEnsurePrefixInit(
    allocator: std.mem.Allocator,
    virt: *VirtualState,
) void {
    if (virt.prefix_strides.items.len == 0) {
        virt.prefix_strides.append(allocator, 0.0) catch {};
    }
    if (virt.prefix_doc_units.items.len == 0) {
        virt.prefix_doc_units.append(allocator, 0) catch {};
    }
}

fn virtualAppendItem(
    allocator: std.mem.Allocator,
    virt: *VirtualState,
    item: VirtualItem,
    gap: f32,
    separator_len: usize,
) void {
    virtualEnsurePrefixInit(allocator, virt);
    virt.items.append(allocator, item) catch return;

    const prev_stride = virt.prefix_strides.items[virt.prefix_strides.items.len - 1];
    virt.prefix_strides.append(allocator, prev_stride + item.height + gap) catch {};

    const prev_doc = virt.prefix_doc_units.items[virt.prefix_doc_units.items.len - 1];
    virt.prefix_doc_units.append(allocator, prev_doc + item.text_len + separator_len) catch {};
}

fn virtualPopItem(virt: *VirtualState) void {
    if (virt.items.items.len == 0) return;
    _ = virt.items.pop();
    if (virt.prefix_strides.items.len > 0) _ = virt.prefix_strides.pop();
    if (virt.prefix_doc_units.items.len > 0) _ = virt.prefix_doc_units.pop();
}

fn virtualRecomputePrefixesFrom(
    virt: *VirtualState,
    start_item_index: usize,
    gap: f32,
    separator_len: usize,
) void {
    if (start_item_index >= virt.items.items.len) return;
    if (virt.prefix_strides.items.len != virt.items.items.len + 1) return;
    if (virt.prefix_doc_units.items.len != virt.items.items.len + 1) return;

    var stride = virt.prefix_strides.items[start_item_index];
    var doc = virt.prefix_doc_units.items[start_item_index];
    var i: usize = start_item_index;
    while (i < virt.items.items.len) : (i += 1) {
        const item = virt.items.items[i];
        stride += item.height + gap;
        virt.prefix_strides.items[i + 1] = stride;

        doc += item.text_len + separator_len;
        virt.prefix_doc_units.items[i + 1] = doc;
    }
}

fn virtualUpdateItemMetrics(
    state: *ViewState,
    item_index: usize,
    height: f32,
    text_len: usize,
    gap: f32,
    separator_len: usize,
) void {
    if (item_index >= state.virt.items.items.len) return;
    state.virt.items.items[item_index].height = height;
    state.virt.items.items[item_index].text_len = text_len;
    virtualRecomputePrefixesFrom(&state.virt, item_index, gap, separator_len);
}

fn virtualContentHeight(virt: *const VirtualState, padding: f32, gap: f32) f32 {
    const n = virt.items.items.len;
    if (n == 0) return padding * 2.0;
    if (virt.prefix_strides.items.len < n + 1) return padding * 2.0;
    return padding + virt.prefix_strides.items[n] - gap + padding;
}

fn virtualDocLength(virt: *const VirtualState, separator_len: usize) usize {
    // NOTE: prefix_doc_units includes a trailing separator_len after *every* item
    // (see virtualAppendItem). We subtract one separator at the end to get the
    // actual selectable doc length.
    const n = virt.items.items.len;
    if (n == 0) return 0;
    if (virt.prefix_doc_units.items.len < n + 1) return 0;
    const total = virt.prefix_doc_units.items[n];
    return if (total > separator_len) total - separator_len else 0;
}

fn findFirstVisibleIndex(virt: *const VirtualState, padding: f32, y: f32) usize {
    const n = virt.items.items.len;
    if (n == 0) return 0;
    if (virt.prefix_strides.items.len < n + 1) return 0;

    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const top = padding + virt.prefix_strides.items[mid];
        const bottom = top + virt.items.items[mid].height;
        if (bottom < y) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn findFirstTopAfterIndex(virt: *const VirtualState, padding: f32, y: f32) usize {
    // Returns the first index whose item top is strictly greater than `y`.
    // (Intentional strict bound: if `y` lands exactly on an item top, we still
    // include that item in the render window, which is slightly conservative and
    // avoids edge-case blank gaps.)
    const n = virt.items.items.len;
    if (n == 0) return 0;
    if (virt.prefix_strides.items.len < n + 1) return 0;

    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const top = padding + virt.prefix_strides.items[mid];
        if (top > y) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return lo;
}

test "chat virtualization binary search basics" {
    const allocator = std.testing.allocator;
    var virt: VirtualState = .{};
    defer virt.deinit(allocator);

    const gap: f32 = 10.0;
    const sep: usize = 2;

    virtualAppendItem(allocator, &virt, .{ .kind = .message, .msg_index = 0, .height = 100.0, .text_len = 5 }, gap, sep);
    virtualAppendItem(allocator, &virt, .{ .kind = .message, .msg_index = 1, .height = 50.0, .text_len = 3 }, gap, sep);
    virtualAppendItem(allocator, &virt, .{ .kind = .message, .msg_index = 2, .height = 80.0, .text_len = 4 }, gap, sep);

    const padding: f32 = 5.0;

    // y within first item
    try std.testing.expectEqual(@as(usize, 0), findFirstVisibleIndex(&virt, padding, 0.0));
    try std.testing.expectEqual(@as(usize, 0), findFirstVisibleIndex(&virt, padding, padding + 10.0));

    // y just below first item bottom (100)
    const y_after_first = padding + 100.0 + 0.1;
    try std.testing.expectEqual(@as(usize, 1), findFirstVisibleIndex(&virt, padding, y_after_first));

    // top-after
    try std.testing.expectEqual(@as(usize, 0), findFirstTopAfterIndex(&virt, padding, 0.0));
    try std.testing.expectEqual(@as(usize, 1), findFirstTopAfterIndex(&virt, padding, padding + 100.0));
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    var index: usize = 0;
    while (index < suffix.len) : (index += 1) {
        if (std.ascii.toLower(value[start + index]) != suffix[index]) return false;
    }
    return true;
}

fn isImageAttachment(att: types.ChatAttachment) bool {
    if (std.mem.indexOf(u8, att.kind, "image") != null) return true;
    if (std.mem.startsWith(u8, att.url, "data:image/")) return true;
    return endsWithIgnoreCase(att.url, ".png") or
        endsWithIgnoreCase(att.url, ".jpg") or
        endsWithIgnoreCase(att.url, ".jpeg") or
        endsWithIgnoreCase(att.url, ".gif") or
        endsWithIgnoreCase(att.url, ".webp");
}

fn isToolRole(role: []const u8) bool {
    return std.mem.startsWith(u8, role, "tool") or std.mem.eql(u8, role, "toolResult");
}

fn countVisible(
    messages: []const types.ChatMessage,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) i32 {
    var count: i32 = 0;
    for (messages) |msg| {
        if (shouldSkipMessage(msg, inbox, show_tool_output)) continue;
        count += 1;
    }
    return count;
}

fn drawMessage(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    rect: draw_context.Rect,
    id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp_ms: ?i64,
    now_ms: i64,
    attachments: ?[]const types.ChatAttachment,
    align_right: bool,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    content_y: f32,
    scroll_y: f32,
    doc_base: usize,
    selection: ?[2]usize,
    mouse_pos: [2]f32,
    measures_per_frame: ?*u64,
) MessageLayout {
    _ = id;
    if (measures_per_frame) |counter| counter.* += 1;
    const t = theme.activeTheme();
    const bubble = components.composite.message_bubble.bubbleColors(role, t);
    const bubble_x = if (align_right)
        rect.max[0] - padding - bubble_width
    else
        rect.min[0] + padding;

    var display = buildDisplayText(allocator, content);
    defer display.deinit(allocator);

    var lines = buildWrappedLines(allocator, ctx, display.text, &display.sources, bubble_width - padding * 2.0);
    defer lines.deinit(allocator);

    const header_height = line_height;
    const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
    const header_gap = t.spacing.xs;
    var attachments_height: f32 = 0.0;
    if (attachments) |items| {
        attachments_height = measureAttachmentsHeight(ctx, items, bubble_width, line_height, padding);
    }
    const total_height = padding * 2.0 + header_height + header_gap + content_height + attachments_height;

    const view_top = scroll_y;
    const view_bottom = scroll_y + rect.size()[1];
    const bubble_top = content_y;
    const bubble_bottom = content_y + total_height;
    const visible = !(bubble_bottom < view_top or bubble_top > view_bottom);

    var hover_index: ?usize = null;
    var local_sel: ?[2]usize = null;
    if (selection) |sel| {
        const msg_start = doc_base;
        const msg_end = doc_base + display.text.len;
        if (sel[1] > msg_start and sel[0] < msg_end) {
            const start = if (sel[0] > msg_start) sel[0] - msg_start else 0;
            const end = if (sel[1] < msg_end) sel[1] - msg_start else display.text.len;
            if (start < end) {
                local_sel = .{ start, end };
            }
        }
    }

    if (visible) {
        const bubble_y = rect.min[1] + content_y - scroll_y;
        const bubble_rect = draw_context.Rect{
            .min = .{ bubble_x, bubble_y },
            .max = .{ bubble_x + bubble_width, bubble_y + total_height },
        };
        ctx.drawRoundedRect(bubble_rect, t.radius.md, .{
            .fill = bubble.bg,
            .stroke = bubble.border,
            .thickness = 1.0,
        });
        ctx.pushClip(bubble_rect);
        defer ctx.popClip();

        const label = components.composite.message_bubble.roleLabel(role);
        const label_pos = .{ bubble_x + padding, bubble_y + padding };
        ctx.drawText(label, label_pos, .{ .color = bubble.accent });

        if (timestamp_ms) |ts| {
            var time_buf: [32]u8 = undefined;
            const time_label = components.composite.message_bubble.formatRelativeTime(now_ms, ts, &time_buf);
            const label_w = ctx.measureText(label, 0.0)[0];
            const time_pos = .{ label_pos[0] + label_w + t.spacing.sm, label_pos[1] };
            ctx.drawText(time_label, time_pos, .{ .color = t.colors.text_secondary });
        }

        const content_start_y = bubble_y + padding + header_height + header_gap;
        const content_end_y = content_start_y + content_height;
        if (local_sel) |sel| {
            drawSelectionHighlight(
                ctx,
                .{ bubble_x + padding, content_start_y },
                &lines,
                display.text,
                sel,
                line_height,
                t,
            );
        }
        var line_y = content_start_y;
        for (lines.items) |line| {
            if (line.start < line.end) {
                const slice = display.text[line.start..line.end];
                drawStyledLine(ctx, .{ bubble_x + padding, line_y }, line, slice, t);
            }
            line_y += line_height;
        }

        if (attachments) |items| {
            _ = drawAttachmentsCustom(
                ctx,
                items,
                bubble_x,
                line_y,
                bubble_width,
                line_height,
                padding,
                true,
            );
        }

        const content_rect = draw_context.Rect{
            .min = .{ bubble_x + padding, content_start_y },
            .max = .{ bubble_x + bubble_width - padding, content_start_y + content_height },
        };
        if (content_rect.contains(mouse_pos) and lines.items.len > 0) {
            const local_y = mouse_pos[1] - content_start_y;
            var line_index: i32 = @intFromFloat(local_y / line_height);
            if (line_index < 0) line_index = 0;
            const max_index: i32 = @intCast(lines.items.len - 1);
            if (line_index > max_index) line_index = max_index;
            const line = lines.items[@intCast(line_index)];
            const local_x = mouse_pos[0] - (bubble_x + padding);
            const idx = indexForLineX(ctx, display.text, line, local_x);
            hover_index = doc_base + idx;
        } else if (bubble_rect.contains(mouse_pos)) {
            if (mouse_pos[1] <= content_start_y) {
                hover_index = doc_base;
            } else if (mouse_pos[1] >= content_end_y) {
                hover_index = doc_base + display.text.len;
            }
        }
    }

    return .{
        .height = total_height,
        .text_len = display.text.len,
        .hover_index = hover_index,
    };
}

fn drawSelectionHighlight(
    ctx: *draw_context.DrawContext,
    origin: draw_context.Vec2,
    lines: *std.ArrayList(WrappedLine),
    text: []const u8,
    selection: [2]usize,
    line_height: f32,
    t: *const theme.Theme,
) void {
    const highlight = .{ t.colors.primary[0], t.colors.primary[1], t.colors.primary[2], 0.25 };
    for (lines.items, 0..) |line, idx| {
        if (selection[1] <= line.start or selection[0] >= line.end) continue;
        const line_sel_start = if (selection[0] > line.start) selection[0] else line.start;
        const line_sel_end = if (selection[1] < line.end) selection[1] else line.end;
        const left = textWidth(ctx, text[line.start..line_sel_start]);
        const right = textWidth(ctx, text[line.start..line_sel_end]);
        const y = origin[1] + @as(f32, @floatFromInt(idx)) * line_height;
        const rect = draw_context.Rect{
            .min = .{ origin[0] + left, y },
            .max = .{ origin[0] + right, y + line_height },
        };
        ctx.drawRect(rect, .{ .fill = highlight });
    }
}

fn drawStyledLine(
    ctx: *draw_context.DrawContext,
    pos: draw_context.Vec2,
    line: WrappedLine,
    text: []const u8,
    t: *const theme.Theme,
) void {
    const line_height = ctx.lineHeight();
    var color = t.colors.text_primary;
    switch (line.style) {
        .heading => {
            theme.push(.heading);
            defer theme.pop();
        },
        .quote => {
            color = t.colors.text_secondary;
            const bar = draw_context.Rect{
                .min = .{ pos[0] - t.spacing.xs, pos[1] },
                .max = .{ pos[0] - t.spacing.xs + 2.0, pos[1] + line_height },
            };
            ctx.drawRect(bar, .{ .fill = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], 0.6 } });
        },
        .code => {
            color = t.colors.text_secondary;
            const text_w = ctx.measureText(text, 0.0)[0];
            const bg = draw_context.Rect{
                .min = .{ pos[0] - 2.0, pos[1] - 1.0 },
                .max = .{ pos[0] + text_w + 2.0, pos[1] + line_height + 1.0 },
            };
            ctx.drawRect(bg, .{ .fill = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], 0.18 } });
        },
        else => {},
    }
    ctx.drawText(text, pos, .{ .color = color });
}

fn textWidth(ctx: *draw_context.DrawContext, text: []const u8) f32 {
    return ctx.measureText(text, 0.0)[0];
}

fn indexForLineX(ctx: *draw_context.DrawContext, text: []const u8, line: WrappedLine, x: f32) usize {
    var idx = line.start;
    var cur_x: f32 = 0.0;
    while (idx < line.end) {
        const next = nextCharIndex(text, idx);
        const slice = text[idx..next];
        const char_w = textWidth(ctx, slice);
        if (cur_x + char_w * 0.5 >= x) break;
        cur_x += char_w;
        idx = next;
    }
    return idx;
}

fn measureAttachmentsHeight(
    ctx: *draw_context.DrawContext,
    attachments: []const types.ChatAttachment,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
) f32 {
    return drawAttachmentsCustom(ctx, attachments, 0.0, 0.0, bubble_width, line_height, padding, false);
}

fn attachmentStateHash(attachments: ?[]const types.ChatAttachment) u64 {
    if (attachments == null) return 0;
    var hasher = std.hash.Wyhash.init(0);
    for (attachments.?) |attachment| {
        hasher.update(attachment.url);
        hasher.update(attachment.kind);
        if (attachment.name) |name| {
            hasher.update(name);
        }
        if (isImageAttachment(attachment)) {
            if (image_cache.get(attachment.url)) |entry| {
                const state_byte: u8 = @intFromEnum(entry.state);
                hasher.update(std.mem.asBytes(&state_byte));
                hasher.update(std.mem.asBytes(&entry.width));
                hasher.update(std.mem.asBytes(&entry.height));
            } else {
                const zero: u8 = 0;
                hasher.update(std.mem.asBytes(&zero));
            }
        }
    }
    return hasher.final();
}

fn estimateMessageHeight(line_height: f32, padding: f32, attachments: ?[]const types.ChatAttachment) f32 {
    // Cheap estimate used for far-off items when we don't want to measure.
    // Over-estimation is generally safer than under-estimation (less likely to "skip" visibility).
    const header_height = line_height;
    const header_gap = theme.activeTheme().spacing.xs;
    const approx_lines: f32 = 3.0;
    var attachments_height: f32 = 0.0;
    if (attachments) |items| {
        // Roughly: one line per non-image attachment, plus a fixed block for images.
        var non_images: f32 = 0.0;
        var images: f32 = 0.0;
        for (items) |a| {
            if (isImageAttachment(a)) images += 1.0 else non_images += 1.0;
        }
        attachments_height = non_images * (line_height + header_gap) + images * 200.0;
    }
    return padding * 2.0 + header_height + header_gap + approx_lines * line_height + attachments_height;
}

fn ensureMessageCache(
    allocator: std.mem.Allocator,
    state: *ViewState,
    ctx: *draw_context.DrawContext,
    msg: types.ChatMessage,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    measures_per_frame: ?*u64,
) MessageCache {
    const cache_map = ensureMessageCacheMap(state, allocator);
    const content_len = msg.content.len;
    if (cache_map.getPtr(msg.id)) |cache| {
        if (cache.content_len == content_len and cache.bubble_width == bubble_width and
            cache.line_height == line_height and cache.padding == padding)
        {
            if (msg.attachments == null and cache.attachments_hash == 0) {
                return cache.*;
            }
            const attachments_hash = attachmentStateHash(msg.attachments);
            if (cache.attachments_hash == attachments_hash) {
                return cache.*;
            }
        }
    }

    const attachments_hash = attachmentStateHash(msg.attachments);

    const layout = measureMessageLayout(
        allocator,
        ctx,
        msg.content,
        msg.attachments,
        bubble_width,
        line_height,
        padding,
        measures_per_frame,
    );
    const new_cache = MessageCache{
        .content_len = content_len,
        .attachments_hash = attachments_hash,
        .bubble_width = bubble_width,
        .line_height = line_height,
        .padding = padding,
        .height = layout.height,
        .text_len = layout.text_len,
    };
    storeMessageCache(allocator, state, msg.id, new_cache);
    return new_cache;
}

fn measureMessageLayout(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    content: []const u8,
    attachments: ?[]const types.ChatAttachment,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    measures_per_frame: ?*u64,
) MessageLayout {
    if (measures_per_frame) |counter| counter.* += 1;
    var display = buildDisplayText(allocator, content);
    defer display.deinit(allocator);

    var lines = buildWrappedLines(allocator, ctx, display.text, &display.sources, bubble_width - padding * 2.0);
    defer lines.deinit(allocator);

    const header_height = line_height;
    const content_height = @as(f32, @floatFromInt(lines.items.len)) * line_height;
    const header_gap = theme.activeTheme().spacing.xs;
    var attachments_height: f32 = 0.0;
    if (attachments) |items| {
        attachments_height = measureAttachmentsHeight(ctx, items, bubble_width, line_height, padding);
    }
    const total_height = padding * 2.0 + header_height + header_gap + content_height + attachments_height;
    return .{
        .height = total_height,
        .text_len = display.text.len,
        .hover_index = null,
    };
}

fn storeMessageCache(
    allocator: std.mem.Allocator,
    state: *ViewState,
    id: []const u8,
    cache: MessageCache,
) void {
    const cache_map = ensureMessageCacheMap(state, allocator);
    if (cache_map.getPtr(id)) |entry| {
        entry.* = cache;
        return;
    }
    const key = allocator.dupe(u8, id) catch return;
    cache_map.put(key, cache) catch allocator.free(key);
}

fn updateMessageCache(
    state: *ViewState,
    id: []const u8,
    cache: MessageCache,
    height: f32,
    text_len: usize,
) void {
    if (state.message_cache == null) return;
    if (state.message_cache.?.getPtr(id)) |entry| {
        entry.height = height;
        entry.text_len = text_len;
        return;
    }
    // If the cache was missing, ignore; it will be created next frame.
    _ = cache;
}

fn clearMessageCache(state: *ViewState, allocator: std.mem.Allocator) void {
    if (state.message_cache == null) return;
    var cache_map = &state.message_cache.?;
    var it = cache_map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    cache_map.deinit();
    state.message_cache = null;
}

fn ensureMessageCacheMap(state: *ViewState, allocator: std.mem.Allocator) *std.StringHashMap(MessageCache) {
    if (state.message_cache == null) {
        state.message_cache = std.StringHashMap(MessageCache).init(allocator);
    }
    return &state.message_cache.?;
}

fn drawAttachmentsCustom(
    ctx: *draw_context.DrawContext,
    attachments: []const types.ChatAttachment,
    bubble_x: f32,
    start_y: f32,
    bubble_width: f32,
    line_height: f32,
    padding: f32,
    visible: bool,
) f32 {
    const t = theme.activeTheme();
    var y = start_y;
    var has_any = false;

    for (attachments) |attachment| {
        if (isImageAttachment(attachment)) continue;
        const label = attachment.name orelse attachment.url;
        if (visible) {
            ctx.drawText(label, .{ bubble_x + padding, y }, .{ .color = t.colors.text_secondary });
        }
        y += line_height + t.spacing.xs;
        has_any = true;
    }

    if (has_any) {
        y += t.spacing.xs;
    }

    for (attachments) |attachment| {
        if (!isImageAttachment(attachment)) continue;
        image_cache.request(attachment.url);
        const max_width = @max(120.0, @min(320.0, bubble_width - padding * 2.0));
        const max_height: f32 = 240.0;
        if (image_cache.get(attachment.url)) |entry| {
            switch (entry.state) {
                .ready => {
                    const w = @as(f32, @floatFromInt(entry.width));
                    const h = @as(f32, @floatFromInt(entry.height));
                    const aspect = if (h > 0) w / h else 1.0;
                    var draw_w = @min(max_width, w);
                    var draw_h = draw_w / aspect;
                    if (draw_h > max_height) {
                        draw_h = max_height;
                        draw_w = draw_h * aspect;
                    }
                    if (visible) {
                        const tex_ref = draw_context.DrawContext.textureFromId(@as(u64, entry.texture_id));
                        const rect = draw_context.Rect{
                            .min = .{ bubble_x + padding, y },
                            .max = .{ bubble_x + padding + draw_w, y + draw_h },
                        };
                        ctx.drawImage(tex_ref, rect);
                    }
                    y += draw_h + t.spacing.xs;
                },
                .loading => {
                    if (visible) {
                        ctx.drawText("Loading image...", .{ bubble_x + padding, y }, .{ .color = t.colors.text_secondary });
                    }
                    y += line_height + t.spacing.xs;
                },
                .failed => {
                    if (visible) {
                        ctx.drawText("Image failed to load", .{ bubble_x + padding, y }, .{ .color = t.colors.text_secondary });
                    }
                    y += line_height + t.spacing.xs;
                },
            }
        } else {
            if (visible) {
                ctx.drawText("Loading image...", .{ bubble_x + padding, y }, .{ .color = t.colors.text_secondary });
            }
            y += line_height + t.spacing.xs;
        }
    }

    return y - start_y;
}

fn drawScrollbar(ctx: *draw_context.DrawContext, rect: draw_context.Rect, scroll_y: f32, max_scroll: f32) void {
    if (max_scroll <= 0.0) return;
    const t = theme.activeTheme();
    const track = scrollbarTrackRect(rect);
    const thumb = scrollbarThumbRect(rect, scroll_y, max_scroll);
    ctx.drawRect(track, .{ .fill = .{ t.colors.border[0], t.colors.border[1], t.colors.border[2], 0.12 } });
    ctx.drawRect(thumb, .{ .fill = .{ t.colors.text_secondary[0], t.colors.text_secondary[1], t.colors.text_secondary[2], 0.4 } });
}

fn scrollbarTrackRect(rect: draw_context.Rect) draw_context.Rect {
    const track_w: f32 = 14.0;
    const inset: f32 = 6.0;
    return .{
        .min = .{ rect.max[0] - inset - track_w, rect.min[1] },
        .max = .{ rect.max[0] - inset, rect.max[1] },
    };
}

fn scrollbarThumbRect(rect: draw_context.Rect, scroll_y: f32, max_scroll: f32) draw_context.Rect {
    const track = scrollbarTrackRect(rect);
    const view_h = rect.size()[1];
    const thumb_h = @max(24.0, view_h * (view_h / (view_h + max_scroll)));
    const thumb_y = rect.min[1] + (scroll_y / max_scroll) * (view_h - thumb_h);
    return .{
        .min = .{ track.min[0], thumb_y },
        .max = .{ track.max[0], thumb_y + thumb_h },
    };
}

fn buildDisplayText(allocator: std.mem.Allocator, text: []const u8) DisplayText {
    var out = std.ArrayList(u8).empty;
    var sources = std.ArrayList(SourceLine).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var failed = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code_block = !in_code_block;
            continue;
        }
        var style: LineStyle = if (in_code_block) .code else .normal;
        var line_out = trimmed;
        var prefix: []const u8 = "";
        if (!in_code_block) {
            if (trimmed.len > 0 and trimmed[0] == '#') {
                var hash_count: usize = 0;
                while (hash_count < trimmed.len and trimmed[hash_count] == '#') {
                    hash_count += 1;
                }
                if (hash_count < trimmed.len and trimmed[hash_count] == ' ') {
                    style = .heading;
                    line_out = trimmed[hash_count + 1 ..];
                }
            }
            if (style == .normal and std.mem.startsWith(u8, trimmed, "> ")) {
                style = .quote;
                line_out = trimmed[2..];
            } else if (style == .normal and (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ "))) {
                style = .list;
                line_out = trimmed[2..];
                prefix = "- ";
            }
        }

        const start = out.items.len;
        if (prefix.len > 0) {
            out.appendSlice(allocator, prefix) catch {
                failed = true;
                break;
            };
        }
        if (line_out.len > 0) {
            out.appendSlice(allocator, line_out) catch {
                failed = true;
                break;
            };
        }
        const end = out.items.len;
        sources.append(allocator, .{ .start = start, .end = end, .style = style }) catch {
            failed = true;
            break;
        };
        out.append(allocator, '\n') catch {
            failed = true;
            break;
        };
    }

    if (failed) {
        out.deinit(allocator);
        sources.deinit(allocator);
        return .{ .text = text, .owned = false, .sources = .empty };
    }

    if (out.items.len > 0) {
        _ = out.pop();
    }

    const owned = out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        sources.deinit(allocator);
        return .{ .text = text, .owned = false, .sources = .empty };
    };
    return .{ .text = owned, .owned = true, .sources = sources };
}

fn displayTextLen(text: []const u8) usize {
    // Must stay in sync with buildDisplayText() transformations.
    var it = std.mem.splitScalar(u8, text, '\n');
    var in_code_block = false;
    var len: usize = 0;
    var wrote_any = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code_block = !in_code_block;
            continue;
        }

        var style: LineStyle = if (in_code_block) .code else .normal;
        var line_out = trimmed;
        var prefix_len: usize = 0;

        if (!in_code_block) {
            if (trimmed.len > 0 and trimmed[0] == '#') {
                var hash_count: usize = 0;
                while (hash_count < trimmed.len and trimmed[hash_count] == '#') {
                    hash_count += 1;
                }
                if (hash_count < trimmed.len and trimmed[hash_count] == ' ') {
                    style = .heading;
                    if (hash_count + 1 <= trimmed.len) {
                        line_out = trimmed[hash_count + 1 ..];
                    }
                }
            }
            if (style == .normal and std.mem.startsWith(u8, trimmed, "> ")) {
                style = .quote;
                if (trimmed.len >= 2) line_out = trimmed[2..];
            } else if (style == .normal and (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ "))) {
                style = .list;
                if (trimmed.len >= 2) line_out = trimmed[2..];
                prefix_len = 2; // "- "
            }
        }

        len += prefix_len;
        len += line_out.len;
        len += 1; // newline
        wrote_any = true;
    }

    if (wrote_any and len > 0) len -= 1; // pop last newline
    return len;
}

fn buildWrappedLines(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    text: []const u8,
    sources: *std.ArrayList(SourceLine),
    wrap_width: f32,
) std.ArrayList(WrappedLine) {
    var lines = std.ArrayList(WrappedLine).empty;
    buildWrappedLinesInto(allocator, ctx, text, sources, wrap_width, &lines);
    return lines;
}

fn buildWrappedLinesInto(
    allocator: std.mem.Allocator,
    ctx: *draw_context.DrawContext,
    text: []const u8,
    sources: *std.ArrayList(SourceLine),
    wrap_width: f32,
    lines: *std.ArrayList(WrappedLine),
) void {
    lines.clearRetainingCapacity();
    const effective_wrap = if (wrap_width <= 1.0) 10_000.0 else wrap_width;
    if (sources.items.len == 0) {
        _ = lines.append(allocator, .{ .start = 0, .end = text.len, .style = .normal }) catch {};
        return;
    }

    for (sources.items) |source| {
        if (source.start == source.end) {
            _ = lines.append(allocator, .{ .start = source.start, .end = source.end, .style = source.style }) catch {};
            continue;
        }
        var line_start: usize = source.start;
        var line_width: f32 = 0.0;
        var last_space: ?usize = null;
        var index: usize = source.start;

        while (index < source.end) {
            const ch = text[index];
            const next = nextCharIndex(text, index);
            const slice = text[index..next];
            const char_w = textWidth(ctx, slice);

            if (ch == ' ' or ch == '\t') {
                last_space = next;
            }

            if (line_width + char_w > effective_wrap and line_width > 0.0) {
                if (last_space != null and last_space.? > line_start) {
                    _ = lines.append(allocator, .{ .start = line_start, .end = last_space.? - 1, .style = source.style }) catch {};
                    index = last_space.?;
                } else {
                    _ = lines.append(allocator, .{ .start = line_start, .end = index, .style = source.style }) catch {};
                }
                line_start = index;
                line_width = 0.0;
                last_space = null;
                continue;
            }

            line_width += char_w;
            index = next;
        }

        _ = lines.append(allocator, .{ .start = line_start, .end = source.end, .style = source.style }) catch {};
    }
}

fn nextCharIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const first = text[index];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const next = index + @as(usize, len);
    return if (next > text.len) text.len else next;
}

var chat_buffer: std.ArrayList(u8) = .empty;

pub fn deinitGlobals(allocator: std.mem.Allocator) void {
    chat_buffer.deinit(allocator);
    chat_buffer = .empty;
}
fn ensureChatBuffer(
    allocator: std.mem.Allocator,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) bool {
    chat_buffer.clearRetainingCapacity();
    var writer = chat_buffer.writer(allocator);
    for (messages) |msg| {
        if (shouldSkipMessage(msg, inbox, show_tool_output)) continue;
        writer.print("[{s}] {s}\n\n", .{ msg.role, msg.content }) catch return false;
        if (msg.attachments) |attachments| {
            for (attachments) |attachment| {
                writer.print("[attachment:{s}] {s}\n\n", .{ attachment.kind, attachment.url }) catch return false;
            }
        }
    }
    if (stream_text) |stream| {
        writer.print("[assistant] {s}\n", .{stream}) catch return false;
    }
    writer.writeByte(0) catch return false;
    return true;
}

fn bufferZ() [:0]u8 {
    if (chat_buffer.items.len <= 1) return @constCast(empty_z[0.. :0]);
    return chat_buffer.items[0 .. chat_buffer.items.len - 1 :0];
}

fn shouldSkipMessage(
    msg: types.ChatMessage,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) bool {
    if (inbox) |store| {
        if (store.isCommandMessage(msg.id)) {
            return !show_tool_output;
        }
    }
    if (isEmptyMessage(msg)) return true;
    if (!show_tool_output and isToolRole(msg.role)) return true;
    return false;
}

fn isEmptyMessage(msg: types.ChatMessage) bool {
    if (msg.attachments) |attachments| {
        if (attachments.len > 0) return false;
    }
    const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
    return trimmed.len == 0;
}

fn selectionRange(state: *const ViewState) ?[2]usize {
    const anchor = state.selection_anchor orelse return null;
    const focus = state.selection_focus orelse return null;
    if (anchor == focus) return null;
    if (anchor < focus) return .{ anchor, focus };
    return .{ focus, anchor };
}

fn buildSelectableBuffer(
    allocator: std.mem.Allocator,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    show_tool_output: bool,
) ?[]u8 {
    var out = std.ArrayList(u8).empty;
    const separator = "\n\n";

    var wrote_any = false;
    for (messages) |msg| {
        if (shouldSkipMessage(msg, inbox, show_tool_output)) continue;
        var display = buildDisplayText(allocator, msg.content);
        defer display.deinit(allocator);
        if (wrote_any) {
            _ = out.appendSlice(allocator, separator) catch return null;
        }
        _ = out.appendSlice(allocator, display.text) catch return null;
        wrote_any = true;
    }
    if (stream_text) |stream| {
        var display = buildDisplayText(allocator, stream);
        defer display.deinit(allocator);
        if (wrote_any) {
            _ = out.appendSlice(allocator, separator) catch return null;
        }
        _ = out.appendSlice(allocator, display.text) catch return null;
        wrote_any = true;
    }

    if (!wrote_any) {
        out.deinit(allocator);
        return null;
    }
    const owned = out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return null;
    };
    return owned;
}

const empty_z = [_:0]u8{};
