# CLI basics

The CLI is useful for quick commands, automation, or remote workflows. It can also run in an interactive REPL mode.

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

## Quick commands (preferred OpenClaw-style noun-verb)
- Send a message:
  ```bash
  ziggystarclaw message send "hello"
  ```
  (`chat send`, `message send`, and `messages send` are aliases)
- List sessions:
  ```bash
  ziggystarclaw session list
  ```
- List nodes:
  ```bash
  ziggystarclaw node list
  ```
- Run a command on a node:
  ```bash
  ziggystarclaw --node <id> node run "uname -a"
  ```

`ziggystarclaw-cli` remains fully supported as a backward-compatible executable name.

Legacy flag-style action options are deprecated. They still work during transition, but now emit warnings with command-style replacements.

Use `ziggystarclaw --help-legacy` to see the deprecated legacy action flags.

## Connection setup (CLI)
The CLI reads a config file by default (`ziggystarclaw_config.json`). You can also override values:
```bash
ziggystarclaw --url wss://example.com/ws --token <token> --save-config
```

Environment variables (optional overrides):
- `MOLT_URL`
- `MOLT_TOKEN`
- `MOLT_INSECURE_TLS`
- `MOLT_READ_TIMEOUT_MS`

## Interactive mode (REPL)
Start a REPL:
```bash
ziggystarclaw --interactive
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
- `node run` (alias `nodes run`) uses the default node if `--node` is not provided.
- Set defaults with:
  ```bash
  ziggystarclaw session use <key> --save-config
  ziggystarclaw node use <id> --save-config
  ```

## Approvals
If your server requires approval for certain actions:
```bash
ziggystarclaw approval pending
ziggystarclaw approval approve <id>
ziggystarclaw approval deny <id>
```
(`approval`/`approvals` and `pending`/`list` are interchangeable aliases.)

Device pairing approvals (operator scope):
```bash
ziggystarclaw device pending
ziggystarclaw device approve <requestId>
ziggystarclaw device reject <requestId>
```
(`device`/`devices` and `pending`/`list` are interchangeable aliases.)

Tray startup task management (Windows):
```bash
ziggystarclaw tray startup status
ziggystarclaw tray startup install
ziggystarclaw tray startup uninstall
```

Legacy tray aliases (`tray install-startup`, `tray status`, etc.) still work but are deprecated.

## Common pitfalls
- **No node specified for `node run`.**  
  Pass `--node <id>` or set a default node in the config.
- **No sessions available.**  
  Use `session list` (legacy: `--list-sessions`) to verify the server is providing sessions.
- **Token missing/expired.**  
  Re-set `--token` and `--save-config` or update the config file.
