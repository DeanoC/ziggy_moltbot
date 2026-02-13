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

Other actions:
  --session <key>          Target session for message send (uses default if not set)
  --node <id>              Target node for node commands
  --check-update-only      Fetch update manifest and exit
  --interactive            Start interactive REPL mode
  --node-mode              Run as a capability node (see --node-mode-help)
  --node-register          Interactive: pair as node (connect role=node and persist token)
  --wait-for-approval      With --node-register: keep retrying until approved
<<<<<<< HEAD
  --operator-mode          Deprecated (no-op): operator actions are available without it
