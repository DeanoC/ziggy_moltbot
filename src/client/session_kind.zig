const std = @import("std");
const types = @import("../protocol/types.zig");
const session_keys = @import("session_keys.zig");

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

pub fn isAutomationKind(kind: []const u8) bool {
    return std.ascii.eqlIgnoreCase(kind, "cron") or
        std.ascii.eqlIgnoreCase(kind, "heartbeat") or
        std.ascii.eqlIgnoreCase(kind, "worker") or
        std.ascii.eqlIgnoreCase(kind, "automation");
}

pub fn isAutomationLabel(label: []const u8) bool {
    // Backstop in case the gateway doesn't provide a kind. Session keys typically look like:
    //   agent:<agent_id>:chat-<id>
    // We treat non-chat labels like cron/heartbeat/worker as automation to avoid accidental sends.
    if (isAutomationKind(label)) return true;

    return startsWithIgnoreCase(label, "cron-") or
        startsWithIgnoreCase(label, "heartbeat-") or
        startsWithIgnoreCase(label, "worker-") or
        startsWithIgnoreCase(label, "automation-");
}

pub fn isAutomationSession(session: types.Session) bool {
    if (session.kind) |kind| {
        if (isAutomationKind(kind)) return true;
    }
    if (session_keys.parse(session.key)) |parts| {
        if (isAutomationLabel(parts.label)) return true;
    }
    return false;
}
