# Work Items (ZiggyStarClaw)

Shared, high-level backlog that both Deano and Ziggy can edit.

## Rules

- Put the most important items at the top.
- If an item is exploratory or risky, mark it **no-auto-merge**.
- Tag items with an area prefix, e.g. `[node]`, `[operator]`, `[canvas]`, `[ui]`.
- Ziggy may pick the top item when the PR queue is empty **unless it matches an avoided area**.

## Avoid areas

The PM loop should not start new work in these areas (to avoid parallel conflicting efforts):

- `ui`

## Items

1. `[protocol]` Define/confirm the exact OpenClaw node auth + pairing protocol fields (connect.auth vs device-auth payload) and document with examples.
2. `[operator]` Implement operator role support in node-mode (second connection/profile) + approval workflows.
3. **no-auto-merge**: `[canvas]` Canvas/CDP: implement real `canvas.navigate` / `canvas.eval` / `canvas.snapshot` via CDP
4. `[cli]` Move to a more modern verb noun CLI following OpenClaws own CLI where we overlap (i.e. ziggy_starclaw device approve <DEVICE_I>
5. **no-auto-merge**: `[tui]` Design a plan for a tui for the CLI
6. `[refactor]` Moderlize parts into seperate chunk to support smaller cli were desired (i.e. just a node program that only can be used a node not an operator)
