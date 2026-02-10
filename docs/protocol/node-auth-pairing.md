# Node auth + pairing protocol (field-level)

Status: **current (mirrors gateway implementation)**.

This doc answers:

- What token goes **where**? (WebSocket `Authorization` header vs `connect.params.auth.token` vs the device-auth signed payload)
- What exact fields are used for **device identity + pairing**?

Gateway source-of-truth (server-side):

- OpenClaw: `docs/protocol/auth-pairing.md`
- `src/gateway/protocol/schema/frames.ts` (`ConnectParamsSchema`)
- `src/gateway/device-auth.ts` (`buildDeviceAuthPayload`)
- `src/gateway/server/ws-connection/message-handler.ts` (validation + nonce rules)

ZiggyStarClaw (client-side) references:

- `src/client/websocket_client.zig` (`sendConnectRequest()`)
- `src/protocol/gateway.zig` (`ConnectParams`, `DeviceAuth`)
- `src/client/device_identity.zig` (signing)
- `src/main_node.zig` + `src/node_register.zig` (token invariants, node-mode lifecycle)

---

## 1) Terminology

- **Gateway auth token**: `gateway.authToken` in config. Shared secret used for:
  - WebSocket handshake `Authorization` header
  - `connect.params.auth.token`

- **Node device token**: `node.nodeToken` in config.
  - Issued/rotated by gateway in `hello-ok.auth.deviceToken`.
  - Used by node-mode inside the **device-auth signed payload** when available.

- **Device identity**: keypair-backed identity stored at `node.deviceIdentityPath`.

---

## 2) Connection: which token goes where?

### 2.1 WebSocket handshake

The client opens a WS connection and sends an `Authorization` header.

**Current node-mode invariant (client-side):**

- WS `Authorization` token MUST equal `connect.params.auth.token`.

See:

- `src/main_node.zig`: `connect.auth.token must match the WebSocket Authorization token.`
- `src/node_register.zig`: same comment in the register utility.

### 2.2 `connect` request (WS first frame)

The first WS frame is a `connect` request. In addition to protocol negotiation + client info, it includes:

- `params.auth.token` (the same token as the WS `Authorization` header)
- `params.device.*` (device identity + signature)

Illustrative minimal shape (wire has more fields; see gateway schema for the full set):

```json
{
  "type": "req",
  "id": "1",
  "method": "connect",
  "params": {
    "minProtocol": 1,
    "maxProtocol": 1,
    "role": "node",
    "scopes": ["node.*"],
    "client": {
      "id": "node-host",
      "mode": "node",
      "displayName": "ZiggyStarClaw Node"
    },
    "caps": ["system", "process", "canvas"],
    "commands": ["system.run"],
    "auth": {
      "token": "<gateway.authToken>"
    },
    "device": {
      "id": "<deviceId>",
      "publicKey": "<base64url>",
      "signedAt": 1737264000000,
      "nonce": "<connect.challenge.nonce>",
      "signature": "<signature-over-device-auth-payload>"
    }
  }
}
```

Notes:

- The gateway may emit `connect.challenge` (with a nonce) before `connect`.
- `device.nonce` is required for non-loopback connections (nonce-bound signatures).
- `device.signedAt` must be “fresh” (gateway currently allows about ±10 minutes of skew).

---

## 3) Device-auth signed payload (node-mode)

On the wire, this appears inside `connect.params.device` as:

- `device.id`
- `device.publicKey`
- `device.signature`
- `device.signedAt`
- `device.nonce` (when the gateway has issued a `connect.challenge`)

Despite the name, the signed payload is **not JSON**. It is a UTF-8 string with pipe (`|`) separators.

### 3.1 Which token is used inside the signed payload?

Node-mode uses a *device-auth token* when constructing the signed payload:

- If `node.nodeToken` exists, use it.
- Otherwise fall back to `gateway.authToken` (with a warning).

See `src/main_node.zig`:

- `device_auth_token = if (cfg.node.nodeToken.len > 0) cfg.node.nodeToken else cfg.gateway.authToken;`

Important binding rule (gateway behavior):

- The device-auth payload includes the requested `role`/`scopes` **and** includes `connect.auth.token` (when present), binding those claims into the signature.

### 3.2 Signed payload schema (exact)

Base fields:

```
version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
```

Nonce-bound (v2):

```
v2|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token|nonce
```

Legacy / loopback-only (v1, no nonce):

```
v1|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
```

Where:

- `scopesCsv` is `scopes` joined with `,` (comma), no additional escaping.
- `signedAtMs` is `std.time.milliTimestamp()`.
- `token` is `connect.auth.token` on the wire; node-mode generally uses `node.nodeToken` when available, else `gateway.authToken`.
- `nonce` is `connect.challenge.payload.nonce` (aka `connect.device.nonce`).

The signature is computed over the raw payload bytes.

See:

- `src/client/websocket_client.zig` (payload construction)
- `src/client/device_identity.zig` (`key_pair.sign(payload, null)`)

---

## 4) Pairing lifecycle

### 4.1 First time / unpaired

When a new device identity connects, the gateway may require pairing approval.

In `node-register` (`src/node_register.zig`):

- Connects using the gateway auth token for both WS auth and `connect.auth.token`.
- Waits for `hello-ok`.
- If pairing is required, it prints the device id and instructs to approve in Control UI.

### 4.2 Approval

After approval, reconnecting yields `hello-ok` with a `deviceToken`.

Node-register persists it:

- Saves into `node.nodeToken`.

Node-mode then uses `node.nodeToken` for device-auth on subsequent runs.

### 4.3 Rotation

If the gateway rotates the device token, node-mode should persist the new one back to config.

(See `docs/user/node-mode.md` for user-facing notes; confirm current node-mode code writes back automatically in all cases.)

---

## 5) Quick verification commands

From repo root:

```bash
# Find all references to connect.auth.token invariants
grep -RIn "connect\\.auth" src docs

# Find hello-ok auth token handling
grep -RIn "hello-ok" src docs
grep -RIn "deviceToken" src docs
```
