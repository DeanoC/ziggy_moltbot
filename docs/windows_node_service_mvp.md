# Windows node service

On Windows, ZiggyStarClaw’s “node service” is implemented as a **real Windows Service Control Manager (SCM) service**.

This replaces the earlier Task Scheduler wrapper approach.

## Commands

All of these are available on Windows:

- `ziggystarclaw-cli node service install`
- `ziggystarclaw-cli node service uninstall`
- `ziggystarclaw-cli node service start`
- `ziggystarclaw-cli node service stop`
- `ziggystarclaw-cli node service status`

Legacy `--node-service-*` action flags are still accepted for compatibility, but deprecated in favor of `node service <action>`.

### Mode

- `--node-service-mode onstart` (default on Windows):
  - Installs an **Auto Start** SCM service (runs as `LocalSystem`)
  - Starts at boot

- `--node-service-mode onlogon`:
  - Installs a **Manual Start** SCM service
  - Intended for user-controlled start (e.g. tray app at logon)

> Note: both modes run the service as `LocalSystem` (Session 0). Some interactive capabilities (camera/screen capture) may not work from a service.

### Service name

Default service name:

- `ZiggyStarClaw Node`

Override with:

- `--node-service-name "My Service Name"`

## Config path

You can override with `--config <path>`.

Defaults:

- `onstart` default config path:
  - `%ProgramData%\ZiggyStarClaw\config.json`

- `onlogon` default config path:
  - `%APPDATA%\ZiggyStarClaw\config.json`

## Logging

Logs are written next to the config file:

- `<config dir>\logs\node.log`

Common defaults:

- System (onstart): `%ProgramData%\ZiggyStarClaw\logs\node.log`
- User (onlogon): `%APPDATA%\ZiggyStarClaw\logs\node.log`

The Windows tray app also writes its own troubleshooting log:

- `%APPDATA%\ZiggyStarClaw\tray.log`

## Crash recovery (SCM)

The installer configures SCM recovery actions:

- restart the service automatically on failure

You can inspect/change recovery in:

- Services → **ZiggyStarClaw Node** → Properties → **Recovery**

Or via PowerShell / `sc.exe` (advanced).

## Permissions (tray control without admin)

During install, the service’s security descriptor is set to allow **Authenticated Users** to query/start/stop the service.

This allows `ziggystarclaw-tray.exe` to control the node without requiring elevation.

## Install notes

Creating or modifying an SCM service typically requires an elevated (Administrator) shell.

If install fails with access denied, re-run from an elevated PowerShell.
