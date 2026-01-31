# OpenClaw: Operator & Node API and WebSocket Transport
## A Comprehensive Technical Overview

**Author:** Manus AI  
**Date:** January 30, 2026  
**Repository:** [openclaw/openclaw](https://github.com/openclaw/openclaw)

---

## Executive Summary

OpenClaw is a personal AI assistant framework that operates on a client-server architecture. The **gateway** acts as the central control plane, while **operators** (control clients) and **nodes** (capability providers) connect via a WebSocket-based protocol. This document provides a detailed technical analysis of the operator and node APIs, the WebSocket transport layer, and practical guidance for implementing external clients and nodes outside the core repository.

The protocol is designed to support a wide range of clients including CLI tools, web UIs, mobile apps, and headless services. It provides a unified interface for authentication, command invocation, event streaming, and state synchronization.

---

## 1. WebSocket Transport Layer

The OpenClaw gateway uses a **WebSocket-based protocol** as its primary transport mechanism. All communication between the gateway and its clients (operators and nodes) occurs over persistent WebSocket connections using JSON-formatted text frames.

### 1.1. Protocol Architecture

The protocol operates on a **request-response** model with support for **server-initiated events**. Three frame types are defined:

| Frame Type | Direction | Purpose |
|------------|-----------|---------|
| `req` (Request) | Client → Gateway | Invoke a method on the gateway |
| `res` (Response) | Gateway → Client | Return the result of a request |
| `event` (Event) | Gateway → Client | Notify clients of asynchronous events |

Each frame is a JSON object with a `type` field that identifies its purpose. Requests include an `id` field for correlation with responses, while events may include a `seq` field for ordering and gap detection.

### 1.2. Connection Handshake

The connection lifecycle begins with a mandatory handshake. The gateway may optionally send a `connect.challenge` event containing a nonce that the client must sign with its device key. This challenge-response mechanism ensures that non-local connections are authenticated.

**Gateway Challenge (optional):**

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": {
    "nonce": "random_nonce_string",
    "ts": 1737264000000
  }
}
```

**Client Connect Request:**

The first frame sent by the client must be a `connect` request. This frame contains all the information the gateway needs to authenticate the client and determine its capabilities.

```json
{
  "type": "req",
  "id": "unique_request_id",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "cli",
      "displayName": "OpenClaw CLI",
      "version": "2025.1.30",
      "platform": "darwin",
      "mode": "operator"
    },
    "role": "operator",
    "scopes": ["operator.admin"],
    "auth": {
      "token": "gateway_shared_token"
    },
    "device": {
      "id": "device_fingerprint",
      "publicKey": "base64url_encoded_public_key",
      "signature": "base64url_encoded_signature",
      "signedAt": 1737264000000,
      "nonce": "random_nonce_string"
    }
  }
}
```

**Gateway Hello-OK Response:**

Upon successful authentication, the gateway responds with a `hello-ok` payload containing server information, feature lists, and policy parameters.

```json
{
  "type": "res",
  "id": "unique_request_id",
  "ok": true,
  "payload": {
    "type": "hello-ok",
    "protocol": 3,
    "server": {
      "version": "2025.1.30",
      "connId": "connection_identifier",
      "host": "gateway.local"
    },
    "features": {
      "methods": ["chat.send", "agent.run", "node.invoke", ...],
      "events": ["tick", "chat.delta", "agent.status", ...]
    },
    "snapshot": { ... },
    "auth": {
      "deviceToken": "long_lived_device_token",
      "role": "operator",
      "scopes": ["operator.admin"]
    },
    "policy": {
      "maxPayload": 10485760,
      "maxBufferedBytes": 5242880,
      "tickIntervalMs": 15000
    }
  }
}
```

The `auth.deviceToken` in the response is a long-lived token scoped to the device and role. Clients should persist this token and use it for future connections instead of the shared gateway token.

### 1.3. Authentication Mechanisms

OpenClaw supports multiple authentication mechanisms to balance security and usability:

**Shared Gateway Token/Password:**

The simplest authentication method uses a pre-shared token or password configured on the gateway. This is suitable for local development and trusted environments.

**Device Identity and Pairing:**

For production deployments, OpenClaw uses a device identity system based on public-key cryptography. Each client generates a stable device ID derived from a keypair. The first time a device connects, it must be paired with the gateway through an approval process. Once paired, the gateway issues a device token that can be used for subsequent connections.

**Challenge-Response for Non-Local Connections:**

To prevent replay attacks, non-local connections must sign the gateway's challenge nonce with their device private key. The gateway verifies the signature using the device's public key before issuing a token.

### 1.4. Protocol Versioning

The protocol version is negotiated during the handshake. Clients specify their supported version range using `minProtocol` and `maxProtocol` parameters. The gateway will reject connections if there is no overlap between the client's supported versions and the server's current version.

The current protocol version is **3**, defined in `src/gateway/protocol/schema/protocol-schemas.ts`. When the protocol evolves, the version number is incremented, and clients must update their implementations accordingly.

### 1.5. Message Flow and Correlation

Requests and responses are correlated using the `id` field. When a client sends a request, it generates a unique ID and includes it in the frame. The gateway's response will include the same ID, allowing the client to match the response to the original request.

Events are unidirectional and do not require a response. However, they may include a `seq` field that increments with each event. Clients can use this sequence number to detect gaps in the event stream, which may indicate message loss or buffering issues.

### 1.6. Keep-Alive and Connection Health

The gateway sends periodic `tick` events to keep the connection alive and allow clients to detect silent connection failures. The interval is specified in the `hello-ok` response's `policy.tickIntervalMs` field (typically 15-30 seconds).

Clients should monitor the arrival of tick events and initiate a reconnection if no tick is received within a reasonable timeout (e.g., 2-3 times the tick interval).

---

## 2. Operator API

An **operator** is a client that controls the OpenClaw gateway. Operators are typically interactive applications such as CLIs, web UIs, or automation scripts. They have broad permissions to manage the gateway, send messages to channels, invoke agent runs, and interact with nodes.

### 2.1. Role and Scope System

The operator role is specified during the `connect` handshake. Access to specific methods is further controlled by **scopes**, which define fine-grained permissions.

**Common Operator Scopes:**

| Scope | Description |
|-------|-------------|
| `operator.read` | Read-only access to gateway state and configuration |
| `operator.write` | Permission to modify state, send messages, and trigger actions |
| `operator.admin` | Full administrative access including configuration changes |
| `operator.approvals` | Permission to approve or deny execution approval requests |
| `operator.pairing` | Permission to approve or reject device pairing requests |

When connecting, an operator can request one or more scopes. The gateway will grant scopes based on the authentication method and the client's device pairing status. For example, a device connecting from localhost may be automatically granted all scopes, while a remote device may require explicit approval.

### 2.2. Core Operator Methods

The operator API provides a comprehensive set of methods for interacting with the gateway. These methods are invoked by sending `req` frames with the appropriate `method` and `params` fields.

#### 2.2.1. Chat and Messaging

**`chat.send`**: Send a message to a channel (WhatsApp, Telegram, Slack, etc.).

```json
{
  "type": "req",
  "id": "req_123",
  "method": "chat.send",
  "params": {
    "channel": "whatsapp",
    "to": "+1234567890",
    "message": "Hello from OpenClaw!",
    "sessionKey": "default"
  }
}
```

**`send`**: A simplified message-sending method that uses the last-used channel and recipient from the session.

#### 2.2.2. Agent Operations

**`agent.run`**: Invoke the AI agent with a prompt and optional delivery to a channel.

```json
{
  "type": "req",
  "id": "req_124",
  "method": "agent.run",
  "params": {
    "message": "What's the weather like today?",
    "sessionKey": "default",
    "thinking": "medium",
    "deliver": true,
    "channel": "whatsapp",
    "to": "+1234567890"
  }
}
```

**`agents.list`**: List all active agent runs.

**`agent.identity`**: Get information about the agent's identity and configuration.

#### 2.2.3. Node Management

**`node.list`**: List all connected and paired nodes with their capabilities.

```json
{
  "type": "req",
  "id": "req_125",
  "method": "node.list",
  "params": {}
}
```

**Response:**

```json
{
  "type": "res",
  "id": "req_125",
  "ok": true,
  "payload": {
    "ts": 1737264000000,
    "nodes": [
      {
        "nodeId": "iphone_abc123",
        "displayName": "Dean's iPhone",
        "platform": "ios",
        "version": "1.2.3",
        "caps": ["camera", "location", "voice"],
        "commands": ["camera.snap", "location.get"],
        "connected": true,
        "paired": true
      }
    ]
  }
}
```

**`node.describe`**: Get detailed information about a specific node.

**`node.invoke`**: Invoke a command on a node (see section 3.2 for details).

**`node.pair.request`**, **`node.pair.approve`**, **`node.pair.reject`**: Manage node pairing.

#### 2.2.4. Configuration Management

**`config.get`**: Retrieve the current gateway configuration.

**`config.set`**: Update the gateway configuration.

**`config.patch`**: Apply a partial configuration update.

**`config.apply`**: Apply a configuration from a file or external source.

#### 2.2.5. Session Management

**`sessions.list`**: List all active sessions.

**`sessions.preview`**: Preview the message history for a session.

**`sessions.patch`**: Update session metadata (thinking level, verbose level, etc.).

**`sessions.reset`**: Clear the message history for a session.

**`sessions.delete`**: Delete a session entirely.

#### 2.2.6. Channel Operations

**`channels.status`**: Get the status of all configured channels (WhatsApp, Telegram, etc.).

**`channels.logout`**: Log out of a specific channel.

#### 2.2.7. System and Monitoring

**`health`**: Get the gateway's health status.

**`logs.tail`**: Stream recent log entries.

**`system.presence`**: Get a list of all connected devices and their roles.

### 2.3. Event Subscriptions

Operators receive asynchronous events from the gateway to stay informed of state changes and ongoing operations. Key events include:

| Event | Description |
|-------|-------------|
| `tick` | Periodic keep-alive event |
| `chat.delta` | Incremental message content during streaming |
| `agent.status` | Agent run status updates |
| `node.pair.requested` | A new node has requested pairing |
| `exec.approval.requested` | A command execution requires approval |
| `shutdown` | The gateway is shutting down |

Operators should implement handlers for these events to provide a responsive user experience.

---

## 3. Node API

A **node** is a client that provides capabilities to the OpenClaw gateway. Nodes extend the gateway's functionality by offering access to hardware (cameras, microphones), services (browser automation, system commands), or external APIs.

### 3.1. Node Role and Capability Declaration

During the `connect` handshake, a node declares its capabilities using three key parameters:

**`caps` (Capabilities):**

A list of high-level capability categories the node provides. Examples include:

- `camera`: Access to device cameras
- `location`: GPS and location services
- `voice`: Voice recording and transcription
- `canvas`: Web browser control
- `screen`: Screen recording and snapshots
- `system`: System command execution

**`commands` (Command Allowlist):**

A list of specific commands that can be invoked on the node. This serves as a security allowlist to prevent unauthorized operations. Examples:

- `camera.snap`: Capture a photo
- `location.get`: Get current GPS coordinates
- `voice.record`: Start voice recording
- `canvas.navigate`: Navigate to a URL in the browser
- `system.run`: Execute a system command

**`permissions` (Granular Toggles):**

A dictionary of boolean flags that provide fine-grained control over specific operations. This allows users to grant or deny individual permissions even within a capability category. Examples:

```json
{
  "camera.capture": true,
  "screen.record": false,
  "location.precise": true
}
```

**Example Node Connect Request:**

```json
{
  "type": "req",
  "id": "node_connect_1",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "ios-node",
      "displayName": "Dean's iPhone",
      "version": "1.2.3",
      "platform": "ios",
      "deviceFamily": "iPhone",
      "modelIdentifier": "iPhone15,2",
      "mode": "node"
    },
    "role": "node",
    "scopes": [],
    "caps": ["camera", "location", "voice"],
    "commands": ["camera.snap", "location.get", "voice.record"],
    "permissions": {
      "camera.capture": true,
      "location.precise": true
    },
    "auth": { "token": "..." },
    "device": { ... }
  }
}
```

### 3.2. Command Invocation Flow

When an operator wants to invoke a command on a node, it sends a `node.invoke` request to the gateway. The gateway validates the request against the node's declared commands and any server-side allowlists, then forwards the invocation to the node as a `node.invoke` event.

**Operator → Gateway (`node.invoke` request):**

```json
{
  "type": "req",
  "id": "invoke_123",
  "method": "node.invoke",
  "params": {
    "nodeId": "iphone_abc123",
    "command": "camera.snap",
    "params": {
      "resolution": "1080p",
      "flash": false
    },
    "timeoutMs": 30000,
    "idempotencyKey": "unique_key_123"
  }
}
```

**Gateway → Node (`node.invoke` event):**

```json
{
  "type": "event",
  "event": "node.invoke",
  "payload": {
    "id": "invoke_123",
    "nodeId": "iphone_abc123",
    "command": "camera.snap",
    "paramsJSON": "{\"resolution\":\"1080p\",\"flash\":false}",
    "timeoutMs": 30000
  }
}
```

**Node → Gateway (`node.invoke.result` request):**

After executing the command, the node sends the result back to the gateway using the `node.invoke.result` method.

```json
{
  "type": "req",
  "id": "result_123",
  "method": "node.invoke.result",
  "params": {
    "id": "invoke_123",
    "nodeId": "iphone_abc123",
    "ok": true,
    "payloadJSON": "{\"imageUrl\":\"https://...\",\"timestamp\":1737264000000}"
  }
}
```

**Gateway → Operator (`node.invoke` response):**

The gateway forwards the result to the operator as the response to the original `node.invoke` request.

```json
{
  "type": "res",
  "id": "invoke_123",
  "ok": true,
  "payload": {
    "ok": true,
    "nodeId": "iphone_abc123",
    "command": "camera.snap",
    "payload": {
      "imageUrl": "https://...",
      "timestamp": 1737264000000
    }
  }
}
```

### 3.3. Node-Initiated Events

Nodes can proactively send events to the gateway using the `node.event` method. This is useful for reporting asynchronous events that are not in response to a specific invocation.

**Common Node Events:**

**`voice.transcript`**: A voice recording has been transcribed.

```json
{
  "type": "req",
  "id": "event_456",
  "method": "node.event",
  "params": {
    "event": "voice.transcript",
    "payloadJSON": "{\"text\":\"Hello, how are you?\",\"sessionKey\":\"default\"}"
  }
}
```

When the gateway receives this event, it can trigger an agent run with the transcribed text.

**`agent.request`**: The node is requesting an agent run (e.g., via a Siri shortcut or voice command).

```json
{
  "type": "req",
  "id": "event_457",
  "method": "node.event",
  "params": {
    "event": "agent.request",
    "payloadJSON": "{\"message\":\"What's on my calendar today?\",\"sessionKey\":\"default\",\"deliver\":true}"
  }
}
```

**`chat.subscribe` / `chat.unsubscribe`**: The node wants to subscribe to or unsubscribe from chat events for a specific session.

**`exec.started` / `exec.finished` / `exec.denied`**: The node is reporting the status of a command execution.

### 3.4. Node-Host Runner

The `node-host` component (defined in `src/node-host/runner.ts`) is a reference implementation of a node that runs on the same machine as the gateway or on a remote server. It provides several key capabilities:

**System Command Execution (`system.run`):**

The node-host can execute arbitrary system commands with configurable security policies. It supports three security modes:

- `deny`: All execution requests are denied.
- `allowlist`: Only commands matching the allowlist are executed.
- `full`: All commands are executed (use with caution).

Commands can also require approval from an operator before execution, providing an additional layer of security.

**Browser Control (`browser.proxy`):**

The node-host integrates with the OpenClaw browser control service to provide programmatic access to a headless browser. This allows agents to navigate web pages, fill forms, and extract information.

**Execution Approvals:**

When a command requires approval, the node-host sends an `exec.approval.requested` event to the gateway, which broadcasts it to all connected operators. An operator can then approve or deny the request using the `exec.approval.resolve` method.

---

## 4. Implementing External Clients and Nodes

This section provides practical guidance for developers who want to build external clients or nodes that interact with the OpenClaw gateway.

### 4.1. Protocol Schema and Type Generation

The WebSocket protocol is defined using **TypeBox** schemas in `src/gateway/protocol/schema`. These schemas provide a single source of truth for the protocol's structure and validation rules.

To ensure compatibility with the gateway, you should generate types and validation code from these schemas. The OpenClaw repository includes scripts for generating TypeScript types and Swift models:

- `pnpm protocol:gen`: Generate TypeScript types
- `pnpm protocol:gen:swift`: Generate Swift models for iOS/macOS clients

For other languages, you can use the JSON Schema output from TypeBox with code generation tools like **quicktype** or **json-schema-to-typescript**.

### 4.2. Connection Management Best Practices

**Automatic Reconnection:**

Implement automatic reconnection with exponential backoff to handle gateway restarts, network interruptions, and temporary failures. Start with a short delay (e.g., 1 second) and double it on each failed attempt, up to a maximum (e.g., 30 seconds).

**Tick Monitoring:**

Monitor the arrival of `tick` events to detect silent connection failures. If no tick is received within 2-3 times the expected interval, assume the connection is dead and initiate a reconnection.

**Graceful Shutdown:**

When the gateway sends a `shutdown` event, close the connection gracefully and wait for the specified `restartExpectedMs` before attempting to reconnect.

### 4.3. Device Identity and Pairing

**Generate a Stable Device Identity:**

Each client should generate a stable device ID derived from a keypair. The device ID should be consistent across restarts and should not change unless the user explicitly resets it.

OpenClaw uses Ed25519 keypairs for device identity. The device ID is derived from the public key using a hash function.

**Implement the Pairing Flow:**

For production deployments, implement the device pairing flow:

1. Generate a device keypair on first launch.
2. Send a `connect` request with the device identity.
3. If the device is not yet paired, the gateway will reject the connection.
4. Send a `node.pair.request` or `device.pair.request` to initiate pairing.
5. Wait for an operator to approve the pairing request.
6. Retry the `connect` request with the device identity.
7. The gateway will issue a device token that can be used for future connections.

**Persist the Device Token:**

Once a device token is issued, persist it securely (e.g., in the system keychain). Use the device token for subsequent connections instead of the shared gateway token.

### 4.4. Security Considerations

**Use TLS for Production:**

Always use `wss://` (WebSocket over TLS) for production deployments to encrypt communication between the client and the gateway. This prevents eavesdropping and man-in-the-middle attacks.

