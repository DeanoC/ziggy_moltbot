/// Debug visibility tiers for ZiggyStarClaw UI.
///
/// Spec: docs/spec_zsc_debug_visibility_and_activity_stream.md
pub const DebugVisibilityTier = enum(u8) {
    normal,
    dev,
    deep_debug,

    pub fn label(self: DebugVisibilityTier) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .dev => "Dev",
            .deep_debug => "Deep debug",
        };
    }
};

/// Global UI setting (not yet persisted).
pub var current_tier: DebugVisibilityTier = .normal;

pub fn showToolOutput(tier: DebugVisibilityTier) bool {
    return tier == .deep_debug;
}

pub fn showInlineDebugMeta(tier: DebugVisibilityTier) bool {
    return tier == .deep_debug;
}

pub fn cycle(tier: DebugVisibilityTier) DebugVisibilityTier {
    return switch (tier) {
        .normal => .dev,
        .dev => .deep_debug,
        .deep_debug => .normal,
    };
}
