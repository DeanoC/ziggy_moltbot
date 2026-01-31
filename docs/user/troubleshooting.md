# Troubleshooting

## “Invalid download URL”
- The URL may be a web page, not a file. It must point to a real release asset.
- Prefer using the latest release page and copy the asset link.

## “Server URL is empty”
- Open Settings and set a `ws://` or `wss://` URL.

## TLS errors
- Confirm your server uses a valid certificate.
- Try the **Insecure TLS** toggle only for testing.

## Can’t find a session or node
- Use the CLI to list sessions or nodes:
  ```bash
  ziggystarclaw-cli --list-sessions
  ziggystarclaw-cli --list-nodes
  ```
