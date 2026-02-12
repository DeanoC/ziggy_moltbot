Options (full build):
  --url <ws/wss url>       Override server URL
  --token <token>          Override auth token (alias: --auth-token)
  --gateway-token <token>  Alias for --token
  --log-level <level>      Log level (debug|info|warn|error)
  --config <path>          Config file path (default: ~/.config/ziggystarclaw/config.json or %APPDATA%\ZiggyStarClaw\config.json)
  --update-url <url>       Override update manifest URL
  --print-update-url       Print normalized update manifest URL and exit
  --insecure-tls           Disable TLS verification
  --read-timeout-ms <ms>   Socket read timeout in milliseconds (default: 15000)

Deprecated legacy action flags (still supported during transition):
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

Other actions:
  --session <key>          Target session for message send (uses default if not set)
  --node <id>              Target node for node commands
  --check-update-only      Fetch update manifest and exit
  --interactive            Start interactive REPL mode
  --node-mode              Run as a capability node (see --node-mode-help)
  --node-register          Interactive: pair as node (connect role=node and persist token)
  --wait-for-approval      With --node-register: keep retrying until approved
  --operator-mode          Run as an operator client (pair/approve, list nodes, invoke)
