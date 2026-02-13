# Gateway WS auth + pairing fields (client mirror)

Status: **current** (mirrors OpenClaw gateway docs + protocol schemas for ZiggyStarClaw clients).

This is the ZiggyStarClaw client-side mirror of Gateway WebSocket auth/pairing fields, with code pointers and an example payload builder.

---

## Upstream docs reviewed (OpenClaw)

- `openclaw-fork/docs/gateway/protocol.md`
- `openclaw-fork/docs/gateway/pairing.md`
- `openclaw-fork/docs/web/control-ui.md` (pairing-required UX)

Field-level schema sources used for exact names:

- `openclaw-fork/src/gateway/protocol/schema/frames.ts`
- `openclaw-fork/src/gateway/protocol/schema/devices.ts`
- `openclaw-fork/src/gateway/protocol/schema/nodes.ts`
- `openclaw-fork/src/gateway/device-auth.ts`
- `openclaw-fork/src/infra/device-pairing.ts`
- `openclaw-fork/src/infra/node-pairing.ts`

---

## ZiggyStarClaw code pointers (where these fields are used)

### Connect/auth/device signature flow

- `src/client/websocket_client.zig`
  - `buildHeaders()` → WS `Authorization: Bearer <token>`
  - `parseConnectNonce()` / `handleConnectChallenge()` → `connect.challenge` nonce handling
  - `sendConnectRequest()` → sends `connect.params.auth` + `connect.params.device`
  - delegates exact `v1`/`v2` signed payload string building to `protocol/ws_auth_pairing.zig`
- `src/protocol/gateway.zig` (`ConnectAuth`, `DeviceAuth`, `ConnectParams`)
- `src/protocol/ws_auth_pairing.zig` (mirrored field structs + payload/example builders)
- `src/client/device_identity.zig`
  - `signPayload()` → Ed25519 signature for device-auth payload
- `src/client/event_handler.zig`
  - `extractAuthUpdate()` → reads `hello-ok.auth.deviceToken`, `role`, `scopes`, `issuedAtMs`
- `src/node/connection_manager_singlethread.zig` (node token invariants)

### Pairing flows

- `src/cli/operator_chunk.zig`
  - `device.pair.list`
  - `device.pair.approve` / `device.pair.reject`
- `src/main_node.zig`
  - handles `device.pair.requested` / `device.pair.resolved`
  - handles `node.pair.requested` / `node.pair.resolved`
  - persists paired token from `hello-ok.auth.deviceToken`, then reconnects
- `src/node_register.zig` (bootstrap pairing flow, save `node.nodeToken`)

---

## 1) WS auth fields (connect handshake)

### `connect.challenge` event payload (Gateway -> client)

| Field | Type | Notes |
|---|---|---|
| `payload.nonce` | string | Challenge nonce for non-local clients (required in v2 signature payload). |
| `payload.ts` | integer | Gateway timestamp (ms). |

### `connect` request params (client -> Gateway)

| Field path | Type | Notes |
|---|---|---|
| `params.auth.token` | string? | Shared token / device token path; also bound into signed device-auth payload. |
| `params.auth.password` | string? | Password mode alternative. |
| `params.role` | string? | Requested role (`operator` / `node`) used in pairing checks. |
| `params.scopes[]` | string[]? | Requested operator scopes; scope upgrades can trigger re-pairing. |
| `params.device.id` | string | Device identity ID (fingerprint-derived). |
| `params.device.publicKey` | string | Device public key used for signature verification. |
| `params.device.signature` | string | Signature over `buildDeviceAuthPayload(...)` bytes. |
| `params.device.signedAt` | integer | Signature timestamp (freshness checked server-side). |
| `params.device.nonce` | string? | Nonce from `connect.challenge` (required for non-local device-auth path). |

### `hello-ok.auth` payload (Gateway -> client)

