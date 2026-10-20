# Action with a remote Linux host

Action can observe and act on a Linux desktop running `lattices-host`. Runs, traces and artifacts stay on the controller; the remote host performs the work.

## Prerequisites

- A reachable Linux desktop with `lattices-host` installed and configured.
- An Action runtime that includes `RemoteEngine` support, plus Bun on the controller.
- The host's address and an approved pairing for this controller.

The macOS app installer does not provision a Linux host. See the [Linux host source and setup](https://github.com/arach/lattices/tree/main/packages/host-linux) before continuing. Match setup instructions to the revision you install; the homepage demo is not a Linux acceptance test.

## Pair through the gateway

Use Lattices 0.15.0 with Action 0.4.0 and a host at the same Lattices version. Earlier versions use direct-host transport; see [Runtime versions](/lattices/docs/concepts#private-ipc-and-the-gateway).

Start the local host on the Linux desktop, then start its gateway:

```sh
lats gateway start --tailnet
```

Expect the gateway to bind the host's Tailscale address. Both machines need Tailscale. The default policy admits devices owned by the host's Tailscale user. The gateway runs until stopped; this command does not install a login service.

On the controller, request read-only access:

```sh
lats --host your-linux-host pair --read-only
```

The command waits for approval. On the Linux host, inspect the request and compare its fingerprint with the controller's code. Replace `CLIENT_ID` with the matching pending client:

```sh
lats gateway clients
lats gateway approve CLIENT_ID
```

After the controller reports that it is paired, verify the destination:

```sh
lats --host your-linux-host call host.describe
```

Expect the intended Linux hostname, platform, and capabilities. Stop if the identity differs. Existing direct-host pairings do not grant gateway access; pair again because the gateway has its own key and trust store.

Read-only access is enough for this check and Action's health check below. Desktop input and app launching require a separate request with `lats --host your-linux-host pair --drive`, followed by host approval of the expanded grants. The `--drive` scope covers Lattices host operations used by `RemoteEngine`. It does not grant access to the separate Action agent. Review [Gateway permissions](/lattices/docs/concepts#private-ipc-and-the-gateway) before approving control.

## Connect the MCP runtime

From the Action product directory in a runtime or checkout with remote-engine support, replace `your-linux-host` with the paired gateway host name:

```sh
ACTION_REMOTE_HOST=your-linux-host bun packages/mcp/src/index.ts
```

For an MCP harness, set `ACTION_REMOTE_HOST` in the server environment rather than relying on the environment of an unrelated terminal. A custom port uses `host:port`.

Ask the agent to call `action.health` first. Expect the remote host's platform and capabilities in `diagnostics`. Stop if it reports the wrong host or a connection error.

The runtime supports host snapshots and OCR, point/text target resolution, and input actions supported by that host. Native macOS Accessibility, stage/backdrop overlays, and the companion worker are not available on Linux. `action.record.*` remains native-only; guided sessions use the remote engine's recording path instead.

Implementation reference: [Remote engine](https://github.com/arach/lattices/blob/main/products/action/docs/remote-engine.md).
