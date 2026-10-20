# Lattices gateway

The gateway is an optional per-user process for remote access. Product runtimes
listen on private Unix sockets. Starting Lattices, Action, Canvas, or Speech does
not start the gateway.

```sh
lats gateway start --tailnet
lats gateway status
lats gateway clients
lats gateway approve CLIENT_ID
lats gateway revoke CLIENT_ID
lats gateway stop
```

`run --tailnet` runs in the foreground. `start` runs in the background until
stopped; it does not install a login or boot service. Logs and gateway trust
records live in `~/.lattices/gateway`. The metadata audit log is capped at 10 MiB
and starts a fresh log when full. Product request parameters are not logged.

The current transport requires Tailscale. The gateway binds only its verified
Tailscale IP, with WireGuard protecting network traffic. It rejects loopback
identity, browser Origin headers, unexpected Host headers, unapproved users and
tags, invalid signatures, replayed upgrades, and revoked clients. There is no
wildcard, ordinary LAN, unauthenticated, or automatic network fallback. `--port`
defaults to 9399; `--allow-user` and `--allow-tag` select allowed tailnet peers.
The default admits devices owned by the host's Tailscale user.

From another tailnet machine, `lats --host HOST pair --read-only` asks the local
operator to approve core read access. Check the fingerprint and requested grants
with `lats gateway clients` before approval. `act` adds workspace mutations;
`drive` adds desktop input and app/session launching, including layer activation
because its launch mode can start sessions. These shorthand scopes
cover only Lattices. Existing direct-host pairings must pair with the gateway
because it has a separate key and trust store.

Every stored grant names one exact `product:method`. Pairing requests may provide
an explicit `grants` array instead of a scope. The CLI supplies it with repeated
flags: `lats --host HOST pair --grant action:status --grant speech:speech.enqueue`.
New capabilities require another
local approval. Core RPC method names remain unchanged; other products use
`gateway.call` with `{ "product": "speech", "method": "speech.enqueue", "params": {} }`.
Only the reviewed operations in `src/policy.ts` can be granted. Remote clients
cannot select socket paths, request local administration, or invoke unknown
methods. The gateway reports an unavailable product without starting it.

Canvas requests use `product: "canvas"`; the legacy `"blink"` name remains
accepted. A requested grant such as `canvas:notes.list` is normalized to the
existing `blink:notes.list` identity before local approval and storage. Existing
Blink grants continue to authorize only those same exact methods, with no new
operations or cross-product access added by the rename.

Core event subscriptions require both an event subscription grant and the read
grant for each selected event. Raw computer action events, Canvas event streams,
Speech's native playback reservation, and the separate VNC `capture.live`
listener remain local. Action's connection-owned `drive.begin`, `drive.touch`,
`drive.release`, `workspace.dragFile` and `workspace.cancelOperation` also stay
local: the gateway opens one product connection per call. `drive.status` remains
available with its own read grant. Remote visits use the authenticated companion relay.

The companion uses the same gateway port and its existing signed paths,
including `/visit`. The gateway checks tailnet identity and relays to private
`companion.sock`; the companion retains device pairing, signatures, encrypted
payloads, and device revocation. Configure the gateway address explicitly:
private companion runtimes no longer advertise Bonjour or open port 5287.
Companion device trust and gateway RPC client trust remain separate.

Local control uses `~/.lattices/run/gateway.sock` with a private token. Other
products use their own sockets and tokens in that directory; Canvas retains
`~/Library/Application Support/Blink/blink.sock`. `CANVAS_HOME` overrides that
socket's directory, with `BLINK_HOME` supported as a fallback. Remote requests
cannot set either variable. `LATTICES_RUNTIME_DIR` changes the runtime directory
for all participating processes, principally for isolated tests.

Run source checks with `bun run check:types` from the repository root and gateway
tests with `bun test packages/gateway/test/gateway.test.ts`. Tests use ephemeral
listeners and private fixture sockets; they do not start installed products or
enable the production gateway.
