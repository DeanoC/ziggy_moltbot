// WASM node support scaffold.
//
// NOTE: ZiggyStarClaw already has a WASM *client* build (UI running in the
// browser via Emscripten). This scaffold is for a future WASM *node* runtime
// (capability provider) which likely runs in a WebWorker and communicates
// with the Gateway via WebSocket.
//
// This file is intentionally freestanding-friendly and avoids std/posix.

const builtin = @import("builtin");

pub const WasmNodeScaffold = struct {
    pub fn isTargetWasm() bool {
        return builtin.cpu.arch == .wasm32;
    }

    pub fn start() !void {
        // Placeholder for future node runtime.
        return error.NotImplemented;
    }
};
