# ZiggyStarClaw CLI

## Usage

```text
ziggystarclaw-cli <noun> <verb> [args] [options]
ziggystarclaw-cli --help
ziggystarclaw-cli --help-legacy
```

## Preferred command style (noun verb)

- `message send <message>` (aliases: `chat`, `messages`)
- `sessions list|use <key>` (alias: `session`)
- `nodes list|use <id>|run <command>|which <name>|notify <title>` (alias: `node`)
- `nodes process list|spawn <command>|poll <processId>|stop <processId>`
- `nodes canvas present|hide|navigate <url>|eval <js>|snapshot <path>`
- `nodes approvals get|allow <command>|allow-file <path>`
- `approvals list|approve <id>|deny <id>`
- `devices list|approve <requestId>|reject <requestId>` (alias: `device`)
- `node service ...`
- `node session ...`
- `node runner ...`
- `node profile apply --profile <client|service|session>`
- `tray startup install|uninstall|start|stop|status`

## Notes

- Legacy flag-style action options are deprecated and emit warnings with the noun-verb replacement.
- Use `--help-legacy` to see the deprecated legacy action flags.
- Legacy tray aliases are also supported: `tray install-startup|uninstall-startup|start|stop|status` (deprecated; use `tray startup ...`).
