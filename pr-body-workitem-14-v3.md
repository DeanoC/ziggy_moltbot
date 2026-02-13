## Summary
Refines the CLI TUI design document for work item 14 with a clearer implementation plan tied directly to the current noun-verb CLI command surface.

## What changed
- Reworked `docs/cli/tui/DESIGN.md` into a structured plan with:
  - Explicit goals / non-goals for v1
  - Framework decision (Vaxis) and alternatives
  - Concrete screen/view set and navigation model
  - Command parity map from TUI views to existing CLI commands
  - Integration strategy (adapter -> shared action layer -> event stream)
  - Delivery phases, testing strategy, and DoD

## Audit trail
- Read global backlog context from `../docs/WORK_ITEMS_GLOBAL.md` (item 14, no-auto-merge).
- Updated only `docs/cli/tui/DESIGN.md` to keep scope focused on design.
- Verified branch is up-to-date with `origin/main` before opening PR.

## Manual verification plan
1. Open `docs/cli/tui/DESIGN.md` and verify the sections cover:
   - framework choice,
   - key screens/views,
   - navigation patterns,
   - integration with existing CLI commands.
2. Confirm command parity map uses current command names from `docs/cli/01-overview.md`.
3. Confirm phased rollout is incremental and compatible with no-auto-merge review flow.

## Build/test results
- ✅ `./.tools/zig-0.15.2/zig build`
- ✅ `./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu`
- ✅ `source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig build -Dwasm=true`
- ❌ `./.tools/zig-0.15.2/zig build -Dandroid=true` (local env missing `JDK_HOME` / `ANDROID_HOME`)
- ✅ `./.tools/zig-0.15.2/zig build test`
