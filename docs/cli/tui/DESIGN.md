# ZiggyStarClaw CLI — TUI Design Plan

This document proposes a Terminal User Interface (TUI) for the ZiggyStarClaw (ZSC) CLI. The goal is to add an *optional* interactive surface that complements (not replaces) the existing scriptable CLI.

## Goals

1. **Discoverability**: make ZSC capabilities easy to find (devices, capabilities, common actions).
2. **Fast operator workflow**: connect to a gateway, select a node/device, run common actions (camera snap/clip, screen record, location), and view results.
3. **Status-at-a-glance**: connection status, active session, paired nodes, last errors.
4. **Cross-platform**: Linux/macOS first; Windows supported where feasible (ANSI + raw input).
5. **Style continuity**: reuse the existing CLI’s ANSI conventions (see `src/cli/markdown_help.zig`).

## Non-goals (v1)

- Replacing the existing non-interactive command surface.
- A full “chat UI” or rich media viewer inside the terminal (we will link/open files instead).
- Perfect feature parity with the web UI.
- Remote rendering (SSH multiplexing, web sockets to a browser, etc.).

## Users / primary use-cases

- **Operator**: connect to a gateway, see nodes, approve pairing (if enabled), run actions, and inspect results.
- **Node runner**: run node-mode and monitor connection/logs from an interactive screen.
- **Developer / support**: quickly view config, environment diagnostics, and logs.

## Framework / implementation options

ZSC is implemented in **Zig**, so the TUI should ideally be Zig-native. Below are the main options worth considering.

### Option A: Zig-native TUI library (recommended)

