# CLI basics

The CLI is useful for quick commands, automation, or remote workflows.

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

## Interactive mode
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

## Approvals
If your server requires approval for certain actions:
```bash
ziggystarclaw-cli --list-approvals
ziggystarclaw-cli --approve <id>
ziggystarclaw-cli --deny <id>
```
