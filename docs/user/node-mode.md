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

## Docker sandbox (Linux host)

For a disposable, isolated build + run that can still connect to a local OpenClaw gateway, use the Docker sandbox. It is Linux-host focused (e.g., wizball) and requires `--network=host` (the script sets this).

Basic usage (repo mounted read-only by default):

```bash
scripts/dev/node_sandbox.sh -- --config /repo/config/dev.json --auto-approve-pairing
```

Allow write access (writes `zig-out/` + `.zig-cache/` in the repo):

```bash
scripts/dev/node_sandbox.sh --rw -- --config /repo/config/dev.json
```

Use your host config by mounting it into the container:

```bash
NODE_SANDBOX_DOCKER_ARGS="-v $HOME/.config/ziggystarclaw:/config:ro" \
  scripts/dev/node_sandbox.sh -- --config /config/config.json
```

## Pairing (node-mode)

If the gateway requires device pairing, node-mode can handle it in one of three ways:

1) Auto-approve (when allowed by gateway policy):

```bash
ziggystarclaw-cli --node-mode --auto-approve-pairing
```

2) Interactive prompt: run node-mode in a terminal and confirm the prompt when a pairing request arrives.

3) Operator CLI approval:

```bash
ziggystarclaw-cli --operator-mode --pair-list
ziggystarclaw-cli --operator-mode --pair-approve <requestId>
```

The pairing prompt respects `--pairing-timeout <sec>` (default: 120). If no response arrives before the timeout, the pending request is cleared and late input is ignored.

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
- `--config <path>`: config.json path (default: `~/.config/ziggystarclaw/config.json` on Linux/macOS, `%APPDATA%\ZiggyStarClaw\config.json` on Windows)
- `node.healthReporterIntervalMs` (config): heartbeat interval in ms (default: 10000). If too high, the gateway may mark the node stale.
- `--as-node / --no-node`: enable/disable node connection
- `--as-operator / --no-operator`: enable/disable operator connection
- `--log-level <level>`: debug|info|warn|error

## Auth notes
- WebSocket Authorization and `connect.auth.token` use `gateway.authToken` (they must match).
- `node.nodeToken` (device token) is used in the device-auth signed payload, and is persisted back to config when the gateway issues/rotates it in `hello-ok`.
- `gateway.authToken` is still used for operator-mode and can be used as a fallback for legacy node configs.

## Security notes
- Keep allowlists tight; prefer scripts over arbitrary shells.
- Use TLS when exposing gateways beyond localhost.
- Treat `gateway.authToken` as a secret.

## Manual test plan

1) Run node-mode without pairing approval:

```bash
ziggystarclaw-cli --node-mode --pairing-timeout 5
```

Verify it logs a pairing request and times out after 5 seconds.

2) Run node-mode with auto-approve:

```bash
ziggystarclaw-cli --node-mode --auto-approve-pairing
```

Verify it auto-approves, reconnects, and logs `hello-ok` with token persistence.
