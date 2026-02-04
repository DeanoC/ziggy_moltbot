// Android node support scaffold.
//
// This file is intentionally minimal and does not depend on libc/NDK.
// The goal of the first scaffolding PR is to establish a place for
// Android-specific node runtime glue without impacting desktop builds.
//
// Future work (tracked elsewhere):
// - Decide packaging: background Service / foreground Activity / WorkManager.
// - Implement transport (likely the existing OpenClaw websocket client, or
//   a JNI/OkHttp-backed implementation).
// - Provide implementations for capabilities (screen/camera/location/notify).

const builtin = @import("builtin");

pub const AndroidNodeScaffold = struct {
    pub fn isTargetAndroid() bool {
        // Android uses the Linux OS tag with the Android ABI.
        return builtin.os.tag == .linux and builtin.abi == .android;
    }

    pub fn start() !void {
        // Placeholder for future node runtime.
        return error.NotImplemented;
    }
};
