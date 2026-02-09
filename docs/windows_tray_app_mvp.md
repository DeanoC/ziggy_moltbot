# Windows tray app MVP (ziggystarclaw-tray)

This is a minimal Windows 10/11 tray icon app that controls the ZiggyStarClaw **node scheduled task** ("service"):

- Show current node service status (Running / Stopped / Not installed)
- Start / Stop / Restart
- Open logs (best-effort: opens Explorer with the log selected)

> It is intentionally small and uses the existing `ziggystarclaw-cli node service ...` helpers where available.

---

## Where it shows up

When `ziggystarclaw-tray.exe` is running, you should see a ZiggyStarClaw icon in the Windows notification area.

If you don’t see it, check the hidden icons (the ^ tray overflow).

---

## Requirements

The tray app controls the default scheduled task created by:

```
ziggystarclaw-cli node service install
```

The default task name is:

- `ZiggyStarClaw Node`

---

## Logs

The tray app tries to open the first existing log file from these common locations:

- `%APPDATA%\ZiggyStarClaw\node-service.log` (written by `ziggystarclaw-cli node service install`)
- `%APPDATA%\ZiggyStarClaw\logs\node.log` (future)
- `%LOCALAPPDATA%\ZiggyStarClaw\logs\node.log` (future)

The tray app’s own troubleshooting log is:

- `%APPDATA%\ZiggyStarClaw\tray.log`

---

## Troubleshooting

- **Status: Not installed**
  - Run: `ziggystarclaw-cli node service install`

- **Start/Stop fails with Access Denied**
  - Try running the installer / CLI from an elevated (Administrator) PowerShell.
  - Some task configurations may require higher privileges to control.

- **Open Logs does nothing**
  - The log file may not exist yet (service never started).
  - Use **Open Config Folder** from the tray menu and look for `node-service.log`.

---

## Minimal manual verification (developer)

1. Install the service:
   - `ziggystarclaw-cli node service install`
2. Run `ziggystarclaw-tray.exe`
3. Right-click tray icon:
   - Verify menu shows a **Status** line
   - Click **Start Node** → verify status becomes Running
   - Click **Stop Node** → verify status becomes Stopped
   - Click **Restart Node** → verify it stops then starts
   - Click **Open Logs** → Explorer opens (or config folder opens)
4. Exit tray app via **Exit**.
