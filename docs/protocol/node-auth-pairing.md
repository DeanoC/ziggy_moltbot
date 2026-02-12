# Gateway WS auth + pairing fields (client mirror)

Status: **current (mirrors OpenClaw gateway behavior for ZiggyStarClaw clients)**.

This doc is a client-side mirror of the gateway’s WebSocket auth + pairing fields, with ZiggyStarClaw code pointers and a copy-paste payload builder example.

---

## Gateway source-of-truth (server-side)

- OpenClaw `docs/gateway/protocol.md`
- OpenClaw `src/gateway/protocol/schema/frames.ts` (`ConnectParamsSchema`, `HelloOkSchema`)
- OpenClaw `src/gateway/protocol/schema/devices.ts` (`DevicePair*` schemas)
- OpenClaw `src/gateway/device-auth.ts` (`buildDeviceAuthPayload`)
- OpenClaw `src/gateway/server/ws-connection.ts` (`connect.challenge` emit)
- OpenClaw `src/gateway/server/ws-connection/message-handler.ts` (nonce/signature/timestamp validation + pairing gate)

## ZiggyStarClaw source pointers (client-side)

- `src/client/websocket_client.zig`
  - `buildHeaders()` (WS `Authorization` header)
  - `parseConnectNonce()` / `handleConnectChallenge()`
  - `sendConnectRequest()` (`connect.params.auth` + `connect.params.device`)
  - `buildDeviceAuthPayload()` (payload string shape)
- `src/protocol/gateway.zig` (`ConnectAuth`, `DeviceAuth`, `ConnectParams`)
- `src/client/device_identity.zig` (`signPayload()`)
- `src/node/connection_manager_singlethread.zig` (node token invariants)
- `src/main_node.zig` (node-mode connect + token persistence/reconnect)
- `src/node_register.zig` (bootstrap pairing flow, save `node.nodeToken`)

---

## 1) Token placement (what goes where)

- **WS handshake header**: `Authorization: Bearer <token>`
- **First WS req (`method: "connect"`)**: `params.auth.token`
- **Signed device-auth payload**: includes token as one of the signed fields

For node-mode in ZiggyStarClaw, keep these aligned to the same token for predictable gateway behavior.

Typical lifecycle:

1. First run: shared `gateway.authToken` is used.
2. After approval: gateway returns `hello-ok.auth.deviceToken`.
3. Client persists token to `node.nodeToken` and reconnects with that token.

---

## 2) `connect` auth + device fields (field-level)

Relevant connect params and behavior:

| Field path | Required | Notes |
|---|---:|---|
| `params.auth.token` | optional in schema | Required when gateway shared-token auth is enabled; also used in device signature payload binding. |
| `params.device.id` | required for device-auth path | Must match hash-derived ID from `device.publicKey`; mismatch rejected. |
| `params.device.publicKey` | required for device-auth path | Base64url public key used to verify signature. |
| `params.device.signature` | required for device-auth path | Signature over `buildDeviceAuthPayload(...)` bytes. |
| `params.device.signedAt` | required for device-auth path | Must be fresh (gateway enforces skew window, currently ~±10 min). |
| `params.device.nonce` | required for non-local | Must match server `connect.challenge.payload.nonce` for non-local clients. |
| `params.role` + `params.scopes[]` | optional in schema | Included in signature payload; requesting new role/scopes can require re-pairing approval. |

Handshake notes:

- Gateway sends pre-connect event: `connect.challenge` with `{ nonce, ts }`.
- Non-local clients must sign nonce-bound payload (`v2`).
- Local/loopback can still be accepted with legacy nonce-less payload (`v1`) in compatibility paths.

---

## 3) Device pairing fields (events + methods)

Schemas are in OpenClaw `src/gateway/protocol/schema/devices.ts`.

### 3.1 Methods

- `device.pair.list`: `{}`
- `device.pair.approve`: `{ requestId: string }`
- `device.pair.reject`: `{ requestId: string }`

### 3.2 Events

`device.pair.requested` payload:

- `requestId: string`
- `deviceId: string`
- `publicKey: string`
- `displayName?: string`
- `platform?: string`
- `clientId?: string`
- `clientMode?: string`
- `role?: string`
- `roles?: string[]`
- `scopes?: string[]`
- `remoteIp?: string`
- `silent?: boolean`
- `isRepair?: boolean`
- `ts: number`

`device.pair.resolved` payload:

- `requestId: string`
- `deviceId: string`
- `decision: string` (`approved` / `rejected` / `expired`)
- `ts: number`

When pairing is required during connect, gateway responds with an error like:

- `error.code = not_paired`
- `error.message = "pairing required"`
- `error.details.requestId = <request id>`

---

## 4) Device-auth payload format (exact)

Gateway payload builder (OpenClaw `src/gateway/device-auth.ts`):

- Base fields:
  - `version|deviceId|clientId|clientMode|role|scopesCsv|signedAtMs|token`
- Nonce-bound (`v2`) appends:
  - `|nonce`

Where:

- `version = "v2"` when nonce exists, else `"v1"`
- `scopesCsv = scopes.join(",")`
- `token = params.auth.token` (or empty string if omitted)

---

## 5) Example payload builder (Zig, client-side)

```zig
fn buildDeviceAuthPayload(allocator: std.mem.Allocator, params: struct {
    device_id: []const u8,
    client_id: []const u8,
    client_mode: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    signed_at_ms: i64,
    token: []const u8,
    nonce: ?[]const u8 = null,
}) ![]u8 {
    const scopes_joined = try std.mem.join(allocator, ",", params.scopes);
    defer allocator.free(scopes_joined);

    const version: []const u8 = if (params.nonce != null) "v2" else "v1";
    if (params.nonce) |nonce| {
        return std.fmt.allocPrint(
            allocator,
            "{s}|{s}|{s}|{s}|{s}|{s}|{d}|{s}|{s}",
            .{
                version,
                params.device_id,
                params.client_id,
                params.client_mode,
                params.role,
                scopes_joined,
                params.signed_at_ms,
                params.token,
                nonce,
            },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}|{s}|{s}|{s}|{d}|{s}",
        .{
            version,
            params.device_id,
            params.client_id,
            params.client_mode,
            params.role,
            scopes_joined,
            params.signed_at_ms,
            params.token,
        },
    );
}
```

Usage sketch:

1. Build payload with connect fields (including `token`, and `nonce` when present).
2. Sign bytes via `device_identity.signPayload(...)`.
3. Send signature/public key/device id in `connect.params.device`.

---

## 6) Ziggy implementation notes to keep in sync

- If nonce arrives (`connect.challenge`), sign/send v2 payload with nonce.
- If no nonce arrives within grace window, client may send v1 payload (gateway may reject non-local).
- Keep node-mode token usage consistent across:
  - WS `Authorization`
  - `connect.params.auth.token`
  - token field inside signed payload
- On `hello-ok.auth.deviceToken`, persist and reconnect so role/scopes are enforced with paired token.
