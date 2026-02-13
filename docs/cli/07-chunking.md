# CLI chunking (work item 15)

To support smaller binaries, the CLI is split into separable chunks:

- **Core/local chunk** (`src/main_cli.zig`)
  - Argument parsing
  - Node-mode entry points (`--node-mode`, `node register`)
  - Service/session/tray/supervisor helpers
  - Platform-local runner management

- **Node-only maintenance chunk** (`src/cli/node_only_chunk.zig`)
  - Local config/env override handling for node-only builds
  - Update-manifest inspection (`--print-update-url`) and check flow (`--check-update-only`)
  - Config persistence path for `--save-config` when operator chunk is absent

- **Operator chunk** (`src/cli/operator_chunk.zig`)
  - Gateway operator connection and auth profile
  - Session/chat/approvals/device-pair commands
  - Remote node command/invoke helpers
  - Interactive REPL and update-check flow

## Build behavior

- `-Dcli_operator=true` (default): builds full CLI with both chunks.
- `-Dcli_operator=false`: excludes the operator chunk at compile time.
  - Result: node-only CLI that cannot act as operator.
  - Operator-only commands fail with the standard unsupported hint.

Recommended local profile checks:

```bash
# Full profile
zig build -Dclient=false
python3 -m pytest tests/test_cli_unit.py -v

# Node-only profile
zig build -Dclient=false -Dcli_operator=false --prefix ./zig-out/node-only
ZSC_NODE_ONLY_CLI=./zig-out/node-only/bin/ziggystarclaw-cli \
  python3 -m pytest tests/test_cli_node_only.py -v
```

## Why this split

- Keeps node-runner/service workflows available in constrained builds.
- Reduces compile surface for node-only deployments.
- Makes future command-surface cleanup easier by isolating operator concerns.
