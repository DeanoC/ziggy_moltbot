# Node mode (advanced)

Node mode runs a capability node that connects to the gateway and can execute approved commands or provide canvas features. It is intended for advanced users and automation workflows.

Note: Node mode is not supported on Windows.

## Quick start
```bash
ziggystarclaw-cli --node-mode --host 127.0.0.1 --port 18789
```

## Common options
- `--host <host>`: gateway host (default `127.0.0.1`)
- `--port <port>`: gateway port (default `18789`)
- `--display-name <name>`: friendly node name shown to operators
- `--node-id <id>`: override node ID
- `--config <path>`: custom node config path
- `--save-config`: persist config after successful connect
- `--tls`: enable TLS
- `--insecure-tls`: disable TLS verification (testing only)

## When to use node mode
- You need a dedicated execution node on a remote machine.
- You want to expose command execution with approvals.
- You want canvas capabilities (experimental).

## Security notes
- Use approvals for any command execution.
- Prefer TLS and valid certificates.
- Restrict network access to the gateway.

Image placeholder: Architecture diagram showing Client -> Gateway -> Node mode (with approvals flow).
