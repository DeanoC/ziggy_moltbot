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

1. **no-auto-merge**: `[protocol]` Define/confirm the exact OpenClaw node auth + pairing protocol fields (connect.auth vs device-auth payload) and document with examples.
2. **no-auto-merge**: `[operator]` Implement operator role support in node-mode (second connection/profile) + approval workflows.
3. **no-auto-merge**: `[canvas]` Canvas/CDP: implement real `canvas.navigate` / `canvas.eval` / `canvas.snapshot` via CDP.
