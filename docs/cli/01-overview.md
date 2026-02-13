# ZiggyStarClaw CLI

## Usage

```text
ziggystarclaw <noun> <verb> [args] [options]
ziggystarclaw --help

# Backward-compatible binary name:
ziggystarclaw-cli <noun> <verb> [args] [options]
ziggystarclaw-cli --help
```

## Preferred command style (OpenClaw-style noun verb)

- `message send <message>` (aliases: `chat`, `messages`)
- `sessions list|use <key>` (alias: `session`)
- `nodes list|use <id>|run <command>|which <name>|notify <title>` (alias: `node`)
- `nodes process list|spawn <command>|poll <processId>|stop <processId>`
- `nodes canvas present|hide|navigate <url>|eval <js>|snapshot <path>`
- `nodes approvals get|allow <command>|allow-file <path>`
- `approvals pending|list|approve <id>|deny <id>` (alias: `approval`)
- `devices list|approve <requestId>|reject <requestId>` (alias: `device`)
- `node service ...`
- `node session ...`
- `node runner ...`
- `node profile apply --profile <client|service|session>`
- `tray startup install|uninstall|start|stop|status`

## Notes

- Legacy flag-style action options have been removed.
- Use strict noun-verb commands (`message send`, `sessions list`, `nodes run`, etc.).
- Tray commands now require the explicit noun form: `tray startup <action>`.

## Design docs

- TUI plan: [`docs/cli/tui/DESIGN.md`](./tui/DESIGN.md)
