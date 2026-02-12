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
    var fence_state = FencedCodeState{};

    var cursor: usize = 0;
    while (cursor < markdown.len) {
        const rel_nl = std.mem.indexOfScalarPos(u8, markdown, cursor, '\n');
        const line_end = rel_nl orelse markdown.len;
        const has_newline = rel_nl != null;
        const line = markdown[cursor..line_end];

        try writeMarkdownLine(writer, line, has_newline, mode, &fence_state);

        if (!has_newline) break;
        cursor = line_end + 1;
    }

    if (markdown.len == 0) {
        // Preserve prior behavior for empty docs: write nothing.
        return;
    }
}

const FencedCodeState = struct {
    active: bool = false,
    marker: u8 = 0,
    min_len: usize = 0,
};

const FenceRunInfo = struct {
    marker: u8,
    len: usize,
    rest: []const u8,
};

fn writeMarkdownLine(
    writer: anytype,
    line: []const u8,
    has_newline: bool,
    mode: RenderMode,
    fence_state: *FencedCodeState,
) !void {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    const indent_len = line.len - trimmed.len;

    if (fenceRunInfo(trimmed)) |fence| {
        if (fence_state.active) {
            if (fence.marker == fence_state.marker and
                fence.len >= fence_state.min_len and
                std.mem.trim(u8, fence.rest, " \t").len == 0)
            {
                fence_state.* = .{};
                if (has_newline) try writer.writeByte('\n');
                return;
            }
        } else {
            fence_state.active = true;
            fence_state.marker = fence.marker;
            fence_state.min_len = fence.len;
            if (has_newline) try writer.writeByte('\n');
            return;
        }
    }

    if (fence_state.active) {
        if (mode == .ansi) try writer.writeAll("\x1b[33m");
        try writer.writeAll(line);
        if (mode == .ansi) try writer.writeAll("\x1b[39m");
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    if (headingInfo(trimmed)) |heading| {
        if (indent_len > 0) try writer.writeAll(line[0..indent_len]);

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
        if (indent_len > 0) try writer.writeAll(line[0..indent_len]);

        if (mode == .ansi) {
            try writer.writeAll("\x1b[36m");
            try writer.writeAll(trimmed[0..prefix_len]);
            try writer.writeAll("\x1b[39m");
        } else {
            try writer.writeAll(trimmed[0..prefix_len]);
        }
        try renderInline(writer, trimmed[prefix_len..], mode);
        if (has_newline) try writer.writeByte('\n');
        return;
    }

    try renderInline(writer, line, mode);
    if (has_newline) try writer.writeByte('\n');
}

fn fenceRunInfo(trimmed_line: []const u8) ?FenceRunInfo {
    if (trimmed_line.len < 3) return null;

    const marker = trimmed_line[0];
    if (marker != '`' and marker != '~') return null;

    var idx: usize = 0;
    while (idx < trimmed_line.len and trimmed_line[idx] == marker) : (idx += 1) {}
    if (idx < 3) return null;

    return .{
        .marker = marker,
        .len = idx,
        .rest = trimmed_line[idx..],
    };
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

    const content = normalizeHeadingContent(trimmed_line[idx + 1 ..]);
    return .{
        .level = @as(u8, @intCast(idx)),
        .content = content,
    };
}

fn normalizeHeadingContent(raw_content: []const u8) []const u8 {
    const trimmed_left = std.mem.trimLeft(u8, raw_content, " ");
    const trimmed_right = std.mem.trimRight(u8, trimmed_left, " \t");

    var end = trimmed_right.len;
    while (end > 0 and trimmed_right[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed_right.len) return trimmed_right;

    if (end == 0) return trimmed_right;
    if (!std.ascii.isWhitespace(trimmed_right[end - 1])) return trimmed_right;

    return std.mem.trimRight(u8, trimmed_right[0..end], " \t");
}

fn unorderedListContent(trimmed_line: []const u8) ?[]const u8 {
    if (trimmed_line.len < 2) return null;
    const marker = trimmed_line[0];
    if ((marker == '-' or marker == '*' or marker == '+') and isListWhitespace(trimmed_line[1])) {
        return std.mem.trimLeft(u8, trimmed_line[2..], " \t");
    }
    return null;
}

fn orderedListPrefixLen(trimmed_line: []const u8) ?usize {
    if (trimmed_line.len < 3) return null;

    var idx: usize = 0;
    while (idx < trimmed_line.len and std.ascii.isDigit(trimmed_line[idx])) : (idx += 1) {}
    if (idx == 0) return null;
    if (idx + 1 >= trimmed_line.len) return null;

    const delimiter = trimmed_line[idx];
    if (delimiter != '.' and delimiter != ')') return null;
    if (!isListWhitespace(trimmed_line[idx + 1])) return null;
    return idx + 2;
}

fn isListWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
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

test "plain mode preserves heading indentation and strips closing heading markers" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input =
        "  ## Title ##\n" ++
        "10. **item**\n";

    try writeMarkdown(out.writer(std.testing.allocator), input, .plain);

    try std.testing.expectEqualStrings(
        "  Title\n" ++
            "10. item\n",
        out.items,
    );
}

test "ansi mode adds formatting sequences for heading/list/inline" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input = "## Header\n- **bold** `code`\n1. item\n";
    try writeMarkdown(out.writer(std.testing.allocator), input, .ansi);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[36m•\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[33mcode\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[36m1. \x1b[39m") != null);
}

test "markdown renderer supports tilde fences and 1) ordered lists" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input =
        "1) __first__\n" ++
        "~~~zig\n" ++
        "const x = 1;\n" ++
        "~~~\n";

    try writeMarkdown(out.writer(std.testing.allocator), input, .plain);

    try std.testing.expectEqualStrings(
        "1) first\n" ++
            "\n" ++
            "const x = 1;\n" ++
            "\n",
        out.items,
    );
}

test "markdown renderer only closes fences on matching marker" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const input =
        "```\n" ++
        "still code\n" ++
        "~~~\n" ++
        "```\n" ++
        "after\n";

    try writeMarkdown(out.writer(std.testing.allocator), input, .plain);

    try std.testing.expectEqualStrings(
        "\n" ++
            "still code\n" ++
            "~~~\n" ++
            "\n" ++
            "after\n",
        out.items,
    );
}
