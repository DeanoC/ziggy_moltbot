# UI basics

ZiggyStarClaw provides a focused UI for chat and operator workflows. This page walks through the main panels, common controls, and where to find key settings.

## Main areas
- **Chat**: send and view messages
- **Operator**: node status and actions
- **Settings**: connection and update info

Image placeholder: Full app screenshot with Chat, Operator, and Settings areas labeled.

## Chat panel
- Type into the message input and press **Enter** to send.
- If you have multiple sessions, use the session selector (if shown) to switch.
- If messages are not appearing, confirm the connection state in Settings.

Image placeholder: Chat panel with message input and a conversation history.

## Operator panel
- Shows connected nodes and their status.
- Lets you inspect node info (platform/version) and run supported actions.
- If you see no nodes, check your server connection and permissions.

Image placeholder: Operator panel with a connected node and actions visible.

## Settings panel
This is where you configure the connection and check for updates.

Key fields:
- **Server URL** and **Token**: used for WebSocket auth.
- **Insecure TLS**: skips certificate verification (use only on trusted networks).
- **Updates**: shows current version, release links, and update status.

Image placeholder: Settings panel showing connection fields and update status.

## Updates section
- **Current version**: what you’re running now.
- **Release page**: opens the latest release page.
- **Update status**: “update available” appears if a newer release is found.

If the update check fails, see [Troubleshooting](troubleshooting.md).

## Layout tips
- If a panel is hidden, check the menu bar or UI tabs.
- If the layout feels broken, restart the app and reopen the panel from the menu.

## Common pitfalls
- **Connected but no data**: the server may not be sending sessions/nodes yet.
- **Auth errors**: re-check your token in Settings and remove extra whitespace.
- **TLS errors**: only enable **Insecure TLS** if you trust the server.