| Field | Type | Notes |
|---|---|---|
| `auth.deviceToken` | string | Issued paired token for this device/role/scopes. |
| `auth.role` | string | Role associated with issued token. |
| `auth.scopes` | string[] | Scopes associated with issued token. |
| `auth.issuedAtMs` | integer? | Optional token issue timestamp. |

Token placement rule (important in Ziggy node-mode):

1. WS header bearer token
2. `connect.params.auth.token`
3. token field inside signed device-auth payload

Keep these aligned to avoid role/token mismatches.

---

## 2) Pairing fields

### 2.1 Device pairing (WS device identity path)

Methods:

- `device.pair.list`: `{}`
- `device.pair.approve`: `{ requestId: string }`
- `device.pair.reject`: `{ requestId: string }`

Events:

`device.pair.requested` payload fields:

- `requestId`, `deviceId`, `publicKey`, `ts`
- optional: `displayName`, `platform`, `clientId`, `clientMode`, `role`, `roles[]`, `scopes[]`, `remoteIp`, `silent`, `isRepair`

`device.pair.resolved` payload fields:

- `requestId`, `deviceId`, `decision`, `ts`

Common connect failure shape when pairing is required:

- `error.code = "not_paired"`
- `error.message = "pairing required"`
- `error.details.requestId = <id>`

### 2.2 Node pairing (`node.pair.*`, separate store)

From OpenClaw pairing docs: node pairing is separate from the WS `connect` device-auth gate.

Methods:

- `node.pair.request`: `{ nodeId, displayName?, platform?, version?, coreVersion?, uiVersion?, deviceFamily?, modelIdentifier?, caps[]?, commands[]?, remoteIp?, silent? }`
- `node.pair.list`: `{}`
- `node.pair.approve`: `{ requestId }`
- `node.pair.reject`: `{ requestId }`
- `node.pair.verify`: `{ nodeId, token }`

Events:

- `node.pair.requested` (pending request fields, includes `requestId`, `nodeId`, metadata, optional `silent`, optional `isRepair`, `ts`)
- `node.pair.resolved` (`requestId`, `nodeId`, `decision`, `ts`)

Operational notes mirrored from OpenClaw docs:

- pending pairing TTL is 5 minutes
- approval rotates/creates a fresh token
- repeated request is idempotent per node while pending

---

## 3) Device-auth payload format (exact mirror)

OpenClaw builder source: `openclaw-fork/src/gateway/device-auth.ts`

Signed payload fields:

- base: `version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token`
- v2 adds: `|nonce`

Rules:

- `version = "v2"` when nonce exists, else `"v1"`
- `scopesCsv = scopes.join(",")`
- `token = params.auth.token` (empty string if omitted)

---

## 4) Example payload builder (Zig)

Implemented utility: `src/protocol/ws_auth_pairing.zig`

- `buildDeviceAuthPayload(...)` → exact OpenClaw-compatible signature payload string
- `buildExamplePayloadBundle(...)` → ready-to-print JSON examples for:
  - `connect`
  - `node.pair.request`
  - `device.pair.approve`
  - `device.pair.reject`

Runnable example: `examples/ws_auth_pairing_payload_builder.zig`

It provides:

- `buildDeviceAuthPayload(...)`
- `buildConnectRequestJson(...)`
- `buildDevicePairApproveParamsJson(...)`
- `buildNodePairRequestParamsJson(...)`

Run:

```bash
./.tools/zig-0.15.2/zig run examples/ws_auth_pairing_payload_builder.zig
```

For production connect flows:

1. Build device-auth payload with `buildDeviceAuthPayload(...)` (include nonce when present).
2. Sign bytes via `device_identity.signPayload(...)`.
3. Send signature/public key/device id in `connect.params.device`.

---

## 5) Sync checklist for future updates

When OpenClaw auth/pairing changes, verify these Ziggy spots together:

- `src/client/websocket_client.zig` (connect + signature payload)
- `src/client/event_handler.zig` (`hello-ok.auth` parsing)
- `src/main_node.zig` + `src/node_register.zig` (pairing event handling + token persistence)
- this mirror doc + example builder
