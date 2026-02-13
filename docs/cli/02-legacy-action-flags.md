Legacy action flags (deprecated)

These legacy flag-style “action” options are still accepted for compatibility, but emit warnings with the noun-verb replacement.

Prefer `ziggystarclaw <noun> <verb> ...` commands (`ziggystarclaw-cli` is still supported).

Deprecated legacy action flags:
  --send <message>         Deprecated: use message send <message>
  --list-sessions          Deprecated: use sessions list
  --use-session <key>      Deprecated: use sessions use <key>
  --list-nodes             Deprecated: use nodes list
  --use-node <id>          Deprecated: use nodes use <id>
  --run <command>          Deprecated: use nodes run <command>
  --which <name>           Deprecated: use nodes which <name>
  --notify <title>         Deprecated: use nodes notify <title>
  --ps                     Deprecated: use nodes process list
  --spawn <command>        Deprecated: use nodes process spawn <command>
  --poll <processId>       Deprecated: use nodes process poll <processId>
  --stop <processId>       Deprecated: use nodes process stop <processId>
  --canvas-present         Deprecated: use nodes canvas present
  --canvas-hide            Deprecated: use nodes canvas hide
  --canvas-navigate <url>  Deprecated: use nodes canvas navigate <url>
  --canvas-eval <js>       Deprecated: use nodes canvas eval <js>
  --canvas-snapshot <path> Deprecated: use nodes canvas snapshot <path>
  --exec-approvals-get     Deprecated: use nodes approvals get
  --exec-allow <command>   Deprecated: use nodes approvals allow <command>
  --exec-allow-file <path> Deprecated: use nodes approvals allow-file <path>
  --list-approvals         Deprecated: use approvals list
  --approve <id>           Deprecated: use approvals approve <id>
  --deny <id>              Deprecated: use approvals deny <id>
