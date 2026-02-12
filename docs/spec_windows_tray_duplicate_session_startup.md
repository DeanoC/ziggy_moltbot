# Spec: Windows tray startup duplicate-session guard

## Summary

On Windows logon/startup, ZiggyStarClaw can be launched from more than one startup path:

- SCM service (`ZiggyStarClaw Node`)
- user-session runner (`ziggystarclaw-cli node supervise ...` from Scheduled Task)
- tray app startup task (`ZiggyStarClaw Tray`)

This spec defines the guardrails that prevent duplicate **node-owner** sessions from starting concurrently.

## Problem

A startup race can occur when two startup paths overlap (e.g. service + user-session runner, or duplicate runner invocations). Without a shared ownership guard, two node sessions may start and compete for resources.

## Goals

1. Prevent two concurrent node-owner sessions during login/startup races.
2. Enforce single-instance ownership with deterministic lock semantics.
3. Ensure ownership handoff is explicit on process exit.
4. Emit diagnostics when a second instance is blocked.

## Non-goals

- Selecting runner mode (service vs session) at install-time.
- Replacing existing tray controls or startup task UX.

## Required behavior

### 1) Shared node ownership mutex (service + runner)

Both SCM-hosted node mode and user-session supervisor must acquire the same cross-mode mutex before owning node execution:

- Global lock name: `Global\\ZiggyStarClaw.NodeOwner`
- Local fallback: `Local\\ZiggyStarClaw.NodeOwner`

If lock acquisition reports already-existing owner, startup must be blocked (no second node session spawned).

### 2) Clear handoff semantics

- Lock handle must remain open for the lifetime of the owning process.
- On process exit, owner releases the handle.
- Release path logs an ownership-release diagnostic.

### 3) Diagnostics

On service, runner, and tray paths, diagnostics must include:

- lock acquired
- second instance blocked
- lock scope fallback (`Local\\...`) when used
- owner release

Expected tokens:

- `single_instance_acquired`
- `single_instance_denied_existing_owner`
- `single_instance_scope_local`
- `single_instance_owner_released`

Runner path should also emit a stderr hint when blocked by an existing owner.

## Implementation notes

- Lock helper is centralized in `src/windows/single_instance.zig`.
- Service guard is enforced in `src/windows/scm_host.zig`.
- User-session supervisor guard is enforced in `src/main_cli.zig` (`node supervise`).
- Tray process keeps its own tray-singleton guard and diagnostics in `src/main_tray.zig`.

## Validation

1. Start one node owner (service or runner); attempt to start the other.
   - Second startup is blocked.
   - Diagnostics include `single_instance_denied_existing_owner`.
2. Stop owner and start alternate mode.
   - New mode acquires lock and starts successfully.
   - Previous owner logs release token.
3. Confirm tray duplicate launch is blocked and logged.
