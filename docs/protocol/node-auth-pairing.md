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

**Current behavior (node-mode):**

- If `node.nodeToken` exists, use it as the device-auth token.
- Otherwise fall back to `gateway.authToken` and warn.

See `src/main_node.zig`:

- `device_auth_token = if (cfg.node.nodeToken.len > 0) cfg.node.nodeToken else cfg.gateway.authToken;`

And `src/main_node.zig` comment:

- `Device-auth signed payload should use the paired node token when available.`

TODO (confirm):

- Exact JSON shape of the device-auth payload (field names + where it appears on the wire).
- How the gateway validates it (ordering, algorithm, replay window).

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
3. Exact device-auth payload schema + where it is attached (connect vs subsequent auth frame).
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
