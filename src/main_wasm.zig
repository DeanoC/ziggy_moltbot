const std = @import("std");
const zemscripten = @import("zemscripten");
const logger = @import("utils/logger.zig");

pub const panic = zemscripten.panic;

pub const std_options = std.Options{
    .logFn = zemscripten.log,
};

export fn main() c_int {
    logger.info("MoltBot client stub (wasm) loaded.", .{});
    return 0;
}
