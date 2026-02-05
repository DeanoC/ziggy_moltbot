const builtin = @import("builtin");

pub const use_imgui = builtin.abi.isAndroid() or builtin.os.tag == .emscripten;
