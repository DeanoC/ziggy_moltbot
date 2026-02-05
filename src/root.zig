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
    pub const update_checker = @import("client/update_checker.zig");
};

pub const transport = struct {
    pub const ws = @import("client/websocket_client.zig");
    pub const websocket = ws;
    pub const WebSocketClient = ws.WebSocketClient;
};

pub const websocket = transport.websocket;
pub const WebSocketClient = transport.WebSocketClient;

pub const ui = struct {
    const ui_build = @import("ui/ui_build.zig");
    pub const imgui_bridge = if (ui_build.use_imgui) @import("ui/imgui_bridge.zig") else struct {};
    pub const main_window = @import("ui/main_window.zig");
    pub const chat_view = @import("ui/chat_view.zig");
    pub const input_panel = @import("ui/input_panel.zig");
    pub const settings_view = @import("ui/settings_view.zig");
    pub const status_bar = @import("ui/status_bar.zig");
    pub const theme = @import("ui/theme.zig");
    pub const text_buffer = @import("ui/text_buffer.zig");
    pub const data_uri = @import("ui/data_uri.zig");
    pub const image_cache = @import("ui/image_cache.zig");
    pub const workspace = @import("ui/workspace.zig");
    pub const panel_manager = @import("ui/panel_manager.zig");
    pub const ui_command = @import("ui/ui_command.zig");
    pub const ui_command_inbox = @import("ui/ui_command_inbox.zig");
    pub const workspace_store = @import("ui/workspace_store.zig");
    pub const components = @import("ui/components/components.zig");
    pub const widgets = @import("ui/widgets/widgets.zig");
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
