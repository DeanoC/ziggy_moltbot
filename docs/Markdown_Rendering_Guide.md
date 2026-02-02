# ZiggyStarClaw: Markdown Rendering Implementation Guide

**Author:** Manus AI  
**Date:** February 01, 2026  
**Version:** 1.0  

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Overview and Architecture](#overview-and-architecture)
3. [Library Selection and Integration](#library-selection-and-integration)
4. [Markdown AST to ImGui Renderer](#markdown-ast-to-imgui-renderer)
5. [In-Chat Markdown Rendering](#in-chat-markdown-rendering)
6. [New Panel Type: MarkdownViewer](#new-panel-type-markdownviewer)
7. [Syntax Highlighting for Code Blocks](#syntax-highlighting-for-code-blocks)
8. [Image and Link Handling](#image-and-link-handling)
9. [Build System Updates](#build-system-updates)
10. [Testing Strategy](#testing-strategy)
11. [Implementation Roadmap](#implementation-roadmap)
12. [References](#references)

---

## Executive Summary

This implementation guide provides a detailed roadmap for adding **Markdown rendering** capabilities to ZiggyStarClaw. The design enables rich text formatting both inline within chat messages and as a dedicated viewer panel for Markdown documents. The implementation leverages the CommonMark-compliant **koino** library for parsing and a custom ImGui renderer for display.

Markdown support will enhance the readability of chat messages containing formatted text, code snippets, and documentation, while also providing a dedicated panel for viewing and editing `.md` files with live preview capabilities.

---

## Overview and Architecture

Markdown support in ZiggyStarClaw will be implemented through two complementary features:

1. **Inline in Chat** - Messages in the chat view will be rendered as Markdown
2. **Dedicated Tab** - A new `MarkdownViewerPanel` will allow users to open and view `.md` files in a separate tab

Both features share a common rendering engine that converts Markdown AST nodes to ImGui widgets.

### Architecture Components

| Component | Location | Responsibility |
|-----------|----------|----------------|
| **Markdown Parser** | External: `koino` | Parse Markdown to AST |
| **ImGui Renderer** | `src/ui/markdown_renderer.zig` | Convert AST to ImGui widgets |
| **Chat Integration** | `src/ui/chat_view.zig` | Inline message rendering |
| **Viewer Panel** | `src/ui/panels/markdown_panel.zig` | Dedicated document viewer |
| **Syntax Highlighter** | `src/ui/syntax_highlighter.zig` | Code block highlighting |
| **Link Handler** | `src/ui/link_handler.zig` | Platform-specific URL opening |

### Data Flow

```
Markdown Text → koino Parser → AST → MarkdownRenderer → ImGui Widgets → Display
```

The renderer walks the AST tree recursively, generating appropriate ImGui widgets for each node type (headings, paragraphs, lists, code blocks, etc.).

---

## Library Selection and Integration

After evaluating available options, **koino** is recommended as the primary Markdown parser for the following reasons:

| Criterion | koino | zigdown | zmd |
|-----------|-------|---------|-----|
| **CommonMark Compliance** | ✅ 100% | ❌ No | ✅ Yes |
| **GFM Extensions** | ✅ Yes | ⚠️ Partial | ❌ No |
| **Pure Zig** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Dependencies** | None | TreeSitter (optional) | None |
| **License** | MIT | MIT | MIT |
| **Maintenance** | Active | Active | Active |

**Recommendation:** Use **koino** for its CommonMark and GFM compliance [1].

**Alternative:** Consider **zigdown** if advanced features like TreeSitter syntax highlighting are required, though it is not CommonMark compliant [2].

### Adding koino Dependency

**File: `build.zig.zon` (additions)**

```zon
.{
    .name = "ziggystarclaw",
    .version = "0.2.0",
    .dependencies = .{
        // ... existing dependencies ...
        .koino = .{
            .url = "git+https://nossa.ee/~talya/koino",
            .hash = "1220...", // Run `zig build --fetch` to populate
        },
    },
}
```

After adding the dependency, run:

```bash
zig build --fetch
```

This will download koino and populate the hash automatically.

**File: `build.zig` (additions)**

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add koino dependency
    const koino_dep = b.dependency("koino", .{
        .target = target,
        .optimize = optimize,
    });
    const koino_mod = koino_dep.module("koino");

    // For each executable target
    const exe = b.addExecutable(.{
        .name = "ziggystarclaw",
        .root_source_file = b.path("src/main_native.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add koino module
    exe.root_module.addImport("koino", koino_mod);
    
    // ... rest of build configuration
}
```

---

## Markdown AST to ImGui Renderer

The core of the Markdown support is a renderer that walks the koino AST and generates appropriate ImGui widgets.

**File: `src/ui/markdown_renderer.zig`**

```zig
const std = @import("std");
const zgui = @import("zgui");
const koino = @import("koino");
const theme = @import("theme.zig");
const image_cache = @import("image_cache.zig");

pub const MarkdownRenderer = struct {
    allocator: std.mem.Allocator,
    
    // Style state
    is_bold: bool = false,
    is_italic: bool = false,
    is_code: bool = false,
    heading_level: u8 = 0,
    list_depth: u8 = 0,
    ordered_list_counter: u32 = 0,
    
    // Configuration
    base_font_size: f32 = 14.0,
    code_background: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
    link_color: [4]f32 = .{ 0.4, 0.6, 1.0, 1.0 },
    
    // Callbacks for external handling
    on_link_click: ?*const fn (url: []const u8) void = null,
    on_image_request: ?*const fn (url: []const u8) void = null,

    pub fn init(allocator: std.mem.Allocator) MarkdownRenderer {
        return .{ .allocator = allocator };
    }

    pub fn render(self: *MarkdownRenderer, markdown_text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Parse options for GFM extensions
        var options = koino.Options{
            .extensions = .{
                .table = true,
                .strikethrough = true,
                .autolink = true,
            },
        };

        var parser = koino.Parser.init(arena_alloc, options);
        defer parser.deinit();

        try parser.feed(markdown_text);
        const doc = try parser.finish();

        // Reset state
        self.resetState();

        // Render the document
        try self.renderNode(doc);
    }

    fn resetState(self: *MarkdownRenderer) void {
        self.is_bold = false;
        self.is_italic = false;
        self.is_code = false;
        self.heading_level = 0;
        self.list_depth = 0;
        self.ordered_list_counter = 0;
    }

    fn renderNode(self: *MarkdownRenderer, node: *koino.Node) !void {
        switch (node.data) {
            .document => {
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
            },
            .heading => |h| {
                self.heading_level = h.level;
                zgui.spacing();
                
                // Push heading style
                const scale = switch (h.level) {
                    1 => 2.0,
                    2 => 1.7,
                    3 => 1.4,
                    4 => 1.2,
                    else => 1.1,
                };
                zgui.setWindowFontScale(scale);
                
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                
                zgui.setWindowFontScale(1.0);
                self.heading_level = 0;
                zgui.spacing();
            },
            .paragraph => {
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                zgui.spacing();
            },
            .text => |t| {
                self.renderText(t.content);
            },
            .softbreak => {
                zgui.sameLine(.{});
            },
            .linebreak => {
                zgui.newLine();
            },
            .code => |c| {
                self.renderInlineCode(c.content);
            },
            .code_block => |cb| {
                self.renderCodeBlock(cb.content, cb.info);
            },
            .emph => {
                self.is_italic = true;
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                self.is_italic = false;
            },
            .strong => {
                self.is_bold = true;
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                self.is_bold = false;
            },
            .link => |l| {
                zgui.pushStyleColor(.{ .idx = .text, .col = self.link_color });
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                zgui.popStyleColor(.{});
                
                // Handle link click
                if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left)) {
                    if (self.on_link_click) |callback| {
                        callback(l.url);
                    }
                }
            },
            .image => |img| {
                self.renderImage(img.url, img.title);
            },
            .list => |l| {
                self.list_depth += 1;
                if (l.list_type == .ordered) {
                    self.ordered_list_counter = l.start;
                }
                
                const indent = @as(f32, @floatFromInt(self.list_depth)) * 20.0;
                zgui.indent(.{ .indent_w = indent });
                
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                
                zgui.unindent(.{ .indent_w = indent });
                self.list_depth -= 1;
            },
            .item => {
                // Render bullet or number
                if (self.ordered_list_counter > 0) {
                    zgui.text("{d}. ", .{self.ordered_list_counter});
                    self.ordered_list_counter += 1;
                } else {
                    zgui.text("• ", .{});
                }
                zgui.sameLine(.{});
                
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
            },
            .block_quote => {
                zgui.pushStyleColor(.{ .idx = .text, .col = .{ 0.7, 0.7, 0.7, 1.0 } });
                zgui.indent(.{ .indent_w = 15.0 });
                
                // Draw vertical bar
                const pos = zgui.getCursorScreenPos();
                const draw_list = zgui.getWindowDrawList();
                draw_list.addLine(
                    .{ pos[0] - 10.0, pos[1] },
                    .{ pos[0] - 10.0, pos[1] + 50.0 },
                    0xFF888888,
                    2.0,
                );
                
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                
                zgui.unindent(.{ .indent_w = 15.0 });
                zgui.popStyleColor(.{});
            },
            .thematic_break => {
                zgui.separator();
            },
            .table => {
                try self.renderTable(node);
            },
            .strikethrough => {
                // ImGui doesn't have native strikethrough, so we'll render with color
                zgui.pushStyleColor(.{ .idx = .text, .col = .{ 0.5, 0.5, 0.5, 1.0 } });
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                zgui.popStyleColor(.{});
            },
            else => {
                // Handle any unimplemented node types
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
            },
        }
    }

    fn renderText(self: *MarkdownRenderer, text: []const u8) void {
        if (self.is_bold and self.is_italic) {
            // Bold italic - use color to indicate
            zgui.textColored(.{ 1.0, 1.0, 0.8, 1.0 }, "{s}", .{text});
        } else if (self.is_bold) {
            // Bold text
            zgui.textColored(.{ 1.0, 1.0, 1.0, 1.0 }, "{s}", .{text});
        } else if (self.is_italic) {
            // Italic text - use slightly different color
            zgui.textColored(.{ 0.9, 0.9, 1.0, 1.0 }, "{s}", .{text});
        } else {
            zgui.textWrapped("{s}", .{text});
        }
    }

    fn renderInlineCode(self: *MarkdownRenderer, code: []const u8) void {
        _ = self;
        zgui.pushStyleColor(.{ .idx = .text, .col = .{ 0.9, 0.6, 0.3, 1.0 } });
        zgui.text("`{s}`", .{code});
        zgui.popStyleColor(.{});
    }

    fn renderCodeBlock(self: *MarkdownRenderer, code: []const u8, language: ?[]const u8) void {
        _ = self;
        
        // Language label
        if (language) |lang| {
            zgui.textDisabled("{s}", .{lang});
        }
        
        // Code block background
        zgui.pushStyleColor(.{ .idx = .child_bg, .col = .{ 0.1, 0.1, 0.1, 1.0 } });
        
        const avail = zgui.getContentRegionAvail();
        const line_count = std.mem.count(u8, code, "\n") + 1;
        const height = @min(@as(f32, @floatFromInt(line_count)) * 16.0 + 16.0, 300.0);
        
        if (zgui.beginChild("CodeBlock", .{ .w = avail[0], .h = height, .child_flags = .{ .border = true } })) {
            zgui.pushStyleColor(.{ .idx = .text, .col = .{ 0.8, 0.9, 0.8, 1.0 } });
            zgui.textWrapped("{s}", .{code});
            zgui.popStyleColor(.{});
        }
        zgui.endChild();
        
        zgui.popStyleColor(.{});
        zgui.spacing();
    }

    fn renderImage(self: *MarkdownRenderer, url: []const u8, alt_text: ?[]const u8) void {
        // Request image loading
        if (self.on_image_request) |callback| {
            callback(url);
        }
        
        // Check if image is in cache
        if (image_cache.get(url)) |entry| {
            switch (entry.state) {
                .ready => {
                    const tex_id: zgui.TextureIdent = @enumFromInt(@as(u64, entry.texture_id));
                    const tex_ref = zgui.TextureRef{ .tex_data = null, .tex_id = tex_id };
                    
                    const max_width: f32 = 400.0;
                    const w = @as(f32, @floatFromInt(entry.width));
                    const h = @as(f32, @floatFromInt(entry.height));
                    const aspect = if (h > 0) w / h else 1.0;
                    const draw_w = @min(max_width, w);
                    const draw_h = draw_w / aspect;
                    
                    zgui.image(tex_ref, .{ .w = draw_w, .h = draw_h });
                },
                .loading => {
                    zgui.textDisabled("Loading image...", .{});
                },
                .failed => {
                    zgui.textColored(.{ 0.9, 0.4, 0.4, 1.0 }, "Failed to load image", .{});
                },
            }
        } else {
            // Show alt text while loading
            if (alt_text) |alt| {
                zgui.textDisabled("[Image: {s}]", .{alt});
            } else {
                zgui.textDisabled("[Image]", .{});
            }
        }
    }

    fn renderTable(self: *MarkdownRenderer, table_node: *koino.Node) !void {
        // Count columns from header row
        var col_count: usize = 0;
        if (table_node.first_child) |header_row| {
            var cell = header_row.first_child;
            while (cell) |c| {
                col_count += 1;
                cell = c.next;
            }
        }
        
        if (col_count == 0) return;
        
        if (zgui.beginTable("MarkdownTable", @intCast(col_count), .{
            .flags = .{
                .borders_h = true,
                .borders_v = true,
                .row_bg = true,
            },
        })) {
            defer zgui.endTable();
            
            var row = table_node.first_child;
            var is_header = true;
            
            while (row) |r| {
                zgui.tableNextRow(.{});
                
                var cell = r.first_child;
                var col: i32 = 0;
                
                while (cell) |c| {
                    if (zgui.tableSetColumnIndex(col)) {
                        if (is_header) {
                            zgui.pushStyleColor(.{ .idx = .text, .col = .{ 1.0, 1.0, 1.0, 1.0 } });
                        }
                        
                        try self.renderNode(c);
                        
                        if (is_header) {
                            zgui.popStyleColor(.{});
                        }
                    }
                    col += 1;
                    cell = c.next;
                }
                
                is_header = false;
                row = r.next;
            }
        }
    }
};
```

---

## In-Chat Markdown Rendering

To enable Markdown rendering in chat messages, we modify `chat_view.zig` to use the new renderer.

**File: `src/ui/chat_view.zig` (modifications)**

```zig
const std = @import("std");
const zgui = @import("zgui");
const types = @import("../protocol/types.zig");
const ui_command_inbox = @import("ui_command_inbox.zig");
const image_cache = @import("image_cache.zig");
const markdown_renderer = @import("markdown_renderer.zig");

// Configuration for markdown rendering in chat
var enable_markdown_rendering: bool = true;
var md_renderer: ?markdown_renderer.MarkdownRenderer = null;

pub fn setMarkdownEnabled(enabled: bool) void {
    enable_markdown_rendering = enabled;
}

pub fn draw(
    allocator: std.mem.Allocator,
    messages: []const types.ChatMessage,
    stream_text: ?[]const u8,
    inbox: ?*const ui_command_inbox.UiCommandInbox,
    height: f32,
) void {
    // Initialize markdown renderer if needed
    if (md_renderer == null) {
        md_renderer = markdown_renderer.MarkdownRenderer.init(allocator);
        md_renderer.?.on_image_request = imageRequestCallback;
    }

    const clamped = if (height > 60.0) height else 60.0;
    if (zgui.beginChild("ChatHistory", .{ .h = clamped, .child_flags = .{ .border = true } })) {
        // ... existing scroll handling code ...

        // Markdown toggle checkbox
        if (zgui.checkbox("Render Markdown", .{ .v = &enable_markdown_rendering })) {
            // Toggle changed
        }
        zgui.sameLine(.{});
        
        // ... rest of existing controls ...

        if (select_mode) {
            // ... existing select mode code ...
        } else {
            const now_ms = std.time.milliTimestamp();
            var last_role: ?[]const u8 = null;

            for (messages, 0..) |msg, index| {
                if (inbox) |store| {
                    if (store.isCommandMessage(msg.id)) continue;
                }
                zgui.pushIntId(@intCast(index));
                defer zgui.popId();
                
                if (last_role == null or !std.mem.eql(u8, last_role.?, msg.role)) {
                    if (last_role != null) {
                        zgui.spacing();
                    }
                    renderGroupHeader(msg.role, now_ms, msg.timestamp);
                    zgui.separator();
                    last_role = msg.role;
                }
                
                // Render message content
                if (enable_markdown_rendering and md_renderer != null) {
                    md_renderer.?.render(msg.content) catch {
                        // Fallback to plain text on error
                        zgui.textWrapped("{s}", .{msg.content});
                    };
                } else {
                    zgui.textWrapped("{s}", .{msg.content});
                }

                // ... existing attachment handling code ...
            }
            
            // ... existing stream text handling ...
        }

        // ... existing auto-scroll code ...
    }
    zgui.endChild();
}

fn imageRequestCallback(url: []const u8) void {
    image_cache.request(url);
}

// ... rest of existing functions ...
```

---

## New Panel Type: MarkdownViewer

The dedicated Markdown viewer panel allows users to open and view `.md` files with edit/preview modes.

**File: `src/ui/workspace.zig` (additions)**

```zig
pub const PanelKind = enum {
    Chat,
    CodeEditor,
    ToolOutput,
    Control,
    MarkdownViewer, // NEW
};

pub const MarkdownViewerPanel = struct {
    file_path: []const u8,
    content: text_buffer.TextBuffer,
    scroll_y: f32 = 0.0,
    edit_mode: bool = false,
};

pub const PanelData = union(enum) {
    Chat: ChatPanel,
    CodeEditor: CodeEditorPanel,
    ToolOutput: ToolOutputPanel,
    Control: ControlPanel,
    MarkdownViewer: MarkdownViewerPanel, // NEW

    pub fn deinit(self: *PanelData, allocator: std.mem.Allocator) void {
        switch (self.*) {
            // ... existing cases ...
            .MarkdownViewer => |*viewer| {
                allocator.free(viewer.file_path);
                viewer.content.deinit(allocator);
            },
        }
    }
};
```

**File: `src/ui/panels/markdown_panel.zig`**

```zig
const std = @import("std");
const zgui = @import("zgui");
const workspace = @import("../workspace.zig");
const markdown_renderer = @import("../markdown_renderer.zig");
const text_buffer = @import("../text_buffer.zig");

pub const MarkdownPanelAction = struct {
    save_file: bool = false,
    reload_file: bool = false,
    toggle_edit: bool = false,
};

var md_renderer: ?markdown_renderer.MarkdownRenderer = null;

pub fn draw(
    panel: *workspace.Panel,
    allocator: std.mem.Allocator,
) MarkdownPanelAction {
    var action = MarkdownPanelAction{};
    
    if (panel.kind != .MarkdownViewer) return action;
    var viewer = &panel.data.MarkdownViewer;

    // Initialize renderer if needed
    if (md_renderer == null) {
        md_renderer = markdown_renderer.MarkdownRenderer.init(allocator);
    }

    // Toolbar
    if (zgui.button(if (viewer.edit_mode) "Preview" else "Edit", .{})) {
        viewer.edit_mode = !viewer.edit_mode;
        action.toggle_edit = true;
    }
    zgui.sameLine(.{});
    
    if (viewer.edit_mode) {
        if (zgui.button("Save", .{})) {
            action.save_file = true;
        }
        zgui.sameLine(.{});
    }
    
    if (zgui.button("Reload", .{})) {
        action.reload_file = true;
    }
    zgui.sameLine(.{});
    
    zgui.textDisabled("{s}", .{viewer.file_path});
    
    zgui.separator();

    // Content area
    const avail = zgui.getContentRegionAvail();
    
    if (viewer.edit_mode) {
        // Edit mode - show text editor
        const min_capacity = @max(@as(usize, 64 * 1024), viewer.content.slice().len);
        _ = viewer.content.ensureCapacity(allocator, min_capacity) catch {};
        
        const changed = zgui.inputTextMultiline("##md_editor", .{
            .buf = viewer.content.asZ(),
            .w = avail[0],
            .h = avail[1] - zgui.getFrameHeightWithSpacing(),
            .flags = .{ .allow_tab_input = true },
        });
        
        if (changed) {
            viewer.content.syncFromInput();
            panel.state.is_dirty = true;
        }
    } else {
        // Preview mode - render markdown
        if (zgui.beginChild("MarkdownPreview", .{
            .w = avail[0],
            .h = avail[1],
            .child_flags = .{ .border = true },
        })) {
            md_renderer.?.render(viewer.content.slice()) catch |err| {
                zgui.textColored(.{ 1.0, 0.4, 0.4, 1.0 }, "Error rendering markdown: {s}", .{@errorName(err)});
                zgui.separator();
                zgui.textWrapped("{s}", .{viewer.content.slice()});
            };
        }
        zgui.endChild();
    }

    // Status bar
    zgui.separator();
    const line_count = std.mem.count(u8, viewer.content.slice(), "\n") + 1;
    const char_count = viewer.content.slice().len;
    zgui.textDisabled("{d} lines | {d} characters", .{ line_count, char_count });
    
    if (panel.state.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.8, 0.2, 1.0 }, "(modified)", .{});
    }

    return action;
}
```

---

## Syntax Highlighting for Code Blocks

For enhanced code block rendering with syntax highlighting, we can create a simple keyword-based highlighter.

**File: `src/ui/syntax_highlighter.zig`**

```zig
const std = @import("std");
const zgui = @import("zgui");

pub const TokenType = enum {
    keyword,
    string,
    number,
    comment,
    operator,
    identifier,
    punctuation,
    default,
};

pub const Token = struct {
    text: []const u8,
    token_type: TokenType,
};

pub fn getTokenColor(token_type: TokenType) [4]f32 {
    return switch (token_type) {
        .keyword => .{ 0.8, 0.4, 0.8, 1.0 },    // Purple
        .string => .{ 0.6, 0.9, 0.6, 1.0 },     // Green
        .number => .{ 0.9, 0.7, 0.4, 1.0 },     // Orange
        .comment => .{ 0.5, 0.5, 0.5, 1.0 },    // Gray
        .operator => .{ 0.9, 0.9, 0.6, 1.0 },   // Yellow
        .identifier => .{ 0.7, 0.8, 1.0, 1.0 }, // Light blue
        .punctuation => .{ 0.8, 0.8, 0.8, 1.0 },// Light gray
        .default => .{ 0.9, 0.9, 0.9, 1.0 },    // White
    };
}

// Simple keyword-based highlighting for common languages
pub fn highlightCode(allocator: std.mem.Allocator, code: []const u8, language: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();
    
    const keywords = getKeywordsForLanguage(language);
    
    // Simple tokenization (a full implementation would use proper lexers)
    var i: usize = 0;
    var token_start: usize = 0;
    
    while (i < code.len) {
        const c = code[i];
        
        // Check for string literals
        if (c == '"' or c == '\'') {
            if (i > token_start) {
                try addToken(&tokens, code[token_start..i], keywords);
            }
            const quote = c;
            const string_start = i;
            i += 1;
            while (i < code.len and code[i] != quote) {
                if (code[i] == '\\' and i + 1 < code.len) i += 1;
                i += 1;
            }
            if (i < code.len) i += 1;
            try tokens.append(.{ .text = code[string_start..i], .token_type = .string });
            token_start = i;
            continue;
        }
        
        // Check for comments
        if (c == '/' and i + 1 < code.len) {
            if (code[i + 1] == '/') {
                if (i > token_start) {
                    try addToken(&tokens, code[token_start..i], keywords);
                }
                const comment_start = i;
                while (i < code.len and code[i] != '\n') i += 1;
                try tokens.append(.{ .text = code[comment_start..i], .token_type = .comment });
                token_start = i;
                continue;
            }
        }
        
        // Check for whitespace/separators
        if (std.ascii.isWhitespace(c) or isPunctuation(c)) {
            if (i > token_start) {
                try addToken(&tokens, code[token_start..i], keywords);
            }
            try tokens.append(.{ .text = code[i .. i + 1], .token_type = if (isPunctuation(c)) .punctuation else .default });
            i += 1;
            token_start = i;
            continue;
        }
        
        i += 1;
    }
    
    if (token_start < code.len) {
        try addToken(&tokens, code[token_start..], keywords);
    }
    
    return tokens.toOwnedSlice();
}

fn addToken(tokens: *std.ArrayList(Token), text: []const u8, keywords: []const []const u8) !void {
    var token_type: TokenType = .identifier;
    
    // Check if it's a number
    if (text.len > 0 and (std.ascii.isDigit(text[0]) or (text[0] == '-' and text.len > 1 and std.ascii.isDigit(text[1])))) {
        token_type = .number;
    } else {
        // Check if it's a keyword
        for (keywords) |kw| {
            if (std.mem.eql(u8, text, kw)) {
                token_type = .keyword;
                break;
            }
        }
    }
    
    try tokens.append(.{ .text = text, .token_type = token_type });
}

fn isPunctuation(c: u8) bool {
    return switch (c) {
        '(', ')', '{', '}', '[', ']', ';', ',', '.', ':', '=', '+', '-', '*', '/', '<', '>', '!', '&', '|', '^', '~', '%', '@', '#' => true,
        else => false,
    };
}

fn getKeywordsForLanguage(language: []const u8) []const []const u8 {
    if (std.mem.eql(u8, language, "zig")) {
        return &.{
            "const", "var", "fn", "pub", "return", "if", "else", "while", "for",
            "switch", "break", "continue", "defer", "errdefer", "try", "catch",
            "struct", "enum", "union", "error", "null", "undefined", "true", "false",
            "and", "or", "orelse", "comptime", "inline", "extern", "export",
        };
    } else if (std.mem.eql(u8, language, "python") or std.mem.eql(u8, language, "py")) {
        return &.{
            "def", "class", "if", "elif", "else", "for", "while", "return", "import",
            "from", "as", "try", "except", "finally", "with", "lambda", "yield",
            "True", "False", "None", "and", "or", "not", "in", "is", "pass", "break",
            "continue", "raise", "assert", "global", "nonlocal", "async", "await",
        };
    } else if (std.mem.eql(u8, language, "javascript") or std.mem.eql(u8, language, "js") or std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "ts")) {
        return &.{
            "const", "let", "var", "function", "return", "if", "else", "for", "while",
            "switch", "case", "break", "continue", "class", "extends", "new", "this",
            "import", "export", "default", "from", "async", "await", "try", "catch",
            "finally", "throw", "typeof", "instanceof", "null", "undefined", "true", "false",
        };
    }
    // Default: no keywords
    return &.{};
}
```

### Integration with Markdown Renderer

Update `renderCodeBlock` in `markdown_renderer.zig` to use syntax highlighting:

```zig
fn renderCodeBlock(self: *MarkdownRenderer, code: []const u8, language: ?[]const u8) void {
    const syntax = @import("syntax_highlighter.zig");
    
    // Language label
    if (language) |lang| {
        zgui.textDisabled("{s}", .{lang});
        
        // Try syntax highlighting
        const tokens = syntax.highlightCode(self.allocator, code, lang) catch null;
        if (tokens) |tok_list| {
            defer self.allocator.free(tok_list);
            
            zgui.pushStyleColor(.{ .idx = .child_bg, .col = .{ 0.1, 0.1, 0.1, 1.0 } });
            const avail = zgui.getContentRegionAvail();
            const height = @min(300.0, 200.0);
            
            if (zgui.beginChild("CodeBlock", .{ .w = avail[0], .h = height, .child_flags = .{ .border = true } })) {
                for (tok_list) |token| {
                    const color = syntax.getTokenColor(token.token_type);
                    zgui.pushStyleColor(.{ .idx = .text, .col = color });
                    zgui.text("{s}", .{token.text});
                    zgui.popStyleColor(.{});
                    zgui.sameLine(.{});
                }
            }
            zgui.endChild();
            zgui.popStyleColor(.{});
            zgui.spacing();
            return;
        }
    }
    
    // Fallback to plain rendering
    // ... existing plain code block rendering ...
}
```

---

## Image and Link Handling

The Markdown renderer integrates with the existing `image_cache.zig` for image loading and provides callbacks for link handling.

**File: `src/ui/link_handler.zig`**

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn openUrl(url: []const u8) void {
    if (builtin.target.isWasm()) {
        // Use WASM bridge to open URL
        wasmOpenUrl(url);
    } else {
        // Use platform-specific method
        nativeOpenUrl(url);
    }
}

extern fn wasm_open_url(url: [*]const u8, len: usize) void;

fn wasmOpenUrl(url: []const u8) void {
    wasm_open_url(url.ptr, url.len);
}

fn nativeOpenUrl(url: []const u8) void {
    // Fork a process to open the URL
    const argv = switch (builtin.os.tag) {
        .linux => &.{ "xdg-open", url },
        .macos => &.{ "open", url },
        .windows => &.{ "start", url },
        else => return,
    };
    
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    _ = child.spawn() catch return;
}
```

Update `markdown_renderer.zig` to use the link handler:

```zig
const link_handler = @import("link_handler.zig");

// In MarkdownRenderer.init:
pub fn init(allocator: std.mem.Allocator) MarkdownRenderer {
    return .{
        .allocator = allocator,
        .on_link_click = linkClickCallback,
    };
}

fn linkClickCallback(url: []const u8) void {
    link_handler.openUrl(url);
}
```

---

## Build System Updates

The `build.zig` file needs to be updated to include the koino dependency.

**File: `build.zig` (complete example)**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add koino dependency
    const koino_dep = b.dependency("koino", .{
        .target = target,
        .optimize = optimize,
    });
    const koino_mod = koino_dep.module("koino");

    // For each executable target
    const exe = b.addExecutable(.{
        .name = "ziggystarclaw",
        .root_source_file = b.path("src/main_native.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add koino module
    exe.root_module.addImport("koino", koino_mod);
    
    // ... rest of build configuration
    
    b.installArtifact(exe);
}
```

---

## Testing Strategy

Testing should cover both unit tests for individual components and integration tests for the complete workflow.

**File: `tests/markdown_tests.zig`**

```zig
const std = @import("std");
const testing = std.testing;
const markdown_renderer = @import("../src/ui/markdown_renderer.zig");

test "markdown renderer initializes correctly" {
    var renderer = markdown_renderer.MarkdownRenderer.init(testing.allocator);
    defer _ = renderer; // No deinit needed for basic init
    
    try testing.expect(renderer.is_bold == false);
    try testing.expect(renderer.is_italic == false);
}

test "syntax highlighter identifies zig keywords" {
    const syntax = @import("../src/ui/syntax_highlighter.zig");
    const tokens = try syntax.highlightCode(testing.allocator, "const x = 42;", "zig");
    defer testing.allocator.free(tokens);
    
    // First token should be "const" keyword
    try testing.expect(tokens.len > 0);
    try testing.expectEqualStrings("const", tokens[0].text);
    try testing.expect(tokens[0].token_type == .keyword);
}

test "markdown renderer handles basic text" {
    const koino = @import("koino");
    
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    const markdown = "Hello **world**!";
    
    var parser = koino.Parser.init(arena.allocator(), .{});
    defer parser.deinit();
    
    try parser.feed(markdown);
    const doc = try parser.finish();
    
    try testing.expect(doc.first_child != null);
}
```

---

## Implementation Roadmap

The following table outlines the recommended implementation order and estimated effort for each component:

| Phase | Component | Estimated Effort | Dependencies |
|-------|-----------|------------------|--------------|
| 1 | koino integration | 1-2 days | None |
| 2 | Basic Markdown Renderer | 3-4 days | Phase 1 |
| 3 | Chat integration | 1-2 days | Phase 2 |
| 4 | MarkdownViewer Panel | 2-3 days | Phase 2 |
| 5 | Syntax highlighting | 2-3 days | Phase 2 |
| 6 | Image handling | 1 day | Phase 2 |
| 7 | Link handling | 1 day | Phase 2 |
| 8 | Testing and refinement | 2-3 days | All phases |

**Total estimated effort: 13-18 days**

### Recommended Implementation Order

1. **Start with koino integration** - Get the parser working first
2. **Build basic renderer** - Start with simple nodes (paragraphs, headings)
3. **Add chat integration** - Enable inline rendering
4. **Create viewer panel** - Build dedicated document viewer
5. **Add syntax highlighting** - Enhance code blocks
6. **Integrate images and links** - Complete feature set
7. **Test thoroughly** - Verify all Markdown features work correctly

---

## References

[1] Kivikakk, T. (n.d.). *koino: CommonMark + GFM compatible Markdown parser and renderer*. GitHub. https://github.com/kivikakk/koino

[2] Crabill, J. (n.d.). *zigdown: Markdown toolset in Zig*. GitHub. https://github.com/JacobCrabill/zigdown

[3] Mekhontsev, D. (n.d.). *imgui_md: Markdown renderer for Dear ImGui using MD4C parser*. GitHub. https://github.com/mekhontsev/imgui_md

[4] Jetzig Framework. (n.d.). *zmd: Markdown parser and HTML translator*. GitHub. https://github.com/jetzig-framework/zmd
