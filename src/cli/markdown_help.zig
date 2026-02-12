const std = @import("std");

pub const RenderMode = enum {
    plain,
    ansi,
};

pub fn writeMarkdownForStdout(
    writer: anytype,
    allocator: std.mem.Allocator,
    markdown: []const u8,
) !void {
    const mode = detectRenderModeForStdout(allocator);
    try writeMarkdown(writer, markdown, mode);
}

pub fn detectRenderModeForStdout(allocator: std.mem.Allocator) RenderMode {
    if (helpRenderOverrideFromEnv(allocator)) |override| return override;

    const stdout = std.fs.File.stdout();
    if (!stdout.isTty()) return .plain;

    if (envVarPresent(allocator, "NO_COLOR")) return .plain;

    if (envVarValueOwned(allocator, "CLICOLOR")) |value| {
        defer allocator.free(value);
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 1 and trimmed[0] == '0') return .plain;
    }

    if (envVarValueOwned(allocator, "TERM")) |term| {
        defer allocator.free(term);
        const trimmed = std.mem.trim(u8, term, " \t\r\n");
        if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "dumb")) return .plain;
    } else {
        return .plain;
    }

    return .ansi;
}

fn helpRenderOverrideFromEnv(allocator: std.mem.Allocator) ?RenderMode {
    const raw = envVarValueOwned(allocator, "ZSC_HELP_MARKDOWN") orelse return null;
    defer allocator.free(raw);

    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(value, "ansi") or
        std.ascii.eqlIgnoreCase(value, "color") or
        std.ascii.eqlIgnoreCase(value, "coloured") or
        std.ascii.eqlIgnoreCase(value, "colored") or
        std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return .ansi;
    }

    if (std.ascii.eqlIgnoreCase(value, "plain") or
        std.ascii.eqlIgnoreCase(value, "text") or
        std.ascii.eqlIgnoreCase(value, "none") or
        std.ascii.eqlIgnoreCase(value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return .plain;
    }

    return null;
}

fn envVarPresent(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = envVarValueOwned(allocator, name) orelse return false;
    allocator.free(value);
    return true;
}

fn envVarValueOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

pub fn writeMarkdown(writer: anytype, markdown: []const u8, mode: RenderMode) !void {
    var in_fenced_code = false;

    var cursor: usize = 0;
    while (cursor < markdown.len) {
        const rel_nl = std.mem.indexOfScalarPos(u8, markdown, cursor, '\n');
        const line_end = rel_nl orelse markdown.len;
        const has_newline = rel_nl != null;
        const line = markdown[cursor..line_end];

        try writeMarkdownLine(writer, line, has_newline, mode, &in_fenced_code);

        if (!has_newline) break;
        cursor = line_end + 1;
    }

    if (markdown.len == 0) {
        // Preserve prior behavior for empty docs: write nothing.
        return;
    }
}