**Implement Certificate Pinning:**

For additional security, implement TLS certificate pinning by specifying the gateway's certificate fingerprint in the client configuration. This prevents attacks where an attacker presents a valid certificate from a different authority.

**Validate All Inputs:**

Use the TypeBox schemas to validate all incoming messages before processing them. This prevents injection attacks and ensures that the client behaves correctly even if the gateway sends unexpected data.

**Implement Command Allowlists:**

For nodes that execute system commands or access sensitive resources, implement strict command allowlists. Only execute commands that are explicitly declared in the `commands` parameter during the `connect` handshake.

### 4.5. Error Handling and Resilience

**Handle Protocol Version Mismatches:**

If the gateway rejects the connection due to a protocol version mismatch, provide a clear error message to the user and suggest updating the client or gateway.

**Implement Idempotency:**

For side-effecting operations (e.g., sending a message, executing a command), use idempotency keys to prevent duplicate execution in case of network failures or retries.

**Gracefully Handle Timeouts:**

Set reasonable timeouts for all requests and handle timeout errors gracefully. For long-running operations (e.g., agent runs), consider implementing a polling mechanism or subscribing to status events.

### 4.6. Example: Minimal Node Implementation (Pseudocode)

```javascript
// Minimal node implementation in JavaScript/TypeScript

import WebSocket from 'ws';
import { loadOrCreateDeviceIdentity, signDevicePayload } from './device-identity';

class OpenClawNode {
  constructor(gatewayUrl, capabilities) {
    this.gatewayUrl = gatewayUrl;
    this.capabilities = capabilities;
    this.ws = null;
    this.deviceIdentity = loadOrCreateDeviceIdentity();
  }

  connect() {
    this.ws = new WebSocket(this.gatewayUrl);
    
    this.ws.on('open', () => {
      console.log('Connected to gateway');
    });
    
    this.ws.on('message', (data) => {
      const frame = JSON.parse(data);
      this.handleFrame(frame);
    });
    
    this.ws.on('close', () => {
      console.log('Connection closed, reconnecting...');
      setTimeout(() => this.connect(), 5000);
    });
  }

  handleFrame(frame) {
    if (frame.type === 'event') {
      if (frame.event === 'connect.challenge') {
        this.sendConnect(frame.payload.nonce);
      } else if (frame.event === 'node.invoke') {
        this.handleInvoke(frame.payload);
      }
    } else if (frame.type === 'res') {
      // Handle response to our requests
    }
  }

  sendConnect(nonce) {
    const device = {
      id: this.deviceIdentity.deviceId,
      publicKey: this.deviceIdentity.publicKeyBase64Url,
      signature: signDevicePayload(this.deviceIdentity.privateKey, nonce),
      signedAt: Date.now(),
      nonce: nonce
    };

    const connectRequest = {
      type: 'req',
      id: 'connect_1',
      method: 'connect',
      params: {
        minProtocol: 3,
        maxProtocol: 3,
        client: {
          id: 'my-custom-node',
          version: '1.0.0',
          platform: process.platform,
          mode: 'node'
        },
        role: 'node',
        caps: this.capabilities.caps,
        commands: this.capabilities.commands,
        device: device
      }
    };

    this.ws.send(JSON.stringify(connectRequest));
  }

  handleInvoke(payload) {
    const { id, command, paramsJSON } = payload;
    const params = JSON.parse(paramsJSON || '{}');

    // Execute the command
    const result = this.executeCommand(command, params);

    // Send the result back
    this.sendInvokeResult(id, result);
  }

  executeCommand(command, params) {
    // Implement your command handlers here
    if (command === 'example.hello') {
      return { message: 'Hello from custom node!' };
    }
    throw new Error(`Unknown command: ${command}`);
  }

  sendInvokeResult(invokeId, result) {
    const resultRequest = {
      type: 'req',
      id: `result_${Date.now()}`,
      method: 'node.invoke.result',
      params: {
        id: invokeId,
        nodeId: this.deviceIdentity.deviceId,
        ok: true,
        payloadJSON: JSON.stringify(result)
      }
    };

    this.ws.send(JSON.stringify(resultRequest));
  }
}

// Usage
const node = new OpenClawNode('ws://localhost:18789', {
  caps: ['custom'],
  commands: ['example.hello']
});

node.connect();
```

