const std = @import("std");

const zsc = @import("ziggystarclaw");

test "theme engine loads example theme pack directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = zsc.ui.theme_engine.ThemeEngine.init(allocator, zsc.ui.theme_engine.PlatformCaps.defaultForTarget());
    defer engine.deinit();

    try engine.loadAndApplyThemePackDir("docs/theme_engine/examples/zsc_clean");

    // Active theme should now be runtime (not the built-in compile-time defaults).
    const t = zsc.ui.theme.activeTheme();
    try std.testing.expect(t.spacing.xs > 0.0);
    try std.testing.expect(t.typography.body_size > 0.0);

    const ss = zsc.ui.theme_engine.runtime.getStyleSheet();
    try std.testing.expect(ss.button.primary.fill != null);
    if (ss.button.primary.fill) |p| {
        switch (p) {
            .solid => |c| {
                try std.testing.expectApproxEqAbs(t.colors.primary[0], c[0], 0.0001);
                try std.testing.expectApproxEqAbs(t.colors.primary[1], c[1], 0.0001);
                try std.testing.expectApproxEqAbs(t.colors.primary[2], c[2], 0.0001);
            },
            else => try std.testing.expect(false),
        }
    }
}

test "theme engine loads showcase theme pack directory (partial overrides + per-mode stylesheet)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = zsc.ui.theme_engine.ThemeEngine.init(allocator, zsc.ui.theme_engine.PlatformCaps.defaultForTarget());
    defer engine.deinit();

    try engine.loadAndApplyThemePackDir("docs/theme_engine/examples/zsc_showcase");

    // Ensure StyleSheet resolves differently across modes (panel.fill references colors.surface).
    zsc.ui.theme.setMode(.light);
    const ss_light = zsc.ui.theme_engine.runtime.getStyleSheet();
    zsc.ui.theme.setMode(.dark);
    const ss_dark = zsc.ui.theme_engine.runtime.getStyleSheet();

    try std.testing.expect(ss_light.panel.fill != null);
    try std.testing.expect(ss_dark.panel.fill != null);
    const a = ss_light.panel.fill.?;
    const b = ss_dark.panel.fill.?;
    switch (a) {
        .gradient4 => |ga| {
            switch (b) {
                .gradient4 => |gb| {
                    // Light vs dark token overrides should yield different resolved colors.
                    try std.testing.expect(@abs(ga.tl[0] - gb.tl[0]) > 0.02 or @abs(ga.tr[0] - gb.tr[0]) > 0.02);
                },
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }

    // Ensure focus ring config is present.
    try std.testing.expect(ss_dark.focus_ring.thickness != null);
    try std.testing.expect(ss_dark.focus_ring.color != null);
    try std.testing.expect(ss_dark.focus_ring.glow.color != null);

    // Ensure 9-slice panel frame config is present.
    try std.testing.expect(ss_dark.panel.frame_image.isSet());
    try std.testing.expect(ss_dark.panel.frame_slices_px != null);
    try std.testing.expect(ss_dark.panel.shadow.color != null);
}
