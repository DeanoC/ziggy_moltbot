# workq moved

The `workq` CLI has been extracted into a dedicated repository:

- https://github.com/DeanoC/workq

Use that repo for ongoing development, issues, docs, and releases.

## Local usage (workspace)

```bash
node /safe/Safe/openclaw-config/workspace/workq/bin/workq.js help
/safe/Safe/openclaw-config/workspace/workq/test/smoke.sh
```

## PM-loop / progress-guard commands

```bash
node /safe/Safe/openclaw-config/workspace/workq/bin/workq.js sync-backlog \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --file /safe/Safe/openclaw-config/workspace/docs/WORK_ITEMS_GLOBAL.md

node /safe/Safe/openclaw-config/workspace/workq/bin/workq.js claim \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --queue zsc \
  --session pm-loop

node /safe/Safe/openclaw-config/workspace/workq/bin/workq.js status \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --stale \
  --ttl-ms 7200000
```
