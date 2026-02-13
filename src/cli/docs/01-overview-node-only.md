# ZiggyStarClaw CLI (node-only build)

## Usage

```text
ziggystarclaw-cli <command> [options]
ziggystarclaw-cli [legacy options]
```

## Preferred command style (noun verb)

- `node service ...`
- `node session ...`
- `node runner ...`
- `node profile apply --profile <client|service|session>`
- `tray startup install|uninstall|start|stop|status`

## Notes

- This build is intentionally **node-only**.
- Operator/client commands (sessions, messages/chat, approvals inbox, device pairing, and remote node invoke) are excluded.
- Use `--help` to see node-runner and node-mode focused usage.
