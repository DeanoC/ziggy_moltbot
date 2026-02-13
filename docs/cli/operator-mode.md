# ZiggyStarClaw operator commands

Operator actions are available via the main CLI command surface.

## Usage (preferred noun-verb style)

```text
ziggystarclaw-cli <noun> <verb> [args] [options]
```

Common operator commands:

- `message send <message>`
- `sessions list|use <key>`
- `nodes list|use <id>|run <command>|which <name>|notify <title>`
- `approvals list|approve <id>|deny <id>`
- `devices list|watch|approve <requestId>|reject <requestId>`

## Legacy operator-mode flag

`--operator-mode` previously enabled a legacy operator-only CLI mode.

It is now **deprecated** and unnecessary; use the noun-verb commands above.

Use `--help-legacy` to see the remaining deprecated legacy action flags (ex: `--pair-list`, `--pair-approve`, `--watch-pairing`).
