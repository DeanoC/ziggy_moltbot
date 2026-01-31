# ZiggyStarClaw CLI Feature Audit

## Current Implementation Status

### Connection & Auth ✅
| Feature | Status | Notes |
|---------|--------|-------|
| WebSocket connect | ✅ | Full TLS support |
| Token auth | ✅ | Via CLI arg, config, or env var |
| Device identity | ✅ | Keypair-based device auth |
| Connect challenge | ✅ | Nonce signing for security |
| Auto-reconnect | ❌ | Not implemented |
| Heartbeat/ping | ⚠️ | Can send ping, no auto heartbeat |

### CLI Arguments ✅
| Feature | Status | Notes |
|---------|--------|-------|
| `--url` | ✅ | Override server URL |
| `--token` | ✅ | Override auth token |
| `--config` | ✅ | Config file path |
| `--insecure-tls` | ✅ | Disable TLS verification |
| `--read-timeout-ms` | ✅ | Socket timeout |
| `--help` / `-h` | ✅ | Usage info |
| `--agent` | ❌ | Not implemented |
| `--json` | ❌ | JSON output mode |
| `--verbose` | ❌ | Verbose logging |
| `--agent <id>` | ❌ | Target specific agent |
| `--session <key>` | ❌ | Target specific session |

### Chat Features ⚠️
| Feature | Status | Notes |
|---------|--------|-------|
| Receive chat events | ✅ | Logs to console |
| Display messages | ✅ | Basic logging only |
| Send messages | ❌ | Not implemented in CLI |
| Chat history | ✅ | Received but not displayed nicely |
| Attachments | ⚠️ | Parsed but not handled |
| Message formatting | ❌ | No markdown/rendering |
| Typing indicators | ❌ | Not implemented |
| Reply-to | ❌ | Not implemented |

### Sessions 📋
| Feature | Status | Notes |
|---------|--------|-------|
| List sessions | ✅ | Received and stored |
| Display sessions | ❌ | Not shown in CLI |
| Switch session | ❌ | Not implemented |
| Session history | ✅ | Received but minimal display |
| Create session | ❌ | Not implemented |
| Session labels | ⚠️ | Parsed but not used |
| Active session filtering | ❌ | Not implemented |

### Nodes 🔗
| Feature | Status | Notes |
|---------|--------|-------|
| List nodes | ✅ | Received and stored |
| Display nodes | ❌ | Not shown in CLI |
| Node describe | ✅ | Handled |
| Node invoke | ✅ | Handled |
| Display node results | ❌ | Not shown |
| Camera commands | ❌ | Not exposed in CLI |
| Screen commands | ❌ | Not exposed in CLI |
| Canvas commands | ❌ | Not exposed in CLI |
| Location commands | ❌ | Not exposed in CLI |
| System.run | ❌ | Not exposed in CLI |

### Approvals 🛡️
| Feature | Status | Notes |
|---------|--------|-------|
| Receive approval requests | ✅ | Handled |
| Display approvals | ❌ | Not shown in CLI |
| Resolve approvals | ❌ | Not implemented in CLI |
| Auto-approve | ❌ | Not implemented |
| Approval notifications | ✅ | Logged only |

### Message/Channel Actions 📨
| Feature | Status | Notes |
|---------|--------|-------|
| Send messages | ❌ | Not implemented |
| Send to channels | ❌ | Not implemented |
| Reactions | ❌ | Not implemented |
| Polls | ❌ | Not implemented |
| Thread operations | ❌ | Not implemented |
| Message edit/delete | ❌ | Not implemented |

### Environment/Config 🔧
| Feature | Status | Notes |
|---------|--------|-------|
| Config file support | ✅ | JSON config |
| Environment variables | ✅ | MOLT_URL, MOLT_TOKEN, etc. |
| Log level control | ✅ | MOLT_LOG_LEVEL |
| Log file | ✅ | MOLT_LOG_FILE |
| Multiple profiles | ❌ | Not implemented |

### Interactive Features 🎮
| Feature | Status | Notes |
|---------|--------|-------|
| Interactive REPL | ❌ | Not implemented |
| Command completion | ❌ | Not implemented |
| History navigation | ❌ | Not implemented |
| Tab completion | ❌ | Not implemented |
| Rich output | ❌ | Plain text only |

### Missing OpenClaw Features

#### Gateway Methods
- `chat.send` - Send messages to chat
- `chat.history` - Explicitly request history
- `sessions.history` - Get session history with filters
- `sessions.spawn` - Create new agent sessions
- `sessions.send` - Send messages to other sessions
- `sessions.list` - Explicitly request session list
- `node.list` - Explicitly request node list
- `node.pending` - View pending node pairings
- `node.approve` - Approve node pairing
- `node.invoke` - Invoke node commands
- `exec.approval.resolve` - Resolve exec approvals
- `device.pairing` - Manage device pairing
- `system.presence` - Get online devices
- `skills.bins` - Get available skills

#### Event Handling
- Full event parsing for all gateway events
- Proper state synchronization
- Real-time UI updates (CLI equivalent)

## What the CLI Currently Does

The current CLI is essentially a **read-only log viewer**:

1. Connects to OpenClaw gateway via WebSocket
2. Authenticates with token or device identity
3. Receives and logs all events/messages to console
4. Stores state internally (sessions, nodes, messages, approvals)
5. Handles auth token updates from server
6. Disconnects cleanly on exit

## Recommended Priority Features

### Phase 1: Basic Interaction (High Priority)
1. **Send messages** - Add `chat.send` support
2. **Session selection** - Allow switching/starting sessions
3. **Interactive mode** - Simple REPL for sending messages
4. **Better message display** - Format incoming messages nicely

### Phase 2: Node Operations (Medium Priority)
1. **List nodes** - Display connected/paired nodes
2. **Node invoke** - Run commands on nodes
3. **Camera/screen** - Basic media capture commands

### Phase 3: Approvals & Advanced (Lower Priority)
1. **Approval management** - View and resolve pending approvals
2. **Session management** - List, create, switch sessions
3. **Message channels** - Send to external channels (Discord, etc.)
4. **JSON mode** - Structured output for scripting

## Quick Win Commands to Add

```bash
# Send a message to current session
ziggystarclaw-cli --send "Hello, world!"

# List available sessions
ziggystarclaw-cli --list-sessions

# Switch to a session
ziggystarclaw-cli --session <key>

# List nodes
ziggystarclaw-cli --list-nodes

# Run command on node
ziggystarclaw-cli --node <id> --run "uname -a"

# Interactive mode
ziggystarclaw-cli --interactive
```

## OpenClaw Gateway Methods Reference

From OpenClaw docs, supported methods include:
- `connect` - Handshake (✅ implemented)
- `chat.send` - Send chat message (❌ missing)
- `chat.history` - Get chat history (⚠️ partially)
- `sessions.list` - List sessions (⚠️ partially)
- `sessions.history` - Get session history (⚠️ partially)
- `node.list` - List nodes (⚠️ partially)
- `node.describe` - Describe node capabilities (✅)
- `node.invoke` - Invoke node command (✅)
- `exec.approval.resolve` - Resolve approval (❌)
- `device.pairing` - Pairing operations (⚠️)
- `system.presence` - Get presence info (❌)

---

*Generated from code audit on 2026-01-31*
