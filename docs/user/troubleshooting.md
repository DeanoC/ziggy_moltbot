# Troubleshooting

## “Invalid download URL”
- The URL may be a web page, not a file. It must point to a real release asset.
- Prefer using the latest release page and copy the asset link.

## “No node specified”
- Use `--node <id>` or set a default with `--use-node <id> --save-config`.

## “Server URL is empty”
- Open Settings and set a `ws://` or `wss://` URL.

## TLS errors
- Confirm your server uses a valid certificate.
- Try the **Insecure TLS** toggle only for testing.

## Tabs won’t stay selected
- If a tab flashes and switches back, it may be a focus issue. Restart the app and try again.

## Can’t find a session or node
- Use the CLI to list sessions or nodes:
  ```bash
  ziggystarclaw-cli --list-sessions
  ziggystarclaw-cli --list-nodes
  ```

Image placeholder: Screenshot of an error state (e.g., TLS error or invalid URL) with key fields highlighted.
