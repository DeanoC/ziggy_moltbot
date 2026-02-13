# ZiggyStarClaw CLI TUI Plan

Status: Design plan (ready for staged implementation) for work item 14 (`[zsc]` no-auto-merge)

## 1) Goals and scope

### Goals
- Provide a keyboard-first terminal interface for common ZiggyStarClaw CLI workflows.
- Keep the TUI aligned with the existing noun-verb CLI command model.
- Reuse existing command/business logic wherever possible to avoid behavior drift.
- Work on Linux/macOS/Windows terminals with graceful fallback in minimal terminals.

### Non-goals (initially)
- Replacing the existing GUI app.
- Pixel-perfect UI parity with GUI features.
- Shipping a plugin architecture in v1.
- Building a separate daemon just for the TUI.

---

## 2) Framework / library selection

## Recommendation: **Vaxis** (Zig-native)

Use a Zig-native TUI stack (Vaxis + standard library primitives) rather than cross-language stacks like Bubble Tea (Go) or Ratatui (Rust).

### Why Vaxis
- Native Zig dependency model and build integration (`build.zig`), no Go/Rust sidecar binary.
- Good terminal capability coverage (colors, input, layout primitives).
- Lower maintenance overhead than embedding another runtime.
- Easier to share types and modules with existing Zig CLI code.

### Alternatives considered

1. **Bubble Tea (Go)**
   - Pros: Excellent architecture and ecosystem.
   - Cons: Requires separate Go binary/runtime boundary; duplicates protocol/command logic.

2. **Ratatui (Rust)**
   - Pros: Mature widgets and ecosystem.
   - Cons: Same cross-language integration cost, plus Rust build/tooling burden.

3. **ncurses/PDCurses (C bindings)**
   - Pros: battle-tested.
   - Cons: lower-level API, more manual state/render handling, more glue code.

### Decision summary
For ZiggyStarClaw (already Zig-heavy), **Vaxis** gives the best maintainability/velocity trade-off.

---

## 3) Proposed UX model

The TUI should have a predictable 3-pane shell and command palette.

- **Top bar**: connection/profile/session/node status
- **Left pane**: navigation (Chat, Sessions, Nodes, Approvals, Device Pairing, Processes, Canvas, Logs)
- **Main pane**: selected view content
- **Right pane (optional/toggle)**: details/context/help
- **Bottom bar**: key hints + command input

### Primary keyboard interactions
- `Tab` / `Shift+Tab`: cycle focus regions
- `j/k` or arrows: move selection
- `Enter`: open/execute
- `/`: quick search/filter in current list
- `:`: command palette (maps to noun-verb actions)
- `g` then `c/s/n/a/d/p`: jump to Chat/Sessions/Nodes/Approvals/Devices/Processes
- `?`: keymap help overlay
- `q`: back/close panel, `Ctrl+C` to exit app

### Accessibility / usability requirements
- High-contrast theme defaults.
- Full operation without mouse.
- Clear focus indicator at all times.
- Non-blocking operations with visible progress / error banners.

---

## 4) Screen/view plan

## 4.1 Home / Dashboard view
Purpose: quick operational overview and jump-off.

Shows:
- gateway URL + auth status
- default session and node
- pending approvals count
- recent command outcomes

Mockup (ASCII):

```text
┌ ZiggyStarClaw TUI ─────────────────────────────────────────────────────────────┐
│ Gateway: wss://...  Auth: OK  Session: default  Node: workstation-01         │
├───────────────┬──────────────────────────────────────────┬─────────────────────┤
│ Navigation    │ Dashboard                                │ Details             │
│ > Dashboard   │ - Pending approvals: 2                   │ Hints               │
│   Chat        │ - Nodes online: 3                        │ Enter: open item    │
│   Sessions    │ - Last command: node run "uname -a" OK  │ : palette           │
│   Nodes       │ - Last error: none                       │ ? help              │
│   Approvals   │                                          │                     │
│   Devices     │ [Open Approvals] [Open Nodes] [Open Chat]│                     │
├───────────────┴──────────────────────────────────────────┴─────────────────────┤
│ :                                                                             │
└────────────────────────────────────────────────────────────────────────────────┘
```

## 4.2 Chat view
Purpose: interactive session messaging.

Actions:
- list/select sessions
- send message
- stream/display response text
- switch target session quickly

Integration mapping:
- `chat send <message>`
- `session list`
- `session use <key>`

## 4.3 Sessions view
Purpose: manage session list/default selection.

Actions:
- list sessions
- set default session
- search/filter by key

Integration mapping:
- `session list`
- `session use <key>`

## 4.4 Nodes view
Purpose: discover nodes and run commands.

