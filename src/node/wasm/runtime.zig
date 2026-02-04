// Minimal WASM node runtime state machine.
//
// Connect-only skeleton (stubbed): no actual WebSocket implementation is
// included here yet. The intent is that a JS host will provide transport
// (WebSocket) and call into this module via the exported functions.
//
// Keep this file freestanding-friendly (avoid std/posix/libc).

pub const ApiVersion: u32 = 1;

pub const ErrorCode = enum(u32) {
    ok = 0,
    not_initialized = 1,
    not_implemented = 2,
    invalid_args = 3,
};

pub const State = struct {
    initialized: bool = false,
    connected: bool = false,
};

var g_state: State = .{};

pub fn init() void {
    g_state = .{ .initialized = true, .connected = false };
}

pub fn connect(url_ptr: [*]const u8, url_len: usize) ErrorCode {
    if (!g_state.initialized) return .not_initialized;
    if (url_len == 0) return .invalid_args;

    // TODO(node-wasm): call into host WebSocket API (imported from JS) and
    // drive the normal Gateway handshake + register flow.
    _ = url_ptr;

    return .not_implemented;
}

pub fn disconnect() ErrorCode {
    if (!g_state.initialized) return .not_initialized;
    // TODO(node-wasm): request close from host transport.
    g_state.connected = false;
    return .not_implemented;
}

pub fn isConnected() bool {
    return g_state.connected;
}
