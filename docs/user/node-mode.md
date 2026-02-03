# Node mode (advanced)

Node mode runs a capability node that connects to an OpenClaw gateway and can execute **allowlisted** commands (and other capabilities like notifications/canvas).

## Quick start (Windows)

1) Ensure you have a unified config file:

- `%APPDATA%\ZiggyStarClaw\config.json`

2) Register/pair the device identity (one-time):

```powershell
.\ziggystarclaw-cli.exe --node-register --wait-for-approval
```

3) Run node mode:

```powershell
$cfg = Join-Path $env:APPDATA 'ZiggyStarClaw\config.json'
.\ziggystarclaw-cli.exe --node-mode --config $cfg --as-node --no-operator
```

## Quick start (Linux/macOS)

```bash
ziggystarclaw-cli --node-mode --config ~/.config/ziggystarclaw/config.json
```

## Exec approvals (allowlist)

By default, the node runs in **allowlist** mode for `system.run`.

The gateway will refuse to invoke commands that are not allowlisted.

### Recommended starter allowlist (Windows)

This matches the current behavior of the companion apps (pragmatic but not wide open):

```json
{
  "mode": "allowlist",
  "allowlist": [
    "whoami",
    "cmd **",
    "where **",
    "powershell **",
    "pwsh **"
  ],
  "ask_patterns": []
}
```

Notes:
- Patterns are matched against the **full command string** (args joined with spaces).
- `**` means "match anything" (glob-style).
- For tighter security, replace `cmd **` / `powershell **` with specific scripts or exact commands.

### Updating approvals from the gateway

You can update approvals via OpenClaw:

```bash
openclaw nodes invoke --node <id> --command system.execApprovals.set \
  --params '{"mode":"allowlist","allowlist":["whoami","cmd **","where **","powershell **","pwsh **"],"ask_patterns":[]}'
```

## Windows "always-on" node (Task Scheduler)

Install the scheduled task (will ensure node-register first, using the same config file):

```powershell
.\ziggystarclaw-cli.exe --node-service-install
```

Useful commands:

```powershell
.\ziggystarclaw-cli.exe --node-service-status
.\ziggystarclaw-cli.exe --node-service-start
.\ziggystarclaw-cli.exe --node-service-stop
.\ziggystarclaw-cli.exe --node-service-uninstall
```

Logs:

```powershell
Get-Content (Join-Path $env:APPDATA 'ZiggyStarClaw\node-service.log') -Tail 200
```

## Common options
- `--config <path>`: config.json path (default: `%APPDATA%\ZiggyStarClaw\config.json` on Windows)
- `--as-node / --no-node`: enable/disable node connection
- `--as-operator / --no-operator`: enable/disable operator connection
- `--log-level <level>`: debug|info|warn|error

## Security notes
- Keep allowlists tight; prefer scripts over arbitrary shells.
- Use TLS when exposing gateways beyond localhost.
- Treat `gateway.authToken` as a secret.