Actions:
- list/select node
- set default node
- run `system.run`
- run `system.which`
- node notify

Integration mapping:
- `node list`
- `node use <id>`
- `node run <command>`
- `node which <name>`
- `node notify <title>`

## 4.5 Process manager view
Purpose: background process lifecycle on node.

Actions:
- list processes
- spawn process
- poll process
- stop process

Integration mapping:
- `node process list`
- `node process spawn <command>`
- `node process poll <processId>`
- `node process stop <processId>`

## 4.6 Approvals view
Purpose: handle pending approvals quickly.

Actions:
- list approvals
- approve/deny selected item

Integration mapping:
- `approvals list`
- `approvals approve <id>`
- `approvals deny <id>`

## 4.7 Device pairing view (operator scope)
Purpose: approve/reject pairing requests.

Integration mapping:
- `device list` / `devices list`
- `device approve <requestId>`
- `device reject <requestId>`

## 4.8 Canvas tools view (advanced)
Purpose: terminal-accessible wrappers for canvas commands.

Integration mapping:
- `node canvas present|hide|navigate <url>|eval <js>|snapshot <path>`

## 4.9 Node profile/service/runner/tray helpers (Windows-focused)
Purpose: expose common maintenance commands in guided forms.

Integration mapping examples:
- `node profile apply --profile <client|service|session>`
- `node service <install|uninstall|start|stop|status>`
- `node runner <install|start|stop|status>`
- `tray startup <install|uninstall|start|stop|status>`

---

## 5) Integration approach with existing CLI

## Principle: **single source of truth for behavior**

Avoid re-implementing command semantics independently in the TUI.

### Phase-compatible integration strategy

1. **Initial adapter (fastest path)**
   - TUI executes existing CLI commands and captures stdout/stderr internally.
   - Reuse existing command paths immediately.
   - Similar to internal helper patterns already used for self-invocation.

2. **Shared command service (target architecture)**
   - Extract command actions into reusable Zig modules (e.g., `src/cli/actions/*.zig`).
   - Both `main_cli.zig` parser and `main_tui.zig` call the same action functions.
   - Keep output dual-mode: human text + structured result objects.

3. **Structured event pipeline for streaming operations**
   - For long-running operations, expose progress/event callbacks to TUI.
   - TUI can render live status without polling raw logs.

### Suggested code structure
- `src/main_tui.zig` (entrypoint)
- `src/tui/app.zig` (state model/update loop)
- `src/tui/views/*.zig` (view renderers)
- `src/tui/commands.zig` (command palette mapping)
- `src/cli/actions/*.zig` (shared action layer extracted from CLI)

### CLI entrypoint / invocation
- Add new command-style entrypoint:
  - `ziggystarclaw-cli tui`
- Optional legacy shortcut:
  - `ziggystarclaw-cli --tui`

---

## 6) Implementation phases

## Phase 0 — Foundation (1 PR)
- Add dependency and skeleton TUI app.
- Add `tui` command entrypoint.
- Implement app loop with static layout + key handling + quit.

Acceptance:
- `ziggystarclaw-cli tui` launches and exits cleanly.

## Phase 1 — Read-only operational views (1-2 PRs)
- Dashboard + Sessions + Nodes list (read-only).
- Command palette and keymap overlay.
- Error banner and status line.

Acceptance:
- Can inspect sessions/nodes and navigate views without crashes.

## Phase 2 — Core actions (2-3 PRs)
- Chat send, session use, node use, node run/which/notify.
- Approvals list + approve/deny.

Acceptance:
- All core actions work in TUI and match CLI behavior.

## Phase 3 — Advanced actions (2-3 PRs)
- Process manager and device pairing views.
- Canvas tools panel.
- Windows runner/service/tray forms (platform-gated).

Acceptance:
- Advanced commands are discoverable and actionable from TUI.

## Phase 4 — Shared action refactor (multi-PR)
- Move business logic into shared `cli/actions` layer.
- Replace subprocess/self-invoke calls with direct module calls where possible.

Acceptance:
- CLI and TUI use the same action functions for most commands.

## Phase 5 — Hardening and polish
- Snapshot tests for render output where practical.
- Keyboard flow tests (smoke).
- Better empty/loading/error states.
- Docs and user guide updates.

Acceptance:
- Stable UX on Linux/Windows/macOS terminals; docs updated.

---

## 7) Command parity map (v1 scope)

The following map keeps the first TUI release grounded in existing CLI capabilities.

- **Dashboard**
  - read-only status from: `session list`, `node list`, `approvals list`
  - recent outcomes sourced from in-process command history ring buffer
