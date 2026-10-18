# Action with a remote Linux host

Action can observe and act on a Linux desktop running `lattices-host`. Runs, traces and artifacts stay on the controller; the remote host performs the work.

## Prerequisites

- A reachable Linux desktop with `lattices-host` installed and configured.
- An Action runtime that includes `RemoteEngine` support, plus Bun on the controller.
- The host's address and any required host-pairing setup. Do not expose the host service to the public internet.

The macOS app installer does not provision a Linux host. See the [Linux host source and setup](https://github.com/arach/lattices/tree/main/packages/host-linux) before continuing. Match setup instructions to the revision you install; the homepage demo is not a Linux acceptance test.

## Connect the MCP runtime

From the Action product directory in a runtime or checkout with remote-engine support, replace `your-linux-host` with the reachable host name:

```sh
ACTION_REMOTE_HOST=your-linux-host bun packages/mcp/src/index.ts
```

For an MCP harness, set `ACTION_REMOTE_HOST` in the server environment rather than relying on the environment of an unrelated terminal. A custom port uses `host:port`.

Ask the agent to call `action.health` first. Expect the remote host's platform and capabilities in `diagnostics`. Stop if it reports the wrong host or a connection error.

The runtime supports host snapshots and OCR, point/text target resolution, and input actions supported by that host. Native macOS Accessibility, stage/backdrop overlays, and the companion worker are not available on Linux. `action.record.*` remains native-only; guided sessions use the remote engine's recording path instead.

Implementation reference: [Remote engine](https://github.com/arach/lattices/blob/main/products/action/docs/remote-engine.md).