fn writeMarkdownLine(
    writer: anytype,
    line: []const u8,
    has_newline: bool,
    mode: RenderMode,
    in_fenced_code: *bool,
) !void {
    const trimmed = std.mem.trimLeft(u8, line, " \t");

    if (std.mem.startsWith(u8, trimmed, "```")) {
        in_fenced_code.* = !in_fenced_code.*;
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    if (in_fenced_code.*) {
        if (mode == .ansi) try writer.writeAll("\x1b[33m");
        try writer.writeAll(line);
        if (mode == .ansi) try writer.writeAll("\x1b[39m");
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    if (headingInfo(trimmed)) |heading| {
        if (mode == .ansi) {
            try writer.writeAll("\x1b[1m");
            if (heading.level == 1) try writer.writeAll("\x1b[4m");
        }

        try renderInline(writer, heading.content, mode);

        if (mode == .ansi) {
            if (heading.level == 1) try writer.writeAll("\x1b[24m");
            try writer.writeAll("\x1b[22m");
        }
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    if (unorderedListContent(trimmed)) |content| {
        const indent_len = line.len - trimmed.len;
        if (indent_len > 0) try writer.writeAll(line[0..indent_len]);

        if (mode == .ansi) {
            try writer.writeAll("\x1b[36m•\x1b[39m ");
        } else {
            try writer.writeAll("- ");
        }

        try renderInline(writer, content, mode);
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    if (orderedListPrefixLen(trimmed)) |prefix_len| {
        const indent_len = line.len - trimmed.len;
        if (indent_len > 0) try writer.writeAll(line[0..indent_len]);

        try writer.writeAll(trimmed[0..prefix_len]);
        try renderInline(writer, trimmed[prefix_len..], mode);
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    try renderInline(writer, line, mode);
    if (has_newline) try writer.writeByte('\n');
}

const HeadingInfo = struct {
    level: u8,
    content: []const u8,
};

fn headingInfo(trimmed_line: []const u8) ?HeadingInfo {
    if (trimmed_line.len < 2 or trimmed_line[0] != '#') return null;

    var idx: usize = 0;
    while (idx < trimmed_line.len and trimmed_line[idx] == '#' and idx < 6) : (idx += 1) {}
    if (idx == 0 or idx >= trimmed_line.len) return null;
    if (trimmed_line[idx] != ' ') return null;

    const content = std.mem.trimLeft(u8, trimmed_line[idx + 1 ..], " ");
    return .{
        .level = @as(u8, @intCast(idx)),
        .content = content,
    };
}

fn unorderedListContent(trimmed_line: []const u8) ?[]const u8 {
    if (trimmed_line.len < 2) return null;
    const marker = trimmed_line[0];
    if ((marker == '-' or marker == '*' or marker == '+') and trimmed_line[1] == ' ') {
        return trimmed_line[2..];
    }
    return null;
}

fn orderedListPrefixLen(trimmed_line: []const u8) ?usize {
    if (trimmed_line.len < 3) return null;

    var idx: usize = 0;
    while (idx < trimmed_line.len and std.ascii.isDigit(trimmed_line[idx])) : (idx += 1) {}
    if (idx == 0) return null;
    if (idx + 1 >= trimmed_line.len) return null;
    if (trimmed_line[idx] != '.' or trimmed_line[idx + 1] != ' ') return null;
    return idx + 2;
}

fn renderInline(writer: anytype, text: []const u8, mode: RenderMode) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end_idx| {
                const inner = text[i + 1 .. end_idx];
                if (mode == .ansi) try writer.writeAll("\x1b[33m");
                try writer.writeAll(inner);
                if (mode == .ansi) try writer.writeAll("\x1b[39m");
                i = end_idx + 1;
                continue;
            }
        }

        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end_idx| {
                const inner = text[i + 2 .. end_idx];
                if (mode == .ansi) try writer.writeAll("\x1b[1m");
                try writer.writeAll(inner);
                if (mode == .ansi) try writer.writeAll("\x1b[22m");
                i = end_idx + 2;
                continue;
            }
        }

        if (i + 1 < text.len and text[i] == '_' and text[i + 1] == '_') {
            if (std.mem.indexOfPos(u8, text, i + 2, "__")) |end_idx| {
                const inner = text[i + 2 .. end_idx];
                if (mode == .ansi) try writer.writeAll("\x1b[1m");
                try writer.writeAll(inner);
                if (mode == .ansi) try writer.writeAll("\x1b[22m");
                i = end_idx + 2;
                continue;
            }
        }

        try writer.writeByte(text[i]);
        i += 1;
    }
}

test "plain markdown fallback strips basic markdown markers" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input =
        "# CLI\n" ++
        "- **bold** and `code`\n" ++
        "1. __item__\n" ++
        "```\n" ++
        "echo hi\n" ++
        "```\n";

    try writeMarkdown(out.writer(std.testing.allocator), input, .plain);

    try std.testing.expectEqualStrings(
        "CLI\n" ++
            "- bold and code\n" ++
            "1. item\n" ++
            "\n" ++
            "echo hi\n" ++
            "\n",
        out.items,
    );
}

test "ansi mode adds formatting sequences for heading/list/inline" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input = "## Header\n- **bold** `code`\n";
    try writeMarkdown(out.writer(std.testing.allocator), input, .ansi);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[36m•\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[33mcode\x1b[39m") != null);
}