---

## 5. Advanced Topics

### 5.1. Execution Approvals

The execution approval system provides a security mechanism for nodes that execute potentially dangerous operations (e.g., system commands). When a command requires approval, the node sends an `exec.approval.requested` event to the gateway, which broadcasts it to all connected operators with the `operator.approvals` scope.

An operator can then approve or deny the request using the `exec.approval.resolve` method. The gateway forwards the decision back to the node, which can then proceed with or abort the execution.

### 5.2. Skills and Remote Bins

OpenClaw supports a **skills** system where nodes can download and execute remote binaries. This allows the gateway to extend node capabilities dynamically without requiring a full client update.

Nodes can call the `skills.bins` method to fetch the current list of skill executables. These executables are then added to the node's command allowlist, allowing them to be invoked via `system.run`.

### 5.3. Browser Control Integration

The `browser.proxy` capability allows nodes to provide programmatic access to a headless browser. This is implemented in the node-host runner using the OpenClaw browser control service.

Operators can invoke browser commands through the node, such as navigating to a URL, clicking elements, filling forms, and capturing screenshots. The browser control service handles the low-level browser automation using tools like Puppeteer or Playwright.

### 5.4. Multi-Device Presence

The gateway maintains a presence system that tracks all connected devices and their roles. A single device can connect with multiple roles simultaneously (e.g., as both an operator and a node).

