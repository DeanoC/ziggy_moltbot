# Connecting to a server

ZiggyStarClaw talks to an OpenClaw server over WebSocket.

## Required fields
- **Server URL**: `ws://` or `wss://`
- **Token**: required if your server expects auth

## TLS / certificates
- For `wss://` connections, TLS verification is on by default.
- You can toggle **Insecure TLS** in Settings to skip cert verification.
- Only use insecure TLS for trusted networks or testing.

## Common URL formats
- `wss://example.com:443/ws`
- `ws://10.0.0.5:8787`

## Tips
- If you copy a URL from GitHub or a web page, confirm it is a real WebSocket URL (not an HTML link).
- If your connection fails, check [Troubleshooting](troubleshooting.md).
