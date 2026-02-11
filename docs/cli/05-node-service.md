Node service helpers (Windows SCM service / Linux systemd)
  node service <action>      Convenience: install|uninstall|start|stop|status
  --node-service-install    Install and enable node-mode background service
  --node-service-uninstall  Uninstall the background service
  --node-service-start      Start the service now
  --node-service-stop       Stop the service
  --node-service-status     Show service status
  --node-service-mode <m>   onlogon|onstart (default: onstart on Windows; onlogon elsewhere)
  --node-service-name <n>   Override service name (default: ZiggyStarClaw Node)
  --extract-wsz <path>      Extract a Winamp .wsz skin to a directory (zip)
  --extract-dest <path>     Destination directory for --extract-wsz
