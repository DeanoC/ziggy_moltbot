# ZiggyStarClaw CLI TUI — Design Plan

Status: Proposed plan for work item 14 (`[zsc]`, **no-auto-merge**)

## 1) Objective

Design an interactive, keyboard-first TUI that complements the existing ZiggyStarClaw CLI command surface. The TUI must improve discoverability and operational speed while preserving CLI scriptability.

## 2) Goals and non-goals

### Goals
- Provide a fast terminal UX for daily operator tasks (chat, sessions, nodes, approvals, processes).
- Keep behavior aligned with the existing noun-verb CLI model.
- Reuse command/business logic so TUI + CLI do not drift.
- Stay cross-platform (Linux/macOS/Windows terminal) with graceful capability fallback.

### Non-goals (v1)
- Replacing the SDL/GUI client.
- Introducing TUI-only backend semantics that diverge from CLI behavior.
- Perfect feature parity with every advanced GUI workflow.
- Building a separate persistent daemon solely for TUI.

---

## 3) Framework choice

## Recommendation: **Vaxis** (Zig-native)

Use a Zig-native TUI stack (Vaxis + std lib) instead of a sidecar binary in another language.

### Why Vaxis
- Native Zig integration (`build.zig`, dependency/toolchain consistency).
- Shared types/modules with existing CLI code.
- No second runtime/distribution channel.
- Good-enough terminal primitives for pane layout, input handling, and redraw loops.

### Alternatives considered
1. **Bubble Tea (Go)**
   - Pros: mature architecture and ecosystem.
   - Cons: separate binary/runtime + duplicated protocol/action plumbing.
2. **Ratatui (Rust)**
   - Pros: polished widget ecosystem.
   - Cons: same cross-language maintenance and packaging overhead.
3. **ncurses/PDCurses via C interop**
   - Pros: battle-tested.
   - Cons: low-level API; higher complexity for modern state-driven UI.

Decision: start with **Vaxis** and keep fallback rendering conservative (focus on readability over visual effects).

---

## 4) UX model

### Layout (default)
- **Top status bar**: gateway URL, auth state, active session, active node, pending approvals count.
- **Left nav**: views list.
- **Main pane**: active view content.
- **Right context pane** (toggleable): details/help/log snippet.
- **Bottom command/input bar**: command palette and contextual key hints.

### Core navigation patterns
- `Tab` / `Shift+Tab`: cycle focus regions.
- Arrow keys or `j/k`: move selection.
- `Enter`: open/execute focused action.
- `/`: filter/search in current list.
- `:`: command palette (type CLI-like commands, execute in place).
- `g` + key: jump group (`gc` chat, `gs` sessions, `gn` nodes, `ga` approvals, `gp` processes, `gd` devices).
- `?`: global help overlay.
- `Esc`/`q`: close modal/back.
- `Ctrl+C`: exit application.

### Accessibility/usability requirements
- Fully keyboard operable.
- Always-visible focus indicator.
- High-contrast default palette.
- Non-blocking operations with explicit loading/progress/error states.

---

## 5) Key screens/views

## 5.1 Dashboard
Purpose: operational overview + jump-off actions.

Data:
- connection/auth state
- current session/node
- pending approvals
- recent command outcomes

## 5.2 Chat
Purpose: interactive operator messaging flow.

Actions:
- session picker
- compose/send message
- stream response output
- quick session switching

## 5.3 Sessions
Purpose: inspect/select session context.

Actions:
- list/search sessions
- set active/default session

## 5.4 Nodes
Purpose: node discovery and command execution.

Actions:
- list/select nodes
- show capability badges
- run quick actions (`run`, `which`, `notify`)

## 5.5 Approvals
Purpose: fast approve/deny workflow for pending actions.

Actions:
- list pending approvals
- inspect detail
- approve/deny

## 5.6 Processes
Purpose: monitor and control background node processes.

Actions:
- list processes
- spawn/poll/stop

## 5.7 Devices (pairing)
Purpose: pairing management.

Actions:
- list requests/devices
- approve/reject pairing requests

## 5.8 Canvas (advanced)
Purpose: expose node canvas operations from terminal.

Actions:
- present/hide/navigate/eval/snapshot

## 5.9 Logs/Activity
Purpose: unified execution stream for command outcomes and errors.

