## Summary
- harden node-only profile boundaries so operator-only surfaces are consistently blocked with the standard unsupported hint
- add a dedicated `src/cli/node_only_chunk.zig` and move node-only maintenance/update-path logic out of `src/main_cli.zig`
- add node-only overview/help docs and chunking docs updates
- add node-only CLI profile tests (`tests/test_cli_node_only.py`)
- update CI and release packaging docs/scripts to build and validate both full + node-only CLI variants

## Why
Work item 15 asks for separable CLI chunks that can produce a smaller node-only binary that cannot act as operator. This change tightens that split and validates it in tests/packaging.

## Validation
- `zig build -Dclient=false`
- `python3 -m pytest tests/test_cli_unit.py -q`
- `zig build -Dclient=false -Dcli_operator=false --prefix ./zig-out/node-only`
- `ZSC_NODE_ONLY_CLI=./zig-out/node-only/bin/ziggystarclaw-cli python3 -m pytest tests/test_cli_node_only.py -q`
