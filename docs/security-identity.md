# Device identity

Each machine has one device identity: one X25519 key and one id. Lattices uses
that key for every role that needs a key. Before this change, each role kept
its own key file.

## The file

`~/.lattices/identity/device.json`, mode 0600, in a 0700 directory:

```json
{"version":1,"id":"<uuid>","name":"<host>","privateKey":{"kty":"OKP","crv":"X25519","x":"…","d":"…"}}
```

Two modules read and write this file. Their behavior must stay the same:

- `packages/desktop-client/device-identity.ts` (CLI, gateway, Linux host)
- `apps/mac/Sources/Core/System/DeviceIdentity.swift` (Mac app)

A reader accepts the file only if all of these are true:

- it is a regular file with one link, opened without following a symlink;
- the current user owns it;
- its mode gives no access to group or other;
- it is 64 KB or smaller;
- `x` is the public key of `d`.

If the file is unsafe or malformed, the reader stops with an error. It must not
replace the file. The Mac app then uses a key for the current session only and
writes a warning to the diagnostic log. Peers must re-pair with that session.

A writer creates the file once. It writes a private temporary file and
hard-links it into place. If the link fails because the file exists, another
process created the identity first, and the writer reads that file. The CLI
and the app can start at the same time and still agree on one key.

## Key map

| Role | Before | Now | Who pins the public key |
| --- | --- | --- | --- |
| Gateway server | `gateway/gateway-key.json` (JWK) | device key | gateway clients, in their `paired-hosts.json` |
| Gateway client | `client.json` (id, name, JWK) | device key and id | remote gateways, in `gateway/gateway-clients.json` |
| Mac companion bridge | `companion/bridge.key` (raw 32 bytes); older builds used a Keychain item | device key | the iPad, and Macs that visit this Mac |
| Linux companion bridge | `host/bridge-key.json` (JWK) | device key | the iPad, and Macs that visit this host |
| Visit client | `visit/device-key` (raw 32 bytes) | device key | the bridges this Mac visits |

These stay separate:

| Item | Reason |
| --- | --- |
| The iPad key (`DeckBridgeSecurityStore`) | The iPad is a separate device with its own identity. |
| The Talkie local client key (P-256 signing, Keychain) | The Talkie protocol requires P-256 ECDSA. An X25519 key cannot sign. |
| The `visit-test` key (`--identity`) | The test tool simulates a second device. |
| Trust records: `gateway/gateway-clients.json`, `host/bridge-devices.json`, the companion trusted-device list, `visit/hosts.json`, `paired-hosts.json` | They hold peers' keys, not this machine's key. |

## Why one key is safe

All roles use the same primitives: X25519 key agreement, HKDF-SHA256 with salt
`lattices-bridge-v1`, an HMAC-SHA256 request signature, and ChaChaPoly for
encrypted bodies. Reuse of one key across these roles does not let a peer
replay a message into another role:

- Each signature covers the method, path, device id, timestamp, nonce and body
  hash.
- Each encrypted body uses a distinct AAD for its direction (`request`,
  `response`, `visit`).
- Each trust store is keyed by the peer's id and grants only its own scopes.
  A gateway pairing does not grant companion access, and a companion pairing
  does not grant gateway access.

Role ids must stay distinct. The gateway client id comes from the identity.
The visit device id stays in `visit/hosts.json`. Do not merge these ids.

The fingerprint is the same in every view: the first 12 hex digits of SHA-256
over the base64 public key, as `XXXX-XXXX-XXXX`. The Mac bridge fingerprint in
Companion settings and the visit code in Machines now show the same value.

## Migration

The first process that needs the identity creates it from the old files. It
selects the first key that it can read, in this order:

1. `gateway/gateway-key.json`, only if `gateway/gateway-clients.json` lists at
   least one client;
2. `companion/bridge.key`;
3. `host/bridge-key.json`;
4. `gateway/gateway-key.json`;
5. the key in `client.json`;
6. `visit/device-key`.

If no file has a usable key, the process generates a new key. The id and name
come from `client.json` if it is valid. If not, the id is a new UUID and the
name is the host name.

The order keeps the key that the most peers pin. A gateway key that no client
pinned has no value, so the companion key comes before it. The iPad cannot
re-pair without a person at the device, so the companion key comes before the
client and visit keys.

After the link succeeds, the process deletes the five old key files. It keeps
`gateway/gateway-clients.json`. The Keychain item from old Mac builds is not
read and not deleted.

### Effect on peers

Peers that pinned the adopted key continue to work. Peers that pinned another
old key must re-pair once.

| Machine | Kept | Re-pair |
| --- | --- | --- |
| Mac with no gateway clients | companion key: the iPad and visiting Macs continue | this Mac's own gateway pairings (`lats hosts pair`) and visit pairings |
| Mac with gateway clients | gateway key: its gateway clients continue | the iPad, visiting Macs, and this Mac's own outgoing pairings |
| Linux host (archie) with gateway clients | gateway key: its gateway clients continue | the iPad, Macs that visit the bridge, and its own outgoing pairings |
| Linux host with no gateway clients | bridge key: the iPad and visiting Macs continue | its own outgoing pairings |

### Mixed versions

An old build does not read `device.json`. If an old build runs after the
migration, it creates new per-role key files with new keys. Peers that pair
with that build pin keys that the new build deletes or ignores. Update the CLI,
the gateway and the app on a machine together, and restart all three.

## Related

LAT-014 (paired Macs) proposes a P-256 TLS identity in the Keychain. That
proposal is not built. If it is built, it should explain why it cannot use the
device identity.
