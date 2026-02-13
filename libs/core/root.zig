pub const protocol = struct {
    pub const chat = @import("src/protocol/chat.zig");
    pub const constants = @import("src/protocol/constants.zig");
    pub const gateway = @import("src/protocol/gateway.zig");
    pub const messages = @import("src/protocol/messages.zig");
    pub const requests = @import("src/protocol/requests.zig");
};

pub const identity = @import("src/client/device_identity.zig");

pub const client = struct {
    pub const identity = @import("src/client/device_identity.zig");
};

pub const utils = struct {
    pub const logger = @import("src/utils/logger.zig");
    pub const profiler = @import("src/utils/profiler.zig");
    pub const json_helpers = @import("src/utils/json_helpers.zig");
    pub const string_utils = @import("src/utils/string_utils.zig");
    pub const secret_prompt = @import("src/utils/secret_prompt.zig");
    pub const allocator = @import("src/utils/allocator.zig");
};
