# Getting started

This guide walks you through installing and running ZiggyStarClaw for the first time.

## What you need
- A server URL (WebSocket `ws://` or `wss://`)
- An access token (if your server requires auth)

## Install
Download the latest release for your platform:
- Open the latest release page in your browser.
- Grab the bundle for your platform (Linux/Windows/Android/WASM).

Image placeholder: Screenshot of the GitHub releases page with the correct platform bundles highlighted.

## What’s inside the bundles
- **Linux**: `ziggystarclaw-client`, optional `ziggystarclaw-cli`
- **Windows**: `ziggystarclaw-client.exe`, optional `ziggystarclaw-cli.exe`
- **Android**: `ziggystarclaw_android.apk`
- **WASM**: `ziggystarclaw-client.html`, `ziggystarclaw-client.js`, `ziggystarclaw-client.wasm`

## Run (Linux)
1) Extract the release bundle.
2) Run `ziggystarclaw-client`.
3) Enter server URL + token in Settings.

Image placeholder: Screenshot of the Linux folder layout after extracting the bundle.

## Run (Windows)
1) Extract the release bundle.
2) Run `ziggystarclaw-client.exe`.
3) Enter server URL + token in Settings.

Image placeholder: Screenshot of the Windows folder layout after extracting the bundle.

## Run (Android)
1) Install the APK from the release bundle.
2) Open the app and enter server URL + token in Settings.

Image placeholder: Screenshot of the Settings screen on Android.

## Run (WASM)
1) Host the WASM bundle on a static web server.
2) Open `ziggystarclaw-client.html` in a browser.

Image placeholder: Diagram of WASM files served by a simple local web server (HTML/JS/WASM).

## Next steps
- [Connecting to a server](connection.md)
- [UI basics](ui.md)
