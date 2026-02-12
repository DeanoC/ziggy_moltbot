const std = @import("std");
const panel_manager = @import("panel_manager.zig");
const workspace = @import("workspace.zig");

pub const TransferResult = struct {
    moved_ok: bool = true,
    moved_count: usize = 0,
};

pub fn transferPanelsToWorkspace(
    allocator: std.mem.Allocator,
    src_manager: *panel_manager.PanelManager,
    panel_ids: []const workspace.PanelId,
    dst_ws: *workspace.Workspace,
) TransferResult {
    var out = TransferResult{};
    for (panel_ids) |pid| {
        const taken = src_manager.takePanel(pid) orelse continue;
        if (dst_ws.panels.append(allocator, taken)) |_| {
            out.moved_count += 1;
        } else |_| {
            _ = src_manager.putPanel(taken) catch {
                var tmp = taken;
                tmp.deinit(src_manager.allocator);
            };
            out.moved_ok = false;
            break;
        }
    }
    return out;
}

pub fn restorePanelsFromWorkspace(
    src_manager: *panel_manager.PanelManager,
    src_ws: *workspace.Workspace,
) void {
    while (src_ws.panels.pop()) |p| {
        _ = src_manager.putPanel(p) catch {
            var tmp = p;
            tmp.deinit(src_manager.allocator);
        };
    }
}
