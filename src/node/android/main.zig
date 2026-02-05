// Android node runtime (connect-only skeleton).
//
// This target is **not** the Android UI client build (APK). It is a future
// OpenClaw node runtime intended to be embedded into an Android host (likely
// via JNI) and communicate with the Gateway.
//
// For now this is a compile-safe stub that exports a small API surface.
// It intentionally avoids std/posix/libc so it can cross-compile on CI without
// requiring the Android NDK.

const builtin = @import("builtin");
const runtime = @import("runtime.zig");

comptime {
    // Android uses the Linux OS tag with the Android ABI.
    if (!(builtin.os.tag == .linux and builtin.abi == .android)) {
        @compileError("src/node/android/main.zig must be built for a linux-android target");
    }
}

// -----------------------------------------------------------------------------
// Exported API (host<->android boundary)
//
// The ABI is intentionally simple: integers and pointer+length pairs.
// Keep signatures stable; this will become our Android integration surface.

pub export fn zsc_node_android_api_version() u32 {
    return runtime.ApiVersion;
}

pub export fn zsc_node_android_init() void {
    runtime.init();
}

/// Attempt to connect to the Gateway.
///
/// Parameters:
/// - url_ptr/url_len: UTF-8 bytes for ws:// or wss:// URL.
///
/// Returns: runtime.ErrorCode as u32.
pub export fn zsc_node_android_connect(url_ptr: [*]const u8, url_len: usize) u32 {
    return @intFromEnum(runtime.connect(url_ptr, url_len));
}

pub export fn zsc_node_android_disconnect() u32 {
    return @intFromEnum(runtime.disconnect());
}

pub export fn zsc_node_android_is_connected() u32 {
    return if (runtime.isConnected()) 1 else 0;
}
