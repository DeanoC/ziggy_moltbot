# Canvas Configuration

ZiggyStarClaw node mode supports a visual canvas for HTML/CSS/JS rendering and A2UI.

## Backends

Two canvas backends are supported:

### 1. Chrome (Default)
Uses headless Chrome/Chromium with DevTools Protocol.

**Pros:**
- Full web standards support
- Easy to install
- Good headless mode

**Cons:**
- Requires Chrome/Chromium installation
- Higher memory usage
- Slower startup

**Setup:**
```bash
# Install Chromium
sudo apt-get install chromium-browser

# Or install Google Chrome
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
sudo sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list'
sudo apt-get update
sudo apt-get install google-chrome-stable
```

### 2. WebKitGTK
Uses native WebKitGTK library (like macOS WKWebView).

**Pros:**
- Native Linux integration
- Lower memory usage
- Similar to macOS implementation

**Cons:**
- Requires C interop (not fully implemented)
- More complex build process

**Setup:**
```bash
sudo apt-get install libwebkit2gtk-4.1-dev gir1.2-webkit2-4.1
```

### 3. None
Disables canvas functionality.

## Configuration

Edit `~/.openclaw/node.json`:

```json
{
  "canvas_enabled": true,
  "canvas_backend": "chrome",
  "canvas_width": 1280,
  "canvas_height": 720,
  "chrome_path": "/usr/bin/chromium",
  "chrome_debug_port": 9222
}
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `canvas_enabled` | Enable canvas capability | `false` |
| `canvas_backend` | Backend type: "chrome", "webkitgtk", "none" | `"chrome"` |
| `canvas_width` | Canvas width in pixels | `1280` |
| `canvas_height` | Canvas height in pixels | `720` |
| `chrome_path` | Path to Chrome executable (optional) | Auto-detect |
| `chrome_debug_port` | Chrome remote debugging port | `9222` |

## CLI Usage

```bash
# Start node with canvas enabled
ziggystarclaw-cli --node-mode --display-name "Canvas Node"

# Test canvas commands
openclaw nodes canvas present --node <node-id>
openclaw nodes canvas navigate --node <node-id> --url "https://example.com"
openclaw nodes canvas eval --node <node-id> --js "document.title"
openclaw nodes canvas snapshot --node <node-id> --path /tmp/screenshot.png
```

## Testing

```bash
# 1. Start Xvfb (for headless testing)
export DISPLAY=:99

# 2. Enable canvas in config
# Edit ~/.openclaw/node.json and set canvas_enabled: true

# 3. Start node
ziggystarclaw-cli --node-mode --log-level debug

# 4. Test canvas present
openclaw nodes canvas present --node <your-node-id>
```

## Implementation Status

| Feature | Chrome | WebKitGTK |
|---------|--------|-----------|
| canvas.present | ✅ Started | 🚧 Not implemented |
| canvas.hide | ✅ No-op | 🚧 Not implemented |
| canvas.navigate | ⚠️ CDP needed | 🚧 Not implemented |
| canvas.eval | ⚠️ CDP needed | 🚧 Not implemented |
| canvas.snapshot | ⚠️ CDP needed | 🚧 Not implemented |

**Legend:**
- ✅ Implemented
- ⚠️ Partial (Chrome started but needs DevTools Protocol)
- 🚧 Not implemented

## DevTools Protocol

Full Chrome support requires implementing Chrome DevTools Protocol (CDP):
- WebSocket connection to `ws://localhost:9222/devtools/browser`
- Send CDP commands for navigation, evaluation, screenshots

This is the same protocol used by Puppeteer/Playwright.

## A2UI Support

Canvas supports A2UI (Agent-to-UI) protocol for dynamic UI updates:

```bash
# Push A2UI updates
cat > /tmp/ui.jsonl << 'EOF'
{"surfaceUpdate":{"surfaceId":"main","components":[...]}}
{"beginRendering":{"surfaceId":"main","root":"root"}}
EOF

openclaw nodes canvas a2ui push --node <node-id> --jsonl /tmp/ui.jsonl
```
