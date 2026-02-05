# Node auth + pairing protocol (field-level)

Status: **draft / confirm against current gateway implementation**.

This doc is meant to answer the recurring question:

- What token goes **where**? (WebSocket `Authorization` header vs `connect.params.auth.token` vs device-auth signed payload)
- What exact fields are used for **device identity + pairing**?

Sources:

- `src/main_node.zig` (node-mode token design)
- `src/node_register.zig` (node-register flow)
- `docs/moltbot_websocket_protocol.md` (connect/hello-ok framing)
- `docs/user/node-mode.md` (user-facing notes)

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

**Current node-mode invariant:**

- `Authorization` header token MUST equal `connect.params.auth.token`.

See:

- `src/main_node.zig`: `connect.auth.token must match the WebSocket Authorization token.`
- `src/node_register.zig`: same comment in the register utility.

### 2.2 `connect` request

The first WS frame is a `connect` request, which includes:

- `params.auth.token` (the same gateway token as the WS `Authorization` header)
- `params.device.*` (device identity proof)

Minimal shape (illustrative):

```json
{
  "type": "req",
  "id": "1",
  "method": "connect",
  "params": {
    "minProtocol": 1,
    "maxProtocol": 1,
    "role": "node",
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
      "id": "<device_fingerprint>",
      "publicKey": "<base64>",
      "nonce": "<connect.challenge.nonce>",
      "signedAt": 1737264000000,
      "signature": "<sig(nonce)>"
    }
  }
}
```

Notes:

- Exact fields for `device` are described in `docs/moltbot_websocket_protocol.md`.
- The gateway may emit `connect.challenge` before `connect`.

### 2.3 Device-auth signed payload (node-mode)

Node-mode has a second authentication concept: a signed device payload.

On the wire, this appears inside `connect.params.device` as:

- `device.id`
- `device.publicKey`
- `device.signature`
- `device.signedAt`
- `device.nonce` (optional; only present when the gateway has sent `connect.challenge`)

(See `src/protocol/gateway.zig` `DeviceAuth` and `src/client/websocket_client.zig` `sendConnectRequest()`.)

**Which token is used inside the signed payload?**

- If `node.nodeToken` exists, use it as the **device-auth token**.
- Otherwise fall back to `gateway.authToken` and warn.

See `src/main_node.zig`:

- `device_auth_token = if (cfg.node.nodeToken.len > 0) cfg.node.nodeToken else cfg.gateway.authToken;`

#### 2.3.1 Signed payload schema (exact)

Despite the name, the signed payload is **not JSON**. It is a UTF-8 string with pipe (`|`) separators built by `buildDeviceAuthPayload()`.

Base fields:

```
version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
```

If the gateway provided a nonce via `connect.challenge`, the payload becomes (v2):

```
v2|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token|nonce
```

If no nonce is available yet, the payload is (v1):

```
v1|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token
```

Where:

- `version` is the literal string `v1` or `v2`.
- `scopesCsv` is `scopes` joined with `,` (comma), with no additional escaping.
- `signedAtMs` is the current `std.time.milliTimestamp()`.
- `token` is `node.nodeToken` when available, else `gateway.authToken`.
- `nonce` is the gateway-provided `connect.challenge.payload.nonce`.

The signature is computed over the raw payload bytes (see `src/client/device_identity.zig` `key_pair.sign(payload, null)`).

TODO (confirm in gateway):

- How the gateway validates `signedAtMs` (replay window / clock skew tolerance).
- Whether the gateway requires v2 (nonce) in some deployments.

---

## 3) Pairing lifecycle

### 3.1 First time / unpaired

When a new device identity connects, the gateway may require pairing approval.

In `node-register` (`src/node_register.zig`):

- Connects using the gateway auth token for both WS auth and `connect.auth.token`.
- Waits for `hello-ok`.
- If `PairingRequired`, it prints the device id and instructs to approve in Control UI.

### 3.2 Approval

After approval, reconnecting yields `hello-ok` with a `deviceToken`.

Node-register persists it:

- Saves into `node.nodeToken`.

Node-mode then uses `node.nodeToken` for device-auth on subsequent runs.

### 3.3 Rotation

If the gateway rotates the device token, node-mode should persist the new one back to config.

(There are user-facing notes about this in `docs/user/node-mode.md`; confirm whether current node-mode code writes back automatically in all cases.)

---

## 4) Open questions / confirm list

To finish this doc precisely, confirm in gateway code/docs:

1. What triggers pairing required? (remote-only? policy-based? unknown device id?)
2. Exact field name: `hello-ok.auth.deviceToken` (confirm wire key names).
3. Confirm gateway-side validation details for the device-auth signature payload (v1 vs v2, replay window).
4. Whether connect `auth.token` is *always* required once WS `Authorization` is present.

---

## 5) Quick verification commands

From repo root:

```bash
# Find all references to connect.auth.token invariants
grep -RIn "connect\.auth" src docs

# Find hello-ok auth token handling
grep -RIn "hello-ok" src docs
grep -RIn "deviceToken" src docs
```