Actions:
- filter by severity/text
- inspect recent failures
- copy-friendly output

---

## 6) Integration with existing CLI commands

Principle: **single source of truth for behavior**.

### 6.1 Command parity map

| TUI view | Existing CLI commands |
|---|---|
| Chat | `message send <message>`, `sessions list`, `sessions use <key>` |
| Sessions | `sessions list`, `sessions use <key>` |
| Nodes | `nodes list`, `nodes use <id>`, `nodes run <command>`, `nodes which <name>`, `nodes notify <title>` |
| Processes | `nodes process list`, `nodes process spawn <command>`, `nodes process poll <processId>`, `nodes process stop <processId>` |
| Approvals | `approvals list`, `approvals approve <id>`, `approvals deny <id>` |
| Devices | `devices list`, `devices approve <requestId>`, `devices reject <requestId>` |
| Canvas | `nodes canvas present|hide|navigate|eval|snapshot` |
| Windows maintenance | `node service ...`, `node session ...`, `node runner ...`, `node profile apply ...`, `tray startup ...` |

### 6.2 Implementation strategy

1. **Phase A (fast path)**: TUI invokes existing CLI action paths and captures structured outputs where available.
2. **Phase B (shared action layer)**: move command logic into reusable `src/cli/actions/*.zig` modules consumed by both CLI parser and TUI.
3. **Phase C (event stream)**: long-running operations expose progress events/callbacks so TUI can render live status without brittle log scraping.

### 6.3 Proposed structure
- `src/main_tui.zig`
- `src/tui/app.zig`
- `src/tui/router.zig`
- `src/tui/views/*.zig`
- `src/tui/components/*.zig`
- `src/tui/commands.zig` (palette parser + command mapping)
- `src/cli/actions/*.zig` (shared command behavior)

### 6.4 Invocation
- Primary: `ziggystarclaw-cli tui`
- Optional alias: `ziggystarclaw-cli ui`

If not attached to a TTY, command should fail clearly and suggest equivalent non-interactive commands.

---

## 7) Delivery phases

## Phase 0 — bootstrap
- add TUI entrypoint + app loop shell
- static layout + global keybindings + help overlay

Exit criteria: `ziggystarclaw-cli tui` launches and exits reliably.

## Phase 1 — read-only views
- dashboard, sessions list, nodes list
- status line, error banner primitives

Exit criteria: stable navigation and data refresh without mutating actions.

## Phase 2 — core mutating workflows
- chat send
- session/node selection
- approvals approve/deny
- node `run/which/notify`

Exit criteria: daily operator flows possible end-to-end from keyboard.

## Phase 3 — advanced workflows
- processes screen
- devices pairing management
- canvas tools
- platform-gated Windows maintenance helpers

Exit criteria: broad parity for high-value CLI workflows.

## Phase 4 — shared action refactor + hardening
- migrate from command-invocation wrappers to shared action modules
- add regression and reducer tests
- improve loading/empty/error states

Exit criteria: minimal behavior drift risk between CLI and TUI.

---

## 8) Testing and verification strategy

### Automated
- reducer/update-state unit tests
- command palette parser + keymap tests
- command mapping tests (TUI action -> CLI/shared action)

### Manual smoke matrix
- Linux terminal (xterm/kitty/gnome-terminal equivalent)
- Windows Terminal (PowerShell + cmd)
- macOS Terminal/iTerm2

Minimum checks:
- launch/quit, resize handling, focus changes
- navigation across views
- chat send flow
- approvals flow
- node run/which/notify flow

---

## 9) Risks and mitigations

1. **CLI/TUI drift**
   - Mitigation: shared action layer and mapping tests.
2. **Terminal capability variance**
   - Mitigation: conservative rendering fallback; avoid hard dependency on mouse/truecolor.
3. **Scope creep from too many views**
   - Mitigation: phase gates and MVP-first acceptance criteria.
4. **Long-running command UX**
   - Mitigation: explicit progress state + cancellable operations where supported.

---

## 10) Definition of done (initial TUI milestone)

- User can complete core operator workflows from keyboard only.
- Results/errors are visible, structured, and actionable.
- TUI command is documented and discoverable from CLI help/docs.
- Smoke-tested on Linux + Windows Terminal + one macOS terminal.
- Behavior parity validated against equivalent CLI commands for in-scope actions.