**Candidate**: [`vaxis`](https://github.com/rockorager/vaxis) (Zig)

- Pros:
  - Same language/toolchain as the CLI (no extra runtime or build system).
  - Good fit for a component-style UI with input/event loops.
  - Can be wired to existing ZSC client code directly.
- Cons:
  - Smaller ecosystem than Go/Rust.
  - Windows support may require additional work/validation depending on terminal/backends.

**Decision**: Start with a Zig-native library (vaxis) to keep the project cohesive and avoid shipping a second CLI binary.

### Option B: Go TUI binary (Bubble Tea / tview)

- Pros:
  - Mature ecosystem and patterns (Bubble Tea MVU; tview widgets).
  - Generally strong cross-platform terminal support.
- Cons:
  - Introduces a second language and build pipeline.
  - Requires duplicating config parsing, gateway protocol calls, or creating a local RPC bridge.
  - Packaging complexity (two artifacts, version skew).

**Use if** Zig-native options cannot meet cross-platform requirements.

### Option C: ncurses/termcap (C interop)

- Pros: stable, widely available.
- Cons: low-level ergonomics; additional FFI and platform footguns.

## Proposed CLI surface

Add a new command that launches the interactive UI:

- `ziggystarclaw-cli tui` (primary)
- Optional alias: `ziggystarclaw-cli ui`

The TUI command should accept the same connection/config inputs as existing modes:

- `--config <path>`
- `--url <url>`
- `--gateway-token <token>`
- `--node-token <token>` (when relevant)
- `--log-level <level>`

Behavior:

- If stdout is not a TTY, print an error and suggest non-interactive commands.
- Respect `NO_COLOR` / `CLICOLOR=0` for non-TUI outputs (the TUI itself will still require terminal capabilities).

## Architecture (high-level)

### Directory/module layout

- `src/tui/`
  - `app.zig` (root model + main event loop)
  - `router.zig` (screen switching)
  - `components/` (reusable UI components)
  - `screens/` (top-level screens)
  - `style.zig` (palette + styling helpers)

### Pattern

Use a **unidirectional data flow** similar to MVU:

- **Model**: application state (connection status, selected device, results, errors).
- **Messages/Events**: key presses, ticks, network updates, background task completions.
- **Update**: pure-ish reducer that updates the model and schedules effects.
- **View**: renders model → terminal widgets.

### Background work

Network and long-running actions (camera clip, screen record, downloads) should run in background tasks:

- Background task emits typed events into an in-process queue/channel.
- UI thread consumes events and updates model.

This avoids blocking input/rendering and keeps the UI responsive.

## Main screens (v1 MVP)

### 1) Home / Status

Purpose: immediate confirmation that the CLI is configured and connected.

Contents:

- Gateway URL + connection state
- Operator identity (if operator-mode enabled)
- Node identity (if node-mode enabled)
- Counts: paired nodes, pending approvals, active jobs
- Last error / warning banner

### 2) Devices

Purpose: list paired/known nodes and their advertised capabilities.

Interactions:

- Search/filter box (type-to-filter)
- Select a device → opens **Device Detail**

### 3) Device Detail + Actions

Purpose: run common actions against the selected device.

Sections:

- Device metadata (name, id, platform)
- Capabilities (camera, screen, location, canvas, etc.)
- Actions menu (only show enabled actions)

Action execution:

- Confirm prompts for destructive/expensive actions
- Progress indicator while running
- Result viewer routes to **Jobs/Results**

### 4) Approvals / Pairing

Purpose: approve or reject pending pairing requests.

- List pending approvals
- Detail panel
- Approve/Reject shortcuts

### 5) Jobs / Results

Purpose: view completed/active commands and where outputs were saved.

- Recent actions list (timestamp, device, action, status)
- Selecting a job shows:
  - exit status / error
  - stdout/stderr snippet
  - output path(s)

### 6) Logs

Purpose: tail and filter logs for quick debugging.

- Live log view with levels
- Filter by substring/level
- Copy-friendly (no forced wrapping by default)

### 7) Help

Purpose: show keybindings and optionally embedded markdown docs.

- `?` opens a modal with keybindings
- Optionally reuse `src/cli/markdown_help.zig` to render markdown help pages into a scrollable text region

## Navigation & keybindings

Consistent global keys:

- `q` / `Esc`: back / close modal (quit from Home)
- `Ctrl+C`: quit (always)
- `Tab` / `Shift+Tab`: cycle top-level screens
- `g`: Home/Status
- `d`: Devices
- `a`: Approvals
- `j`: Jobs/Results
- `l`: Logs
- `?`: Help

Screen-local:

- Arrow keys / `j`/`k`: move selection
- `Enter`: open / run selected action
- `/`: focus search/filter

All bindings should be shown in the Help modal and discoverable in-context.

## Style / color scheme

The existing CLI already uses ANSI in `src/cli/markdown_help.zig`:

- Cyan accents for list markers / labels (`\x1b[36m`)
- Yellow for fenced code blocks (`\x1b[33m`)
- Bold/underline for headings

TUI palette should align with this:

- **Accent**: cyan (selection borders, active tab)
- **Highlight**: yellow (warnings, inline code)
- **Success**: green
- **Error**: red
- **Muted**: gray/dim

Implementation notes:

- Prefer a small palette that maps cleanly to 16-color terminals.
- If 256/truecolor is available, optionally enrich backgrounds; keep a readable 16-color fallback.
- For Windows, ensure ANSI mode is enabled (similar to existing stdout handling).

## Config integration

- Read from the same unified config as the CLI.
- v1: configuration is read-only inside the TUI (display + diagnostics).
- v2+: allow edits with explicit “Save” confirmation and safe writes.

## Rollout plan (phases)

### Phase 0 (this PR)

- Document the TUI plan and expected architecture.

### Phase 1 (skeleton)

- `tui` command that starts a UI shell with:
  - Home/Status (static)
  - Help modal
  - Logs screen (basic, from existing logger sink)

### Phase 2 (devices + actions)

- Devices screen populated from gateway connection
- Device detail and a small set of actions
- Jobs/results view

### Phase 3 (approvals)

- Pairing approvals workflow
- Better error states and reconnect UX

### Phase 4 (polish + theming)

- Persisted UI preferences (last screen, filters)
- Optional theme-pack → terminal palette mapping

## Testing strategy

- **Unit tests**:
  - reducer/update functions (model + events)
  - parsing/formatting utilities (rendered labels, status badges)
- **Golden tests** (optional but recommended):
  - render a screen into an offscreen buffer and compare against a stored snapshot
- **Manual smoke tests**:
  - Linux/macOS terminals (kitty, alacritty, iTerm2)
  - Windows Terminal / PowerShell (ANSI + input)

## Definition of Done (MVP)

A first MVP is “done” when:

- `ziggystarclaw-cli tui` launches reliably on at least one POSIX platform.
- Home shows connection/config status.
- Devices list shows nodes and selecting a node exposes at least one action.
- Running an action reports progress and a result (or a clear error) in Jobs.
- Quit/back/help keybindings work and are discoverable.
