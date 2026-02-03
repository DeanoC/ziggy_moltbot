const std = @import("std");
const zgui = @import("zgui");
const types = @import("../protocol/types.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const image_cache = @import("image_cache.zig");
const components = @import("components/components.zig");
const theme = @import("theme.zig");

pub const ChatViewOptions = struct {
    select_copy_mode: bool = false,
    show_tool_output: bool = false,
};

pub fn hasSelection() bool {
    return chat_select_start != chat_select_end;
}

pub fn copySelectionToClipboard(allocator: std.mem.Allocator) void {
    const selection = selectionSlice() orelse return;
    if (selection.len == 0) return;
    const buf = allocator.alloc(u8, selection.len + 1) catch return;
    defer allocator.free(buf);
    @memcpy(buf[0..selection.len], selection);
    buf[selection.len] = 0;
    zgui.setClipboardText(buf[0.. :0]);
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
        zgui.setClipboardText(zbuf);
    }
}

pub fn draw(
    allocator: std.mem.Allocator,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    height: f32,
    opts: ChatViewOptions,
) void {
    const clamped = if (height > 60.0) height else 60.0;
    if (zgui.beginChild("ChatHistory", .{ .h = clamped, .child_flags = .{ .border = true } })) {
        const scroll_max = zgui.getScrollMaxY();
        const was_at_bottom = scroll_max <= 0.0 or zgui.getScrollY() >= (scroll_max - 4.0);
        var content_changed = false;

        const last_id_hash = if (messages.len > 0)
            std.hash.Wyhash.hash(0, messages[messages.len - 1].id)
        else
            0;
        const last_len = if (messages.len > 0) messages[messages.len - 1].content.len else 0;

        if (messages.len != last_message_count or last_id_hash != last_last_id_hash or last_len != last_last_len) {
            content_changed = true;
        }

        if (stream_text) |stream| {
            if (stream.len != last_stream_len) {
                content_changed = true;
            }
        } else if (last_stream_len != 0) {
            content_changed = true;
        }

        last_message_count = messages.len;
        last_last_id_hash = last_id_hash;
        last_last_len = last_len;
        last_stream_len = if (stream_text) |stream| stream.len else 0;
        if (opts.show_tool_output != last_show_tool_output) {
            content_changed = true;
        }
        last_show_tool_output = opts.show_tool_output;

        // Header controls are in the Chat panel (outside the scroll view).
        if (opts.select_copy_mode) {
            if (content_changed or chat_buffer.items.len == 0) {
                _ = ensureChatBuffer(allocator, messages, stream_text, inbox, opts.show_tool_output);
                resetSelection();
            }
            const zbuf = bufferZ();
            _ = zgui.inputTextMultiline("##chat_select", .{
                .buf = zbuf,
                .h = clamped - 20.0,
                .flags = .{ .read_only = true, .callback_always = true },
                .callback = chatSelectCallback,
            });
        } else {
            const now_ms = std.time.milliTimestamp();
            for (messages, 0..) |msg, index| {
                if (inbox) |store| {
                    if (store.isCommandMessage(msg.id)) continue;
                }
                if (!opts.show_tool_output and isToolRole(msg.role)) {
                    continue;
                }
                zgui.pushIntId(@intCast(index));
                defer zgui.popId();
                const align_right = std.mem.eql(u8, msg.role, "user");
                components.composite.message_bubble.draw(.{
                    .id = msg.id,
                    .role = msg.role,
                    .content = msg.content,
                    .timestamp_ms = msg.timestamp,
                    .now_ms = now_ms,
                    .align_right = align_right,
                });

                if (msg.attachments) |attachments| {
                    drawAttachments(attachments, align_right);
                }

                if (zgui.beginPopupContextItem()) {
                    if (zgui.menuItem("Copy message", .{})) {
                        const msg_z = zgui.formatZ("{s}", .{msg.content});
                        zgui.setClipboardText(msg_z);
                        zgui.closeCurrentPopup();
                    }
                    zgui.endPopup();
                }

                zgui.dummy(.{ .w = 0.0, .h = theme.activeTheme().spacing.sm });
            }
            if (stream_text) |stream| {
                zgui.dummy(.{ .w = 0.0, .h = theme.activeTheme().spacing.sm });
                components.composite.message_bubble.draw(.{
                    .id = "streaming",
                    .role = "assistant",
                    .content = stream,
                    .timestamp_ms = now_ms,
                    .now_ms = now_ms,
                    .align_right = false,
                });
            }
        }

        if (content_changed and was_at_bottom) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
        }
    }
    zgui.endChild();
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

