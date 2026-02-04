// WASM node runtime (connect-only skeleton).
//
// This target is intentionally *not* the browser UI client (see `-Dwasm=true`).
// It is a future node runtime intended to run in a JS host environment
// (e.g. WebWorker) and communicate with the Gateway via host-provided
// networking primitives.
//
// For now this is a compile+link-safe stub that exports a small API surface.

const builtin = @import("builtin");
const runtime = @import("runtime.zig");

comptime {
    if (builtin.cpu.arch != .wasm32) {
        @compileError("src/node/wasm/main.zig must be built for wasm32");
    }
}

// -----------------------------------------------------------------------------
// Exported API (host<->wasm boundary)
//
// The ABI is intentionally simple: integers and pointer+length pairs.
// Keep signatures stable; this will become our host integration surface.

pub export fn zsc_node_wasm_api_version() u32 {
    return runtime.ApiVersion;
}

pub export fn zsc_node_wasm_init() void {
    runtime.init();
}

/// Attempt to connect to the Gateway.
///
/// Parameters:
/// - url_ptr/url_len: UTF-8 bytes for ws:// or wss:// URL.
///
/// Returns: runtime.ErrorCode as u32.
pub export fn zsc_node_wasm_connect(url_ptr: [*]const u8, url_len: usize) u32 {
    return @intFromEnum(runtime.connect(url_ptr, url_len));
}

pub export fn zsc_node_wasm_disconnect() u32 {
    return @intFromEnum(runtime.disconnect());
}

pub export fn zsc_node_wasm_is_connected() u32 {
    return if (runtime.isConnected()) 1 else 0;
}
