pub const protocol = struct {
    pub const types = @import("protocol/types.zig");
    pub const messages = @import("protocol/messages.zig");
    pub const constants = @import("protocol/constants.zig");
    pub const gateway = @import("protocol/gateway.zig");
    pub const requests = @import("protocol/requests.zig");
    pub const sessions = @import("protocol/sessions.zig");
    pub const chat = @import("protocol/chat.zig");
};

pub const client = struct {
    pub const state = @import("client/state.zig");
    pub const config = @import("client/config.zig");
    pub const event_handler = @import("client/event_handler.zig");
    pub const device_identity = @import("client/device_identity.zig");
};

pub const transport = struct {
    pub const websocket = @import("client/websocket_client.zig");
    pub const WebSocketClient = websocket.WebSocketClient;
};

pub const websocket = transport.websocket;
pub const WebSocketClient = transport.WebSocketClient;

pub const ui = struct {
    pub const imgui_wrapper = @import("ui/imgui_wrapper.zig");
    pub const main_window = @import("ui/main_window.zig");
    pub const chat_view = @import("ui/chat_view.zig");
    pub const input_panel = @import("ui/input_panel.zig");
    pub const settings_view = @import("ui/settings_view.zig");
    pub const status_bar = @import("ui/status_bar.zig");
    pub const theme = @import("ui/theme.zig");
};

pub const platform = struct {
    pub const wasm = @import("platform/wasm.zig");
    pub const native = @import("platform/native.zig");
    pub const storage = @import("platform/storage.zig");
    pub const network = @import("platform/network.zig");
};

pub const utils = struct {
    pub const allocator = @import("utils/allocator.zig");
    pub const logger = @import("utils/logger.zig");
    pub const json_helpers = @import("utils/json_helpers.zig");
    pub const string_utils = @import("utils/string_utils.zig");
};
