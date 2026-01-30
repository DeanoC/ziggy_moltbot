# Zig MoltBot Client - Comprehensive Implementation Plan

**Project:** A clean, performant browser-based and native MoltBot client built in Zig with ImGui UI
**Author:** Deano (Game Designer, Zig enthusiast)
**Status:** Planning Phase
**Last Updated:** January 28, 2026

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Technology Stack](#technology-stack)
4. [Project Structure](#project-structure)
5. [Phase 1: Core Infrastructure](#phase-1-core-infrastructure)
6. [Phase 2: Protocol Implementation](#phase-2-protocol-implementation)
7. [Phase 3: UI Layer](#phase-3-ui-layer)
8. [Phase 4: Integration & Testing](#phase-4-integration--testing)
9. [Phase 5: Cross-Platform Deployment](#phase-5-cross-platform-deployment)
10. [Dependencies & Libraries](#dependencies--libraries)
11. [Build Configuration](#build-configuration)
12. [Development Workflow](#development-workflow)

---

## Project Overview

This project aims to create a replacement for MoltBot's built-in UI with a clean, minimal, and performant interface built entirely in Zig. The application will:

- **Browser Target**: Compile to WebAssembly for browser deployment
- **Native Targets**: Support desktop (macOS, Linux, Windows) and mobile (Android) via native Zig compilation
- **Single Codebase**: Share protocol, client logic, and UI framework across all platforms
- **ImGui-Based UI**: Leverage immediate-mode GUI for simplicity and efficiency
- **Direct WSS Connection**: Communicate directly with MoltBot's WebSocket endpoint using token authentication

### Key Advantages

- **No Framework Bloat**: ImGui provides immediate-mode UI without React/Vue/Svelte complexity
- **Small Binaries**: Zig produces efficient code; WASM bundle will be minimal
- **Your Preference**: You already know and prefer Zig over Rust/TypeScript
- **Game Dev Proven**: ImGui is battle-tested in game development
- **Cross-Platform**: Single codebase compiles to multiple targets

---

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                    MoltBot Client (Zig)                 │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │              UI Layer (ImGui)                    │   │
│  │  - Chat View                                     │   │
│  │  - Settings/Config Panel                        │   │
│  │  - Message History                              │   │
│  │  - Status Indicators                            │   │
│  └──────────────────────────────────────────────────┘   │
│                          ▲                               │
│                          │                               │
│  ┌──────────────────────────────────────────────────┐   │
│  │           Client Logic Layer                     │   │
│  │  - State Management                             │   │
│  │  - Message Routing                              │   │
│  │  - Event Handling                               │   │
│  │  - Configuration Management                     │   │
│  └──────────────────────────────────────────────────┘   │
│                          ▲                               │
│                          │                               │
│  ┌──────────────────────────────────────────────────┐   │
│  │         Protocol Layer (WebSocket)              │   │
│  │  - WebSocket Connection Management              │   │
│  │  - JSON Message Serialization/Deserialization   │   │
│  │  - Authentication & Token Handling              │   │
│  │  - Message Type Definitions                     │   │
│  └──────────────────────────────────────────────────┘   │
│                          ▲                               │
│                          │                               │
│                  ┌───────┴────────┐                      │
│                  │                │                      │
│         ┌────────▼──────┐  ┌──────▼────────┐            │
│         │ MoltBot WSS   │  │ Local Config  │            │
│         │ Endpoint      │  │ Storage       │            │
│         └───────────────┘  └───────────────┘            │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

### Compilation Targets

| Target | Build Command | Output | Use Case |
|--------|---------------|--------|----------|
| **WASM (Browser)** | `zig build -Dtarget=wasm32-emscripten` | `.wasm` + HTML/CSS | Web deployment |
| **Linux Desktop** | `zig build -Dtarget=x86_64-linux` | ELF binary | Linux development |
| **macOS Desktop** | `zig build -Dtarget=aarch64-macos` | Mach-O binary | macOS development |
| **Windows Desktop** | `zig build -Dtarget=x86_64-windows` | PE binary | Windows development |
| **Android** | `zig build -Dtarget=aarch64-android` | `.so` library | Mobile (future) |

---

## Technology Stack

### Core Dependencies

| Component | Library | Version | Purpose | Link |
|-----------|---------|---------|---------|------|
| **WebSocket** | `websocket.zig` | Latest | WebSocket client for WSS communication | [karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig) |
| **UI Framework** | `zgui` | Latest | ImGui bindings for Zig | [zig-gamedev/zgui](https://github.com/zig-gamedev/zgui) |
| **JSON** | `std.json` | Built-in | JSON serialization/deserialization | [Zig Std Lib](https://ziglang.org/documentation/master/std/) |
| **HTTP/TLS** | `std.http` | Built-in | HTTP client for potential REST fallback | [Zig Std Lib](https://ziglang.org/documentation/master/std/) |
| **Rendering** | `sokol` (via zgui) | Latest | Graphics backend for ImGui | [floooh/sokol](https://github.com/floooh/sokol) |

### Development Tools

- **Zig Compiler**: v0.15.1+ (latest stable)
- **Build System**: Zig's built-in build system (`build.zig`)
- **Package Manager**: Zig's native package manager (`build.zig.zon`)
- **Version Control**: Git

### Reference Implementation

- **MoltBot Repository**: [moltbot/moltbot](https://github.com/moltbot/moltbot)
  - TypeScript UI Reference: `/ui/src/` directory
  - Protocol Documentation: Embedded in TypeScript types
  - WebSocket Examples: `app-gateway.ts`, `app-events.ts`

---

## Project Structure

```
ziggystarclaw/
├── build.zig                      # Build configuration
├── build.zig.zon                  # Package manifest with dependencies
├── README.md                      # Project documentation
├── LICENSE                        # MIT License
│
├── src/
│   ├── main.zig                   # Entry point (platform-specific)
│   ├── main_wasm.zig              # WASM entry point
│   ├── main_native.zig            # Native entry point
│   │
│   ├── protocol/
│   │   ├── types.zig              # MoltBot message type definitions
│   │   ├── messages.zig           # Message serialization/deserialization
│   │   └── constants.zig          # Protocol constants and enums
│   │
│   ├── client/
│   │   ├── websocket_client.zig   # WebSocket connection wrapper
│   │   ├── state.zig              # Client state management
│   │   ├── event_handler.zig      # Event routing and handling
│   │   └── config.zig             # Configuration management
│   │
│   ├── ui/
│   │   ├── imgui_wrapper.zig      # ImGui integration layer
│   │   ├── main_window.zig        # Main window layout
│   │   ├── chat_view.zig          # Chat message display
│   │   ├── input_panel.zig        # Message input UI
│   │   ├── settings_view.zig      # Settings/configuration UI
│   │   ├── status_bar.zig         # Connection status display
│   │   └── theme.zig              # UI theming and colors
│   │
│   ├── platform/
│   │   ├── wasm.zig               # WASM-specific code
│   │   ├── native.zig             # Native platform code
│   │   ├── storage.zig            # Platform-specific storage
│   │   └── network.zig            # Platform-specific networking
│   │
│   └── utils/
│       ├── allocator.zig          # Memory allocation helpers
│       ├── logger.zig             # Logging utilities
│       ├── json_helpers.zig       # JSON parsing utilities
│       └── string_utils.zig       # String manipulation helpers
│
├── assets/
│   ├── fonts/                     # ImGui fonts
│   ├── icons/                     # UI icons (if needed)
│   └── styles/                    # ImGui style definitions
│
├── examples/
│   ├── basic_chat.zig             # Basic chat example
│   └── config_demo.zig            # Configuration UI demo
│
├── tests/
│   ├── protocol_tests.zig         # Protocol serialization tests
│   ├── client_tests.zig           # Client logic tests
│   └── ui_tests.zig               # UI component tests
│
└── docs/
    ├── ARCHITECTURE.md            # Detailed architecture docs
    ├── PROTOCOL.md                # MoltBot protocol documentation
    ├── BUILD.md                   # Build instructions
    └── DEVELOPMENT.md             # Development guide
```

---

## Phase 1: Core Infrastructure

### Objectives

- Set up Zig project structure with build system
- Establish dependency management
- Create basic WebSocket client wrapper
- Implement configuration storage

### Tasks

#### 1.1 Project Initialization

```bash
# Create project directory
mkdir ziggystarclaw
cd ziggystarclaw

# Initialize Git
git init

# Create basic structure
mkdir -p src/{protocol,client,ui,platform,utils} assets tests docs examples
```

#### 1.2 Build Configuration (`build.zig`)

Create `build.zig` with:
- Executable targets for each platform (WASM, Linux, macOS, Windows)
- Dependency linking for websocket.zig and zgui
- Compiler flags for optimization
- Test runner configuration

**Reference**: [Zig Build System Documentation](https://ziglang.org/learn/build-system/)

#### 1.3 Package Manifest (`build.zig.zon`)

Define dependencies:

```zig
.{
    .name = "ziggystarclaw",
    .version = "0.1.0",
    .minimum_zig_version = "0.15.1",
    .dependencies = .{
        .websocket = .{
            .url = "https://github.com/karlseguin/websocket.zig/archive/refs/heads/master.zip",
            .hash = "1220...", // Will be auto-generated
        },
        .zgui = .{
            .url = "https://github.com/zig-gamedev/zgui/archive/refs/heads/main.zip",
            .hash = "1220...",
        },
    },
}
```

**Reference**: [Zig Package Manager Documentation](https://github.com/ziglang/zig/blob/master/doc/build.zig.zon.md)

#### 1.4 WebSocket Client Wrapper

Create `src/client/websocket_client.zig`:

```zig
const std = @import("std");
const ws = @import("websocket");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    conn: ?*ws.Conn = null,
    url: []const u8,
    token: []const u8,
    is_connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url = url,
            .token = token,
        };
    }

    pub fn connect(self: *WebSocketClient) !void {
        // Implementation: Connect to MoltBot WSS endpoint
        // Handle authentication via token
        self.is_connected = true;
    }

    pub fn send(self: *WebSocketClient, message: []const u8) !void {
        // Implementation: Send message to server
    }

    pub fn receive(self: *WebSocketClient) !?[]const u8 {
        // Implementation: Receive message from server
        return null;
    }

    pub fn disconnect(self: *WebSocketClient) void {
        self.is_connected = false;
    }

    pub fn deinit(self: *WebSocketClient) void {
        // Cleanup
    }
};
```

**Reference**: [karlseguin/websocket.zig - Client Section](https://github.com/karlseguin/websocket.zig#client)

#### 1.5 Configuration Management

Create `src/client/config.zig`:

- Store MoltBot server URL (WSS endpoint)
- Store authentication token
- Persist to local storage (browser IndexedDB or native filesystem)
- Load configuration on startup

**Reference**: [MoltBot Pairing Flow](https://github.com/moltbot/moltbot#security-defaults-dm-access)

### Deliverables

- ✅ Project structure created
- ✅ `build.zig` and `build.zig.zon` configured
- ✅ WebSocket client wrapper implemented
- ✅ Configuration storage system working
- ✅ Basic build succeeds for all targets

---

## Phase 2: Protocol Implementation

### Objectives

- Define MoltBot message types based on TypeScript reference
- Implement JSON serialization/deserialization
- Create message routing system
- Build client state machine

### Tasks

#### 2.1 Protocol Type Definitions

Create `src/protocol/types.zig` based on MoltBot TypeScript types:

```zig
// Reference: https://github.com/moltbot/moltbot/blob/main/ui/src/ui/types/

pub const ChatMessage = struct {
    id: []const u8,
    role: []const u8,  // "user" or "assistant"
    content: []const u8,
    timestamp: i64,
    attachments: ?[]ChatAttachment = null,
};

pub const ChatAttachment = struct {
    type: []const u8,  // "image", "file", etc.
    url: []const u8,
    name: ?[]const u8 = null,
};

pub const SessionListResult = struct {
    sessions: []Session,
};

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
};

// ... more types from MoltBot UI
```

**Reference**: [MoltBot UI Types](https://github.com/moltbot/moltbot/tree/main/ui/src/ui/types)

#### 2.2 Message Serialization

Create `src/protocol/messages.zig`:

```zig
const std = @import("std");
const types = @import("types.zig");

pub fn serializeMessage(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    // Use std.json.stringify to convert Zig types to JSON
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try std.json.stringify(message, .{}, buffer.writer());
    return buffer.toOwnedSlice();
}

pub fn deserializeMessage(allocator: std.mem.Allocator, json_data: []const u8, comptime T: type) !T {
    // Use std.json.parseFromSlice to convert JSON to Zig types
    var stream = std.json.TokenStream.init(json_data);
    return try std.json.parse(T, &stream, .{
        .allocator = allocator,
    });
}
```

**Reference**: [Zig std.json Documentation](https://ziglang.org/documentation/master/std/#std.json)

#### 2.3 Event Handler

Create `src/client/event_handler.zig`:

- Route incoming WebSocket messages to appropriate handlers
- Dispatch events to UI layer
- Handle connection state changes

#### 2.4 Client State Machine

Create `src/client/state.zig`:

```zig
pub const ClientState = enum {
    disconnected,
    connecting,
    authenticating,
    connected,
    error,
};

pub const ClientContext = struct {
    state: ClientState,
    current_session: ?[]const u8,
    messages: std.ArrayList(ChatMessage),
    users: std.ArrayList(User),
    // ... more state
};
```

### Deliverables

- ✅ Protocol types defined
- ✅ JSON serialization/deserialization working
- ✅ Event routing system implemented
- ✅ Client state machine operational
- ✅ Tests passing for protocol layer

---

## Phase 3: UI Layer

### Objectives

- Integrate ImGui via zgui
- Build chat view component
- Create settings panel
- Implement message input
- Add status indicators

### Tasks

#### 3.1 ImGui Integration

Create `src/ui/imgui_wrapper.zig`:

```zig
const zgui = @import("zgui");

pub fn init() !void {
    zgui.init(allocator);
    // Configure ImGui settings
    zgui.io.setConfigFlags(.{ .docking_enable = true });
}

pub fn begin_frame() void {
    zgui.newFrame();
}

pub fn end_frame() void {
    zgui.render();
}

pub fn deinit() void {
    zgui.deinit();
}
```

**Reference**: [zig-gamedev/zgui Documentation](https://github.com/zig-gamedev/zgui)

#### 3.2 Main Window Layout

Create `src/ui/main_window.zig`:

- Header with connection status
- Left sidebar with session list
- Center chat view
- Right settings panel
- Bottom message input

#### 3.3 Chat View Component

Create `src/ui/chat_view.zig`:

- Display message history
- Render different message types (text, images, code blocks)
- Auto-scroll to latest message
- Handle message selection/copying

#### 3.4 Message Input Panel

Create `src/ui/input_panel.zig`:

- Text input field with auto-resize
- Send button
- File/image upload button
- Keyboard shortcuts (Enter to send, Shift+Enter for newline)

#### 3.5 Settings View

Create `src/ui/settings_view.zig`:

- Server URL configuration
- Authentication token input
- UI theme selection
- Session management
- Clear history option

#### 3.6 Status Bar

Create `src/ui/status_bar.zig`:

- Connection status indicator
- Current session name
- Message count
- Latency display

### Deliverables

- ✅ ImGui initialized and rendering
- ✅ Main window layout complete
- ✅ All UI components functional
- ✅ Message display working
- ✅ Settings panel operational
- ✅ Status indicators showing correct state

---

## Phase 4: Integration & Testing

### Objectives

- Connect all layers (protocol, client, UI)
- Implement full message flow
- Add error handling and recovery
- Create comprehensive tests

### Tasks

#### 4.1 Message Flow Integration

Connect:
1. UI input → Client message handler
2. Client message handler → WebSocket send
3. WebSocket receive → Event handler
4. Event handler → Client state update
5. State update → UI re-render

#### 4.2 Error Handling

- Connection failures
- Message serialization errors
- Authentication failures
- Network timeouts
- Graceful degradation

#### 4.3 Testing Suite

Create `tests/`:
- Protocol serialization tests
- Client state machine tests
- Message routing tests
- UI component tests
- Integration tests

#### 4.4 Logging & Debugging

Implement `src/utils/logger.zig`:
- Debug logging for development
- Error logging for troubleshooting
- Optional log output to file

### Deliverables

- ✅ Full message flow working end-to-end
- ✅ Error handling robust
- ✅ All tests passing
- ✅ Logging system operational
- ✅ Documentation updated

---

## Phase 5: Cross-Platform Deployment

### Objectives

- Build and test for all target platforms
- Create deployment scripts
- Optimize for each platform
- Document deployment process

### Tasks

#### 5.1 WASM Build & Deployment

```bash
# Build WASM target
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall

# Create HTML wrapper
# Deploy to web server or CDN
```

**Reference**: [Emscripten Zig Integration](https://ziglang.org/learn/build-system/)

#### 5.2 Native Desktop Builds

```bash
# Linux
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# macOS (Apple Silicon)
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# Windows
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

#### 5.3 Android Build (Future)

- Set up Android NDK integration
- Configure build for ARM64
- Package as `.apk` or `.aab`

#### 5.4 CI/CD Pipeline

Create GitHub Actions workflow:
- Build all targets on push
- Run tests
- Generate release artifacts
- Deploy WASM to hosting

### Deliverables

- ✅ WASM builds successfully
- ✅ Native binaries for all platforms
- ✅ Deployment scripts working
- ✅ CI/CD pipeline configured
- ✅ Release process documented

---

## Dependencies & Libraries

### Primary Dependencies

#### 1. **websocket.zig** - WebSocket Client
- **Repository**: [karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig)
- **Purpose**: Handle WebSocket connections to MoltBot WSS endpoint
- **Key Features**:
  - Client and server support
  - Message masking for client payloads
  - Ping/pong handling
  - Connection lifecycle management
- **Usage**: `websocket_client.zig` wrapper
- **Zig Version**: 0.15.1+

#### 2. **zgui** - ImGui Bindings
- **Repository**: [zig-gamedev/zgui](https://github.com/zig-gamedev/zgui)
- **Purpose**: Immediate-mode GUI framework for UI rendering
- **Key Features**:
  - Hand-crafted Zig API with default arguments
  - Full Dear ImGui API exposed
  - DrawList API for vector graphics
  - Plot API for data visualization
  - Node editor API for advanced layouts
  - Docking support
- **Usage**: `ui/` layer components
- **Zig Version**: 0.15.1+
- **Note**: Includes Sokol graphics backend for rendering

#### 3. **std.json** - JSON Serialization (Built-in)
- **Purpose**: Parse and serialize JSON messages
- **Key Features**:
  - `std.json.parseFromSlice()` for deserialization
  - `std.json.stringify()` for serialization
  - Support for custom types via `jsonParse()` and `jsonStringify()`
- **Usage**: `protocol/messages.zig`
- **Documentation**: [Zig Standard Library](https://ziglang.org/documentation/master/std/#std.json)

#### 4. **std.http** - HTTP Client (Built-in)
- **Purpose**: Potential REST fallback or auxiliary HTTP requests
- **Key Features**:
  - HTTP client implementation
  - TLS support via system libraries
- **Usage**: `platform/network.zig` (optional)
- **Documentation**: [Zig Standard Library](https://ziglang.org/documentation/master/std/#std.http)

### Optional/Future Dependencies

| Library | Purpose | Repository | Status |
|---------|---------|-----------|--------|
| **sokol** | Graphics rendering backend | [floooh/sokol](https://github.com/floooh/sokol) | Included via zgui |
| **zstbi** | Image loading | [zig-gamedev/zstbi](https://github.com/zig-gamedev/zstbi) | For image display |
| **zflecs** | Entity component system | [zig-gamedev/zflecs](https://github.com/zig-gamedev/zflecs) | For complex state (future) |

### MoltBot Reference Resources

| Resource | Link | Purpose |
|----------|------|---------|
| **Main Repository** | [moltbot/moltbot](https://github.com/moltbot/moltbot) | Protocol reference |
| **UI Source** | [ui/src/](https://github.com/moltbot/moltbot/tree/main/ui/src) | TypeScript implementation reference |
| **Type Definitions** | [ui/src/ui/types/](https://github.com/moltbot/moltbot/tree/main/ui/src/ui/types) | Message type definitions |
| **Gateway Logic** | [ui/src/ui/app-gateway.ts](https://github.com/moltbot/moltbot/blob/main/ui/src/ui/app-gateway.ts) | WebSocket connection handling |
| **Event Handling** | [ui/src/ui/app-events.ts](https://github.com/moltbot/moltbot/blob/main/ui/src/ui/app-events.ts) | Event routing |
| **Documentation** | [README.md](https://github.com/moltbot/moltbot#readme) | General documentation |

---

## Build Configuration

### `build.zig` Template

```zig
const std = @import("std");
const websocket = @import("websocket");
const zgui = @import("zgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WASM target
    const wasm_exe = b.addExecutable(.{
        .name = "ziggystarclaw-client",
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        }),
        .optimize = optimize,
    });

    // Native target
    const native_exe = b.addExecutable(.{
        .name = "ziggystarclaw-client",
        .root_source_file = b.path("src/main_native.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    const ws_module = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket");

    const zgui_module = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
    }).module("zgui");

    wasm_exe.root_module.addImport("websocket", ws_module);
    wasm_exe.root_module.addImport("zgui", zgui_module);

    native_exe.root_module.addImport("websocket", ws_module);
    native_exe.root_module.addImport("zgui", zgui_module);

    // Install steps
    b.installArtifact(wasm_exe);
    b.installArtifact(native_exe);

    // Run step
    const run_step = b.step("run", "Run the application");
    const run_cmd = b.addRunArtifact(native_exe);
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("tests/protocol_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

### `build.zig.zon` Template

```zig
.{
    .name = "ziggystarclaw",
    .version = "0.1.0",
    .minimum_zig_version = "0.15.1",
    .dependencies = .{
        .websocket = .{
            .url = "https://github.com/karlseguin/websocket.zig/archive/refs/heads/master.zip",
            .hash = "1220<hash_will_be_generated>",
        },
        .zgui = .{
            .url = "https://github.com/zig-gamedev/zgui/archive/refs/heads/main.zip",
            .hash = "1220<hash_will_be_generated>",
        },
    },
}
```

**Reference**: [Zig Build System Documentation](https://ziglang.org/learn/build-system/)

---

## Development Workflow

### Setup

```bash
# Clone repository
git clone https://github.com/yourusername/ziggystarclaw.git
cd ziggystarclaw

# Fetch dependencies
zig build --fetch

# Build for native target
zig build

# Run application
zig build run
```

### Building for Different Targets

```bash
# WASM (Browser)
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall

# Linux
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# macOS (Apple Silicon)
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# macOS (Intel)
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast

# Windows
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

### Testing

```bash
# Run all tests
zig build test

# Run specific test file
zig test tests/protocol_tests.zig

# Run with logging
zig build test -Dlog_level=debug
```

### Debugging

```bash
# Build with debug symbols
zig build -Doptimize=Debug

# Use GDB/LLDB
gdb ./zig-cache/bin/ziggystarclaw-client
```

### Code Organization Best Practices

1. **Keep modules focused**: Each file should have a single responsibility
2. **Use clear naming**: File and function names should be self-documenting
3. **Document public APIs**: Add doc comments to public functions
4. **Test as you go**: Write tests alongside implementation
5. **Avoid circular dependencies**: Structure imports hierarchically

### Git Workflow

```bash
# Create feature branch
git checkout -b feature/websocket-client

# Make changes and commit
git add .
git commit -m "feat: implement WebSocket client wrapper"

# Push and create PR
git push origin feature/websocket-client
```

---

## Next Steps

### Immediate Actions

1. **Create project repository** on GitHub
2. **Set up initial project structure** with `build.zig` and `build.zig.zon`
3. **Add WebSocket dependency** and verify build
4. **Begin Phase 1** with core infrastructure

### Timeline Estimate

| Phase | Duration | Status |
|-------|----------|--------|
| Phase 1: Core Infrastructure | 1-2 weeks | Not Started |
| Phase 2: Protocol Implementation | 1-2 weeks | Not Started |
| Phase 3: UI Layer | 2-3 weeks | Not Started |
| Phase 4: Integration & Testing | 1-2 weeks | Not Started |
| Phase 5: Cross-Platform Deployment | 1 week | Not Started |
| **Total** | **6-10 weeks** | - |

### Success Criteria

- ✅ WASM build compiles successfully
- ✅ Can connect to MoltBot WSS endpoint
- ✅ Can send and receive chat messages
- ✅ UI displays messages correctly
- ✅ Settings panel functional
- ✅ Native builds work on all platforms
- ✅ Binary size < 5MB (WASM) and < 20MB (native)

---

## Additional Resources

### Zig Learning

- [Zig Language Documentation](https://ziglang.org/documentation/master/)
- [Zig Standard Library](https://ziglang.org/documentation/master/std/)
- [Zig Build System Guide](https://ziglang.org/learn/build-system/)
- [Zig Package Manager](https://github.com/ziglang/zig/blob/master/doc/build.zig.zon.md)

### ImGui Resources

- [Dear ImGui Official](https://github.com/ocornut/imgui)
- [ImGui Demo](https://github.com/ocornut/imgui/blob/master/imgui_demo.cpp)
- [zgui Examples](https://github.com/zig-gamedev/zgui/tree/main/examples)

### WebSocket Protocol

- [RFC 6455 - WebSocket Protocol](https://tools.ietf.org/html/rfc6455)
- [WebSocket MDN Documentation](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket)

### MoltBot Protocol

- [MoltBot Repository](https://github.com/moltbot/moltbot)
- [MoltBot UI Implementation](https://github.com/moltbot/moltbot/tree/main/ui/src)
- [MoltBot Type Definitions](https://github.com/moltbot/moltbot/tree/main/ui/src/ui/types)

---

## Questions & Clarifications

### Q: Why Zig over Rust?
**A**: You have existing Zig experience and prefer its pragmatism. Zig's simplicity and lack of framework overhead align with your goals.

### Q: Will WASM performance be acceptable?
**A**: Yes. ImGui is lightweight, and Zig compiles to efficient WASM. Binary size will be small, and rendering will be fast.

### Q: How do we handle real-time updates?
**A**: WebSocket maintains a persistent connection. Messages arrive asynchronously and trigger UI updates via the event handler.

### Q: Can we reuse code between WASM and native?
**A**: Yes. Core protocol, client logic, and UI components are platform-agnostic. Only platform-specific code (storage, networking) differs.

### Q: What about authentication and security?
**A**: Token-based auth is handled in the WebSocket handshake. WSS (secure WebSocket) encrypts the connection. Tokens are stored securely per platform.

---

## Document History

| Date | Author | Changes |
|------|--------|---------|
| 2026-01-28 | Deano | Initial comprehensive plan created |

---

**Status**: Ready for Phase 1 Implementation

**Next Review**: After Phase 1 completion

**Maintainer**: Deano
