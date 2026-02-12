ZiggyStarClaw CLI

Usage:
  ziggystarclaw-cli <command> [options]
  ziggystarclaw-cli [legacy options]

Preferred command style (noun verb):
  chat send <message>
  session list|use <key>
  node list|use <id>|run <command>|which <name>|notify <title>
  node process list|spawn <command>|poll <processId>|stop <processId>
  node canvas present|hide|navigate <url>|eval <js>|snapshot <path>
  node approvals get|allow <command>|allow-file <path>
  approvals list|approve <id>|deny <id>
  device list|approve <requestId>|reject <requestId>
  node service ...
  node session ...
  node runner ...
  node profile apply --profile <client|service|session>
  tray install-startup|uninstall-startup|start|stop|status

Notes:
  - Legacy flag-style options are still supported for compatibility.
  - Use --help to see both command-style and legacy actions.
