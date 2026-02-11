const cli = @import("src/main_cli.zig");

pub fn main() !void {
    try cli.main();
}
