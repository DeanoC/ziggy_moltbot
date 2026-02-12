const build_options = @import("build_options");

pub const supports_operator_client = build_options.cli_enable_operator;

pub const profile_label = if (supports_operator_client) "full" else "node-only";

pub const operator_disabled_hint =
    "This CLI build is node-only and cannot act as operator. Rebuild with -Dcli_operator=true.";
