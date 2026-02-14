pub const client = struct {
    pub const state = @import("client/state.zig");
    pub const config = @import("client/config.zig");
    pub const session_keys = @import("client/session_keys.zig");
    pub const session_kind = @import("client/session_kind.zig");
    pub const update_checker = @import("client/update_checker.zig");
    pub const agent_registry = @import("client/agent_registry.zig");
};

pub const protocol = struct {
    pub const types = @import("protocol/types.zig");
};

pub const platform = struct {
    pub const sdl3 = @import("platform/sdl3.zig");
    pub const wasm_fetch = @import("platform/wasm_fetch.zig");
    pub const wasm_storage = @import("platform/wasm_storage.zig");
};

pub const utils = struct {
    pub const profiler = @import("utils/profiler.zig");
};
