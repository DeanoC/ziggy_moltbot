# CLI basics

The CLI is useful for quick commands, automation, or remote workflows. It can also run in an interactive REPL mode.

A staged TUI design plan for the CLI is tracked in [`docs/tui-plan.md`](../tui-plan.md).

## Canonical command reference (shared with `--help`)
The source for CLI help text lives in [`docs/cli/`](../cli/) and is embedded directly by the CLI binary using `@embedFile`.

Main sections:
- [Overview](../cli/01-overview.md)
- [Options (full build)](../cli/02-options.md)
- [Legacy action flags (deprecated)](../cli/02-legacy-action-flags.md)
- [Options (node-only build)](../cli/02-options-node-only.md)
- [Node runner (Windows)](../cli/03-node-runner.md)
- [Tray startup (Windows)](../cli/04-tray-startup.md)
- [Node service helpers](../cli/05-node-service.md)
- [Global flags (full build)](../cli/06-global-flags.md)
- [Global flags (node-only build)](../cli/06-global-flags-node-only.md)
- [CLI chunking internals](../cli/07-chunking.md)
- [Node mode help](../cli/node-mode.md)
- [Operator mode help](../cli/operator-mode.md)

## Build profiles

Internally, the build is split into a core/local CLI chunk and an operator chunk (see [CLI chunking internals](../cli/07-chunking.md)).

- Full CLI (default):
  ```bash
  zig build -Dclient=false
  ```
- Node-only CLI (smaller binary; operator commands disabled):
  ```bash
  zig build -Dclient=false -Dcli_operator=false
  ```

## Quick commands (preferred noun-verb style)
- Send a message:
  ```bash
  ziggystarclaw-cli message send "hello"
  ```
  (`chat send` and `messages send` are aliases)
- List sessions:
  ```bash
  ziggystarclaw-cli sessions list
  ```
- List nodes:
  ```bash
  ziggystarclaw-cli nodes list
  ```
- Run a command on a node:
  ```bash
  ziggystarclaw-cli --node <id> nodes run "uname -a"
  ```

Legacy flag-style action options are deprecated. They still work during transition, but now emit warnings with command-style replacements.

Use `ziggystarclaw-cli --help-legacy` to see the deprecated legacy action flags.

## Connection setup (CLI)
The CLI reads a config file by default (`ziggystarclaw_config.json`). You can also override values:
```bash
ziggystarclaw-cli --url wss://example.com/ws --token <token> --save-config
```

Environment variables (optional overrides):
- `MOLT_URL`
- `MOLT_TOKEN`
- `MOLT_INSECURE_TLS`
- `MOLT_READ_TIMEOUT_MS`

## Interactive mode (REPL)
Start a REPL:
```bash
ziggystarclaw-cli --interactive
```

Commands:
- `help`
- `send <message>`
- `session [key]`
- `sessions`
- `node [id]`
- `nodes`
- `run <command>`
- `approvals`
- `approve <id>`
- `deny <id>`
- `save`
- `quit` / `exit`

## Default session/node behavior
- `message send` (and alias `chat send`) uses the default session if `--session` is not provided.
- `nodes run` (alias `node run`) uses the default node if `--node` is not provided.
- Set defaults with:
  ```bash
  ziggystarclaw-cli sessions use <key> --save-config
  ziggystarclaw-cli nodes use <id> --save-config
  ```

## Approvals
If your server requires approval for certain actions:
```bash
ziggystarclaw-cli approvals list
ziggystarclaw-cli approvals approve <id>
ziggystarclaw-cli approvals deny <id>
```

Device pairing approvals (operator scope):
```bash
ziggystarclaw-cli devices list
ziggystarclaw-cli devices approve <requestId>
ziggystarclaw-cli devices reject <requestId>
# singular aliases are also supported
ziggystarclaw-cli device approve <requestId>
```

Tray startup task management (Windows):
```bash
ziggystarclaw-cli tray startup status
ziggystarclaw-cli tray startup install
ziggystarclaw-cli tray startup uninstall
```

Legacy tray aliases (`tray install-startup`, `tray status`, etc.) still work but are deprecated.

## Common pitfalls
- **No node specified for `nodes run`.**  
  Pass `--node <id>` or set a default node in the config.
- **No sessions available.**  
  Use `sessions list` (legacy: `--list-sessions`) to verify the server is providing sessions.
- **Token missing/expired.**  
  Re-set `--token` and `--save-config` or update the config file.
