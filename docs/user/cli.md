# CLI basics

The CLI is useful for quick commands, automation, or remote workflows. It can also run in an interactive REPL mode.

## Canonical command reference (shared with `--help`)
The source for CLI help text lives in [`docs/cli/`](../cli/) and is embedded directly by the CLI binary using `@embedFile`.

Main sections:
- [Overview](../cli/01-overview.md)
- [Options](../cli/02-options.md)
- [Node runner (Windows)](../cli/03-node-runner.md)
- [Tray startup (Windows)](../cli/04-tray-startup.md)
- [Node service helpers](../cli/05-node-service.md)
- [Global flags](../cli/06-global-flags.md)
- [Node mode help](../cli/node-mode.md)
- [Operator mode help](../cli/operator-mode.md)

## Quick commands
- Send a message:
  ```bash
  ziggystarclaw-cli --send "hello"
  ```
- List sessions:
  ```bash
  ziggystarclaw-cli --list-sessions
  ```
- List nodes:
  ```bash
  ziggystarclaw-cli --list-nodes
  ```
- Run a command on a node:
  ```bash
  ziggystarclaw-cli --node <id> --run "uname -a"
  ```

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
- `--send` uses the default session if `--session` is not provided.
- `--run` uses the default node if `--node` is not provided.
- Set defaults with:
  ```bash
  ziggystarclaw-cli --use-session <key> --use-node <id> --save-config
  ```

## Approvals
If your server requires approval for certain actions:
```bash
ziggystarclaw-cli --list-approvals
ziggystarclaw-cli --approve <id>
ziggystarclaw-cli --deny <id>
```

## Common pitfalls
- **No node specified for `--run`.**  
  Either pass `--node <id>` or set a default node in the config.
- **No sessions available.**  
  Use `--list-sessions` to verify the server is providing sessions.
- **Token missing/expired.**  
  Re-set `--token` and `--save-config` or update the config file.
