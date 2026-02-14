const ziggy = @import("ziggy-core");
const zui = @import("ziggy-ui");

pub const protocol = struct {
    pub const types = zui.protocol.types;
    pub const messages = ziggy.protocol.messages;
    pub const constants = ziggy.protocol.constants;
    pub const gateway = ziggy.protocol.gateway;
    pub const requests = ziggy.protocol.requests;
    pub const sessions = @import("protocol/sessions.zig");
    pub const chat = ziggy.protocol.chat;
    pub const nodes = @import("protocol/nodes.zig");
    pub const ws_auth_pairing = @import("protocol/ws_auth_pairing.zig");
};

pub const client = struct {
    pub const state = zui.client.state;
    pub const config = zui.client.config;
    pub const event_handler = @import("client/event_handler.zig");
    pub const device_identity = ziggy.identity;
    pub const update_checker = zui.client.update_checker;
};

pub const transport = struct {
    pub const ws = @import("client/websocket_client.zig");
    pub const websocket = ws;
    pub const WebSocketClient = ws.WebSocketClient;
};

pub const websocket = transport.websocket;
pub const WebSocketClient = transport.WebSocketClient;

pub const ui = struct {
    pub const main_window = zui.ui.main_window;
    pub const chat_view = zui.ui.chat_view;
    pub const input_panel = zui.ui.input_panel;
    pub const settings_view = zui.ui.settings_view;
    pub const status_bar = zui.ui.status_bar;
    pub const draw_context = zui.ui.draw_context;
    pub const theme = zui.ui.theme;
    pub const theme_engine = zui.ui.theme_engine.theme_engine;
    pub const text_buffer = zui.ui.text_buffer;
    pub const data_uri = zui.ui.data_uri;
    pub const image_cache = zui.ui.image_cache;
    pub const workspace = zui.ui.workspace;
    pub const panel_manager = zui.ui.panel_manager;
    pub const dock_transfer = zui.ui.dock_transfer;
    pub const ui_command = zui.ui.ui_command;
    pub const ui_command_inbox = zui.ui.ui_command_inbox;
    pub const workspace_store = zui.ui.workspace_store;
    pub const components = zui.ui.components;
    pub const widgets = zui.ui.widgets;
    pub const layout = struct {
        pub const custom_layout = zui.ui.layout.custom_layout;
        pub const dock_graph = zui.ui.layout.dock_graph;
        pub const dock_drop = zui.ui.layout.dock_drop;
        pub const dock_detach = zui.ui.layout.dock_detach;
        pub const dock_rail = zui.ui.layout.dock_rail;
    };
};

pub const platform = struct {
    pub const wasm = @import("platform/wasm.zig");
    pub const native = @import("platform/native.zig");
    pub const storage = @import("platform/storage.zig");
    pub const network = @import("platform/network.zig");
};

pub const utils = struct {
    pub const allocator = ziggy.utils.allocator;
    pub const logger = ziggy.utils.logger;
    pub const profiler = zui.bridge_utils.profiler;
    pub const json_helpers = ziggy.utils.json_helpers;
    pub const string_utils = ziggy.utils.string_utils;
    pub const secret_prompt = ziggy.utils.secret_prompt;
};

pub const node = struct {
    pub const node_context = @import("node/node_context.zig");
    pub const command_router = @import("node/command_router.zig");
};

pub const windows = struct {
    pub const camera = @import("windows/camera.zig");
    pub const screen = @import("windows/screen.zig");
};

pub const unified_config = @import("unified_config.zig");
