# ZiggyStarClaw Spec: Debug Visibility Tiers + Activity Stream (Noise Control)

## Goal
Make the default UI feel like a normal chat app (clean, stable), while still supporting deep debugging when needed.

This spec is specifically about hiding **tool/process noise** (e.g. `process:list`, `process:log`, tool call IDs, streaming test logs) from the main chat timeline, and providing deliberate places/modes to inspect it.

## Non-goals
- Redesigning the transport/protocol.
- Removing the ability to inspect raw tool I/O.
- Changing OpenClaw behavior (this is a client/UI spec).

## Terminology
- **Chat timeline**: the canonical conversation bubbles (user/assistant).
- **Activity stream**: background operational events (tool runs, process state, approvals, system events).
- **Visibility tier**: the amount of activity shown inline vs in side panels.

## Requirements

### R1. Three visibility tiers (user-selectable)
1) **Normal (default)**
- Show only user/assistant messages.
- Show only *actionable* interrupts as non-chat toasts/badges (e.g. “Approval needed”).

2) **Dev**
- Normal + warnings/errors summaries.
- Show a 1-line “tool used” row *only when it explains a user-visible outcome*.
- No streaming logs in the timeline.

3) **Deep debug**
- Dev + full raw tool I/O, tool call IDs, session/fork/compaction details.
- Allows expanding streaming output/logs.

### R2. Separate streams (don’t interleave by default)
- Chat timeline must not be polluted by tool chatter.
- Activity stream lives in a sidebar/tab with filters.

Suggested tabs:
- **Activity** (tools/processes/runs)
- **Approvals** (pending/approved/denied)
- **System** (session forks/resets, compaction, routing)

### R3. Actionable interruptions
Normal mode may show:
- Approval required (pending) with a badge count.
- Tool run failed **if it affects the user-requested action** (e.g., build failed).

Delivery mechanisms:
- Toast + badge in header
- Optional “Open details” button that jumps to Activity/Approvals tab

### R4. Noise suppression and aggregation
In Activity stream:
- Repeated updates for the same run should be aggregated into a single card:
  - Example: `process:poll` updates should update the card, not append new rows.
- “Still running” updates should not emit more than once per N seconds.
- Long stdout/stderr should be truncated with “show more”, with explicit byte/line limits.

### R5. Stable mapping from gateway events → UI objects
Represent activity items with stable keys:
- `runId` / `toolCallId` / `process.sessionId` should map to a single UI card.
- Dedup logic: same key updates in-place.

### R6. Filters
Activity stream filter dimensions:
- Severity: debug/info/warn/error
- Source: tool/process/approval/system
- Scope: current conversation vs background/cron

### R7. Defaults
- Default tier: **Normal**
- Default open panel: none
- Default filter: show warn/error/actionable

## UX Sketch

### Header
- “Approvals” badge (count)
- “Activity” badge (warn/error count)
- Visibility tier dropdown: Normal / Dev / Deep debug

### Timeline
- Only canonical conversation.
- Optionally, a small inline *pill* for “Approval required” that opens Approvals.

### Activity cards
- Card title: `tool=exec` / `tool=process` / `cron job` etc.
- Status: running/succeeded/failed
- Expandable details:
  - parameters (sanitized)
  - stdout/stderr preview
  - timestamps

## Implementation notes
- Keep the raw event log in memory (or persisted) regardless of tier; tier only changes presentation.
- Add a “Copy raw event JSON” action in Deep debug.
- Consider storing activity state separately from message list state to avoid virtualization bugs impacting chat.

## Acceptance criteria
- In Normal mode, background builds/tests do not spam the chat timeline.
- A build failure produces 1 actionable notification; details live in Activity.
- Approvals never appear as tool spam in chat; they appear as a badge + Approvals screen.
- Switching tiers does not lose events.
