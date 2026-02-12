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
    //   agent:<agent_id>:<bucket>
    // where <bucket> is often "main". We treat known automation labels as system sessions.
    if (isAutomationKind(label)) return true;

    return startsWithIgnoreCase(label, "cron-") or
        startsWithIgnoreCase(label, "heartbeat-") or
        startsWithIgnoreCase(label, "worker-") or
        startsWithIgnoreCase(label, "automation-") or
        startsWithIgnoreCase(label, "webchat:") or
        startsWithIgnoreCase(label, "g-agent-") or
        containsAutomationToken(label);
}

pub fn isAutomationSession(session: types.Session) bool {
    if (session.kind) |kind| {
        if (isAutomationKind(kind)) return true;
    }
    if (isAutomationLabel(session.key)) return true;
    if (session.label) |label| {
        if (isAutomationLabel(label)) return true;
    }
    if (session.display_name) |name| {
        if (isAutomationLabel(name)) return true;
    }
    if (session_keys.parse(session.key)) |parts| {
        if (isAutomationLabel(parts.label)) return true;
    }
    return false;
}

fn containsAutomationToken(label: []const u8) bool {
    return containsDelimitedToken(label, "heartbeat") or
        containsDelimitedToken(label, "cron") or
        containsDelimitedToken(label, "automation");
}

fn containsDelimitedToken(haystack: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;
    if (haystack.len < token.len) return false;

    var i: usize = 0;
    while (i + token.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + token.len], token)) continue;

        const left_ok = if (i == 0)
            true
        else
            !std.ascii.isAlphanumeric(haystack[i - 1]);
        const right_index = i + token.len;
        const right_ok = if (right_index >= haystack.len)
            true
        else
            !std.ascii.isAlphanumeric(haystack[right_index]);

        if (left_ok and right_ok) return true;
    }
    return false;
}
