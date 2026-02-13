# ZiggyStarClaw CLI

## Usage

```text
ziggystarclaw <noun> <verb> [args] [options]
ziggystarclaw --help

# Backward-compatible binary name:
ziggystarclaw-cli <noun> <verb> [args] [options]
```

## Preferred command style (OpenClaw-style noun verb)

- `message send <message>` (aliases: `chat`, `messages`)
- `session list|use <key>` (alias: `sessions`)
- `node list|use <id>|run <command>|which <name>|notify <title>` (alias: `nodes`)
- `node process list|spawn <command>|poll <processId>|stop <processId>`
- `node canvas present|hide|navigate <url>|eval <js>|snapshot <path>`
- `node approvals get|allow <command>|allow-file <path>`
- `approval pending|list|approve <id>|deny <id>` (alias: `approvals`)
- `device pending|list|approve <requestId>|reject <requestId>` (alias: `devices`)
- `node service ...`
- `node session ...`
- `node runner ...`
- `node profile apply --profile <client|service|session>`
- `tray startup install|uninstall|start|stop|status`

## Notes

- The CLI now enforces strict noun-verb commands.
- Legacy action flags and tray shortcut aliases were removed.

## Design docs

- TUI plan: [`docs/cli/tui/DESIGN.md`](./tui/DESIGN.md)
