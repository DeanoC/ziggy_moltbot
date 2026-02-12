# CLI chunking (work item 15)

To support smaller binaries, the CLI is split into separable chunks:

- **Core/local chunk** (`src/main_cli.zig`)
  - Argument parsing
  - Node-mode entry points (`--node-mode`, `node register`)
  - Service/session/tray/supervisor helpers
  - Platform-local runner management

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

## Why this split

- Keeps node-runner/service workflows available in constrained builds.
- Reduces compile surface for node-only deployments.
- Makes future command-surface cleanup easier by isolating operator concerns.
