ZiggyStarClaw CLI

Usage:
  ziggystarclaw-cli <command> [options]
  ziggystarclaw-cli [deprecated legacy options]

Preferred command style (noun verb):
  chat send <message>
  session|sessions list|use <key>
  node|nodes list|use <id>|run <command>|which <name>|notify <title>
  node process list|spawn <command>|poll <processId>|stop <processId>
  node canvas present|hide|navigate <url>|eval <js>|snapshot <path>
  node approvals get|allow <command>|allow-file <path>
  approvals list|approve <id>|deny <id>
  device|devices list|approve <requestId>|reject <requestId>
  node service ...
  node session ...
  node runner ...
  node profile apply --profile <client|service|session>
  tray startup install|uninstall|start|stop|status

Notes:
  - Legacy flag-style action options are deprecated and emit warnings with the noun-verb replacement.
  - Legacy tray aliases are also supported: tray install-startup|uninstall-startup|start|stop|status (deprecated; use tray startup ...).
  - Use --help to see preferred command-style usage plus transitional compatibility flags.
