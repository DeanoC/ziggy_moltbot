# Updates

ZiggyStarClaw checks for updates using the latest release metadata.

## What it uses
- Release page: shows the newest version
- Update manifest: `update.json` (generated during release packaging)

Image placeholder: Screenshot of the Updates section showing current version and status.

## How to update
1) Open the latest release page.
2) Download the bundle for your platform.
3) Replace your existing install.

## Update Manifest URL
In Settings, you can set an explicit update manifest URL if you host `update.json` elsewhere.
- Example: `https://example.com/ziggystarclaw/update.json`
- Leave it blank to use the default release flow.

## Common pitfalls
- **Invalid download URL**: the URL points to an HTML page, not a release asset.
- **Blocked download**: corporate networks may block GitHub downloads.
- **WASM updates**: you must replace the hosted files on your server.

If the app says “invalid download URL”, check that the update URL in Settings points to a valid release asset.