- **Chat**
  - send: `chat send <message>`
  - session switching: `session list`, `session use <key>`
- **Sessions**
  - list/select default session: `session list`, `session use <key>`
- **Nodes**
  - list/select default node: `node list`, `node use <id>`
  - node operations: `node run`, `node which`, `node notify`
- **Approvals**
  - list/approve/deny: `approvals list`, `approvals approve`, `approvals deny`
- **Processes**
  - list/spawn/poll/stop: `node process list|spawn|poll|stop`
- **Devices**
  - pairing flows: `device list`, `device approve`, `device reject`
- **Canvas**
  - wrappers for: `node canvas present|hide|navigate|eval|snapshot`

Out of scope for v1 (deferred until parity is stable):
- introducing TUI-only actions with no CLI equivalent
- introducing alternate semantics for existing noun-verb commands

---

## 8) Definition of done (for initial TUI release)

- A user can complete daily operator flows (chat send, session/node selection, approvals, basic node commands) entirely from keyboard.
- Core actions produce outcomes equivalent to CLI execution for the same inputs.
- Failures are visible as structured, user-facing error banners (not silent log-only failures).
- `ziggystarclaw-cli tui` is documented in user docs with keybindings and quickstart.
- Smoke-tested on Linux, Windows Terminal, and at least one macOS terminal emulator.

---

## 9) Testing strategy

- **Unit tests**
  - command palette parser and keybinding behavior
  - view state reducers/update logic
- **Integration tests**
  - command action adapters with mocked transport
  - shared action layer tests to keep CLI/TUI parity
- **Manual smoke checklist**
  - launch, resize terminal, navigation, approve/deny flow, chat send flow
  - Windows-specific runner/service/tray screen checks

---

## 10) Risks and mitigations

1. **Behavior drift between CLI and TUI**
   - Mitigation: prioritize shared action layer by Phase 4.

2. **Terminal compatibility differences**
   - Mitigation: test on default Windows Terminal + Linux/macOS terminals; keep fallback rendering simple.

3. **Complexity growth from too many views**
   - Mitigation: ship thin vertical slices, keep command palette as universal escape hatch.

4. **Long-running command UX issues**
   - Mitigation: explicit loading/progress states and cancellable operations.

---

## 11) Delivery notes

- This plan favors incremental, reviewable PR slices.
- The first usable milestone is Phase 2 (core daily workflows).
- Existing CLI remains fully usable; TUI is additive, not a breaking replacement.

---

## 12) Suggested PR slicing (no-auto-merge friendly)

To keep review scope small and reduce merge risk, split implementation into the following PR sequence:

1. **PR-A: TUI bootstrap + entrypoint**
   - Add `src/main_tui.zig` and a minimal app loop.
   - Wire `ziggystarclaw-cli tui` command entrypoint.
   - Include keymap overlay + quit flow.

2. **PR-B: Read-only views**
   - Dashboard, Sessions list, Nodes list.
   - Status line + error banner primitives.
   - No mutating actions yet.

3. **PR-C: Core mutating flows**
   - Chat send, session/node select, approvals approve/deny.
   - Basic node actions (`run`, `which`, `notify`).
   - Add parity tests for command-to-action mapping.

4. **PR-D: Advanced workflows**
   - Process manager, device pairing, canvas wrappers.
   - Windows-specific service/runner/tray helpers behind platform checks.

5. **PR-E: Shared action refactor + hardening**
   - Move remaining logic to shared `cli/actions` modules.
   - Add regression tests and update user docs.

This sequence supports manual, per-PR review while preserving a usable app at each milestone.

---

## 13) Terminal compatibility acceptance matrix

Minimum matrix before calling the initial TUI release done:

| Environment | Must-pass checks |
| --- | --- |
| Linux + default terminal (xterm/gnome-terminal/kitty equivalent) | launch, resize, focus switching, chat send, approvals flow |
| Windows Terminal (PowerShell + cmd shells) | launch, keymap behavior, node actions, process list/poll, UTF-8 rendering |
| macOS Terminal or iTerm2 | launch, navigation, command palette, error banners |

Fallback behavior requirements when capabilities are limited:
- no hard dependency on mouse support
- reduced color mode still preserves focus/selection visibility
- no ANSI artifacts when terminal lacks advanced styling support

---

## 14) Open design questions to resolve during implementation

- Should REPL and TUI share one command history store, or remain separate?
- Do we expose a compact mode for <= 100-column terminals in v1, or defer?
- For long-running operations, should cancellation map to process stop, request abort, or both?
- Should platform-specific views (service/runner/tray) be hidden entirely off-Windows, or shown as disabled with guidance?
