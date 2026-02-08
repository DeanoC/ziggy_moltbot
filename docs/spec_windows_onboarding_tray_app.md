# Spec: Windows onboarding + tray app (MVP)

Goal: after MSIX install, user launches ZiggyStarClaw and can set up a full node (camera/screen/browser) with minimal friction.

---

## Why tray app (not service)

Full node capabilities require interactive user session permissions (camera/screen capture/browser). A tray app:
- starts on logon
- can show prompts / status
- can open logs and guide pairing

---

## MVP UI requirements

1. **Connection settings screen**
   - Gateway WS URL (ws/wss/http/https)
   - Token (optional when using Tailscale Serve + gateway auth via injected headers)
   - “Test connect” button

2. **Pair / Register node**
   - Button: “Register as Node”
   - Shows device id that needs approval
   - Status: pending/approved/rejected

3. **Run node in background**
   - Start/Stop/Restart node
   - Show last heartbeat time + connected/disconnected
   - Link/button: “Open logs”

4. **Capability smoke tests**
   - Camera: take snapshot
   - Screen: start short recording
   - Browser/Canvas: open a URL (uses canvas.navigate when implemented)

---

## Technical approach (recommended)

- Keep `ziggystarclaw-client.exe` as the UI/tray process.
- Spawn a child process for node-mode:
  - Prefer a dedicated `ziggystarclaw-node.exe` built as Windows subsystem (no console).
  - Fallback: spawn CLI with Windows no-window flags.

- Ensure stdout/stderr from node process is captured to a log file.

---

## Config + log locations

Prefer per-user local storage:
- Config: `%LOCALAPPDATA%\ZiggyStarClaw\config.json`
- Logs: `%LOCALAPPDATA%\ZiggyStarClaw\logs\node.log`

Add migration:
- If `%APPDATA%\ZiggyStarClaw\config.json` exists and local doesn’t, offer to import.

---

## Open questions

- Do we keep a single unified config or split UI settings vs node settings?
- How do we handle multiple gateways/profiles?

---

## Acceptance criteria

- Fresh Windows user installs MSIX.
- Launch → onboarding wizard appears.
- User enters gateway URL (+ token if needed).
- User can complete node-register and node appears in gateway.
- Tray app shows “Connected” and node keeps running in background after closing main window.