fn drawAttachments(attachments: []const types.ChatAttachment, align_right: bool) void {
    const t = theme.activeTheme();
    const avail = zgui.getContentRegionAvail()[0];
    const bubble_width = messageBubbleWidth(avail);
    const cursor_start = zgui.getCursorPos();

    if (align_right and avail > bubble_width) {
        zgui.setCursorPosX(cursor_start[0] + (avail - bubble_width));
    }

    var has_non_image = false;
    for (attachments) |attachment| {
        if (isImageAttachment(attachment)) continue;
        has_non_image = true;
        const label = attachment.name orelse attachment.url;
        components.core.badge.draw(label, .{ .variant = .neutral, .filled = false, .size = .small });
        zgui.sameLine(.{ .spacing = t.spacing.xs });
    }
    if (has_non_image) {
        zgui.newLine();
    }

    for (attachments) |attachment| {
        if (!isImageAttachment(attachment)) continue;
        image_cache.request(attachment.url);
        const max_width = @max(120.0, @min(320.0, bubble_width));
        const max_height: f32 = 240.0;
        if (image_cache.get(attachment.url)) |entry| {
            switch (entry.state) {
                .ready => {
                    const tex_id: zgui.TextureIdent = @enumFromInt(@as(u64, entry.texture_id));
                    const tex_ref = zgui.TextureRef{ .tex_data = null, .tex_id = tex_id };
                    const w = @as(f32, @floatFromInt(entry.width));
                    const h = @as(f32, @floatFromInt(entry.height));
                    const aspect = if (h > 0) w / h else 1.0;
                    var draw_w = @min(max_width, w);
                    var draw_h = draw_w / aspect;
                    if (draw_h > max_height) {
                        draw_h = max_height;
                        draw_w = draw_h * aspect;
                    }
                    zgui.image(tex_ref, .{ .w = draw_w, .h = draw_h });
                },
                .loading => {
                    zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Loading image...", .{});
                    zgui.dummy(.{ .w = max_width, .h = 120.0 });
                },
                .failed => {
                    zgui.textColored(.{ 0.9, 0.4, 0.4, 1.0 }, "Image failed to load", .{});
                    if (entry.error_message) |err| {
                        zgui.sameLine(.{});
                        zgui.textDisabled("{s}", .{err});
                    }
                },
            }
        } else {
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Loading image...", .{});
            zgui.dummy(.{ .w = max_width, .h = 120.0 });
        }
        zgui.dummy(.{ .w = 0.0, .h = t.spacing.xs });
    }

    zgui.setCursorPosX(cursor_start[0]);
}

fn messageBubbleWidth(avail: f32) f32 {
    return @min(560.0, avail * 0.82);
}

var last_message_count: usize = 0;
var last_last_id_hash: u64 = 0;
var last_last_len: usize = 0;
var last_stream_len: usize = 0;
var chat_buffer: std.ArrayList(u8) = .empty;
var last_show_tool_output: bool = false;
var chat_select_start: usize = 0;
var chat_select_end: usize = 0;

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
        if (inbox) |store| {
            if (store.isCommandMessage(msg.id)) continue;
        }
        if (!show_tool_output and isToolRole(msg.role)) continue;
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

fn selectionSlice() ?[]const u8 {
    if (chat_buffer.items.len == 0) return null;
    const text_len = chat_buffer.items.len - 1;
    if (text_len == 0) return null;
    var start = chat_select_start;
    var end = chat_select_end;
    if (start > end) {
        const tmp = start;
        start = end;
        end = tmp;
    }
    if (start >= text_len or end > text_len) return null;
    if (start == end) return null;
    return chat_buffer.items[start..end];
}

fn resetSelection() void {
    chat_select_start = 0;
    chat_select_end = 0;
}

fn chatSelectCallback(data: *zgui.InputTextCallbackData) callconv(.c) i32 {
    const start_i = if (data.selection_start < 0) 0 else data.selection_start;
    const end_i = if (data.selection_end < 0) 0 else data.selection_end;
    chat_select_start = @intCast(start_i);
    chat_select_end = @intCast(end_i);
    return 0;
}

const empty_z = [_:0]u8{};