The `system.presence` method returns a list of all connected devices with their roles, scopes, and capabilities. This allows UIs to show a unified view of the user's devices and their current status.

---

## 6. Conclusion

The OpenClaw gateway provides a powerful and flexible WebSocket-based protocol for building a wide range of clients and nodes. By understanding the handshake process, message framing, authentication mechanisms, and the roles of operators and nodes, developers can extend the capabilities of OpenClaw to meet their specific needs.

Key takeaways for external implementers:

1. **Use the TypeBox schemas** to generate types and validation code for your language of choice.
2. **Implement robust connection management** with automatic reconnection and exponential backoff.
3. **Generate a stable device identity** and implement the pairing flow for production deployments.
4. **Use TLS and certificate pinning** for secure communication in production environments.
5. **Validate all inputs** and implement strict command allowlists for nodes that execute sensitive operations.
6. **Handle errors gracefully** and provide clear feedback to users when things go wrong.

The OpenClaw protocol is designed to be extensible and future-proof. As the project evolves, new capabilities and methods will be added, but the core architecture and principles will remain consistent.

---

## Appendix: Key File Locations

For developers who want to dive deeper into the OpenClaw codebase, here are the key files and directories:

| Path | Description |
|------|-------------|
| `src/gateway/protocol/` | Protocol definitions and schemas |
| `src/gateway/protocol/schema/` | TypeBox schemas for all protocol messages |
| `src/gateway/server/ws-connection/message-handler.ts` | WebSocket message handling on the gateway |
| `src/gateway/client.ts` | Reference WebSocket client implementation |
| `src/gateway/server-methods/` | Implementation of all gateway methods |
| `src/gateway/server-node-events.ts` | Node event handling logic |
| `src/node-host/runner.ts` | Reference node implementation (node-host) |
| `docs/gateway/protocol.md` | Official protocol documentation |

---

**Document Version:** 1.0  
**Last Updated:** January 30, 2026  
**Repository Commit:** Latest from main branch
