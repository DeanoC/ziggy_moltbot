const std = @import("std");
const types = @import("../protocol/types.zig");
const session_kind = @import("../client/session_kind.zig");
const session_keys = @import("../client/session_keys.zig");

pub fn matchesAgent(session: types.Session, agent_id: []const u8) bool {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "agent:{s}:", .{agent_id}) catch "";
    if (prefix.len > 0 and std.mem.startsWith(u8, session.key, prefix)) {
        return true;
    }

    // Fallback for legacy keys that may not include the full `agent:<id>:` shape.
    if (session_keys.parse(session.key)) |parts| {
        return std.mem.eql(u8, parts.agent_id, agent_id);
    }
    return std.mem.eql(u8, agent_id, "main");
}

pub fn includeForAgent(
    session: types.Session,
    agent_id: []const u8,
    include_system: bool,
) bool {
    if (!matchesAgent(session, agent_id)) return false;
    if (!include_system and session_kind.isAutomationSession(session)) return false;
    return true;
}

pub fn updatedDesc(sessions: []const types.Session, a: usize, b: usize) bool {
    const updated_a = sessions[a].updated_at orelse 0;
    const updated_b = sessions[b].updated_at orelse 0;
    if (updated_a == updated_b) return a < b;
    return updated_a > updated_b;
}

pub fn bucketKey(session: types.Session) []const u8 {
    if (session_keys.parse(session.key)) |parts| {
        return parts.label;
    }
    return session.key;
}

pub fn bucketKeyForSessionKey(session_key: []const u8) []const u8 {
    if (session_keys.parse(session_key)) |parts| {
        return parts.label;
    }
    return session_key;
}

pub fn bucketLabelFromKey(bucket_key: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, bucket_key, " \t\r\n");
    if (trimmed.len == 0) return "Conversation";
    if (std.ascii.eqlIgnoreCase(trimmed, "main")) return "Main chat";
    if (hasPrefixIgnoreCase(trimmed, "chat-")) return "Chat";

    if (trimmed.len > 48 and std.mem.indexOfScalar(u8, trimmed, ' ') == null) {
        const keep = @min(trimmed.len, 45);
        return std.fmt.bufPrint(buf, "{s}...", .{trimmed[0..keep]}) catch "Conversation";
    }
    return trimmed;
}

pub fn displayLabel(
    session: types.Session,
    agent_id: []const u8,
    ordinal: usize,
    buf: []u8,
) []const u8 {
    _ = agent_id;
    _ = ordinal;
    if (session.display_name) |name| {
        if (name.len > 0 and !looksMachineLabel(name)) return name;
    }
    if (session.label) |label| {
        if (label.len > 0 and !looksMachineLabel(label)) return label;
    }
    return bucketLabelFromKey(bucketKey(session), buf);
}

pub fn displayLabelForKey(
    sessions: []const types.Session,
    agent_id: []const u8,
    session_key: []const u8,
    buf: []u8,
) ?[]const u8 {
    var ordinal: usize = 0;
    for (sessions) |session| {
        if (!matchesAgent(session, agent_id)) continue;
        if (std.mem.eql(u8, session.key, session_key)) {
            return displayLabel(session, agent_id, ordinal, buf);
        }
        if (!includeForAgent(session, agent_id, true)) continue;
        ordinal += 1;
    }
    return null;
}

pub fn secondaryLabel(
    now_ms: i64,
    session: types.Session,
    buf: []u8,
) []const u8 {
    var rel_buf: [64]u8 = undefined;
    const rel = relativeTimeLabel(now_ms, session.updated_at, &rel_buf);
    var id_buf: [48]u8 = undefined;
    const sid = sessionIdentifierLabel(session, &id_buf);

    if (session_kind.isAutomationSession(session)) {
        if (sid) |id| {
            if (std.mem.eql(u8, rel, "never")) {
                return std.fmt.bufPrint(buf, "System • {s}", .{id}) catch "System";
            }
            return std.fmt.bufPrint(buf, "System • {s} • {s}", .{ id, rel }) catch "System";
        }
        if (std.mem.eql(u8, rel, "never")) return "System";
        return std.fmt.bufPrint(buf, "System • {s}", .{rel}) catch "System";
    }
    if (sid) |id| {
        if (std.mem.eql(u8, rel, "never")) return id;
        return std.fmt.bufPrint(buf, "{s} • {s}", .{ id, rel }) catch rel;
    }
    return rel;
}

pub fn relativeTimeLabel(now_ms: i64, updated_at: ?i64, buf: []u8) []const u8 {
    const ts = updated_at orelse 0;
    if (ts <= 0) return "never";
    const delta_ms = if (now_ms > ts) now_ms - ts else 0;
    const seconds = @as(u64, @intCast(@divTrunc(delta_ms, 1000)));
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;

    if (seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "now";
    }
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "now";
    }
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "days ago";
}

fn looksMachineLabel(label: []const u8) bool {
    if (session_kind.isAutomationLabel(label)) return true;
    if (hasPrefixIgnoreCase(label, "chat-")) return true;
    if (hasPrefixIgnoreCase(label, "agent:")) return true;
    if (containsIgnoreCase(label, "webchat:")) return true;
    if (containsIgnoreCase(label, "g-agent-")) return true;
    if (containsIgnoreCase(label, "agent-") and std.mem.count(u8, label, "-") >= 2) return true;
    if (std.mem.indexOfScalar(u8, label, ':') != null and std.mem.count(u8, label, "-") >= 2 and std.mem.count(u8, label, ":") >= 1) {
        return true;
    }

    var punctuation: usize = 0;
    var digits: usize = 0;
    for (label) |ch| {
        if (ch == '-' or ch == '_' or ch == ':' or ch == '/') punctuation += 1;
        if (std.ascii.isDigit(ch)) digits += 1;
    }
    if (label.len >= 20 and punctuation >= 2 and digits >= 4) return true;
    return false;
}

pub fn sessionIdentifierLabel(session: types.Session, buf: []u8) ?[]const u8 {
    const raw = session.session_id orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len <= 12) return trimmed;
    return std.fmt.bufPrint(buf, "{s}...", .{trimmed[0..8]}) catch trimmed;
}

fn hasPrefixIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (text.len < needle.len) return false;

    var index: usize = 0;
    while (index + needle.len <= text.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(text[index .. index + needle.len], needle)) return true;
    }
    return false;
}
