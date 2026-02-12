ZiggyStarClaw Node Mode

Usage:
  ziggystarclaw-cli --node-mode [options]

Config:
  Uses a single config file (no legacy fallbacks):
    %APPDATA%\ZiggyStarClaw\config.json

Options:
  --config <path>            Path to config.json (default: %APPDATA%\ZiggyStarClaw\config.json)
  --url <url>                Override gateway URL (ws/wss/http/https; with or without /ws)
  --gateway-token <token>    Override gateway auth token (handshake + connect auth)
  --node-token <token>       Override node device token (role=node)
  --display-name <name>      Override node display name shown in gateway UI
  --as-node / --no-node      Enable/disable node connection (default: from config)
  --as-operator / --no-operator  Enable/disable operator connection (default: from config)
  --auto-approve-pairing    Auto-approve pairing requests (node-mode only)
  --pairing-timeout <sec>   Pairing approval timeout in seconds (default: 120)
  --insecure-tls             Disable TLS verification
  --log-level <level>        Log level (debug|info|warn|error)
  -h, --help                 Show help
