# Windows node service (MVP)

This repo’s “node service” on Windows is implemented as a **Windows Task Scheduler** task that keeps the node running in the background.

## Commands

All of these are available on Windows:

- `ziggystarclaw-cli node service install`
- `ziggystarclaw-cli node service uninstall`
- `ziggystarclaw-cli node service start`
- `ziggystarclaw-cli node service stop`
- `ziggystarclaw-cli node service status`

(Equivalent flag form also exists: `--node-service-install|uninstall|start|stop|status`.)

### Mode

- `--node-service-mode onstart` (default on Windows): run at boot (Task Scheduler `ONSTART`, runs as `SYSTEM`).
- `--node-service-mode onlogon`: run when the user logs on.

### Config path

- `onstart` default config path:
  - `%ProgramData%\ZiggyStarClaw\config.json`

- `onlogon` default config path:
  - `%APPDATA%\ZiggyStarClaw\config.json`

You can override with `--config <path>`.

## Logging

Node logs are written to:

- `%ProgramData%\ZiggyStarClaw\logs\node.log`

## Crash recovery

Because this is a Task Scheduler wrapper (not a Windows SCM service yet), **SCM recovery options do not apply**.

Instead, the installed wrapper script runs the node in a loop and restarts it after a short delay if it exits.

## Install notes

Creating an `onstart` task (runs as `SYSTEM`) typically requires an elevated (Administrator) shell.
If install fails with access denied, re-run the command from an elevated PowerShell.
