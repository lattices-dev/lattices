# Ply desktop companion

Ply is a small, draggable workspace shortcut. Click the creature, pick a
Lattices workspace, and Ply switches to it using the workspace’s saved layout.
The current workspace has a checkmark. Ply thinks while reading, arranges
while switching, smiles after confirmation, and looks puzzled on failure.

## Try it

With the Lattices app running, from the repository root:

```sh
experiments/ply-desktop/script/build_and_run.sh --verify
```

1. Click Ply on the desktop. The **Where to?** popover lists your workspaces.
2. Choose a workspace. Switching uses `layers.activate` with `mode: focus`,
   the same semantics as a Lattices workspace switch, including its saved layout.
3. Look for **Now in …** and the updated **Here** marker. Scroll for more rows.
4. Use **Refresh** if you change workspaces elsewhere while the picker is open.
5. Close the picker with its close button or a click outside it.

Drag Ply to move it. Right-click for **Say hello**, size, expression, hide,
and quit. The menu bar also has **Switch workspace…**, so the picker remains
reachable when the companion is hidden. Reduced Motion disables the bounce.

The build script records the absolute repository and Bun paths in the local
app bundle. Rebuild after moving the checkout or changing Bun’s location.
The app reuses the existing atlas; there are no new artwork assets or packages.

## Why this job

Three behaviours were considered:

- **Agent lookout:** show projects with agent terminals open. `terminals.search`
  identifies Claude processes, but presence does not distinguish working,
  waiting for input, or idle. The live sample also lacked window targets.
- **Input nudge:** show explicit Scout approval requests. This needs a current
  attention feed; aggregate attention and historical failures are insufficient.
- **Workspace shortcut (implemented):** a useful click target backed by
  Lattices’ existing workspace read and activation APIs.

Action’s `layer list` was also inspected. A connected agent display can exist
without an active task, so it is not used as a work-in-progress signal.

## Read and action policy

Ply performs **no background polling** and makes no startup requests. Opening
the picker or pressing Refresh calls `bun bin/lattices.ts call layers.list '{}'`.
The standard CLI owns private socket authentication; Ply does not copy tokens
or create another transport. The CLI also checks daemon availability.

A workspace selection calls `layers.activate` by stable ID with `mode: focus`,
then reads `layers.list` once to confirm the active workspace. It does not use
launch mode. Success means the daemon accepted the action and reports that
workspace active; it is not a claim that every configured app is running.

Reads run off the main thread. Repeated refreshes are coalesced, including
close/reopen during a slow request. Commands have a 20-second deadline and a
1 MiB output limit. Controls are disabled during an operation. Failures remove
stale results and offer explicit Refresh; a failed switch is never retried
automatically. Closing the picker discards late read results. An explicitly
requested switch is allowed to finish if the picker closes.

The picker shows a snapshot, not a live agent dashboard. It has no continuous
animation, notification permission, agent messaging, or model/API usage.

## Verification

```sh
swift test --package-path experiments/ply-desktop
experiments/ply-desktop/script/build_and_run.sh --self-test
experiments/ply-desktop/script/build_and_run.sh --verify
```

The Swift tests cover drag/placement/artwork, passive startup, current-layer
semantics, stable IDs, switch verification, invalid responses, explicit
recovery, stale reads, overlapping refreshes, large CLI output, and a hung
CLI process. Native self-checks use an empty fixture and isolated preferences;
they do not change the user’s workspace. The report is `dist/self-check.json`.

Live acceptance on November 16, 2026: opened the installed picker, inspected
the current marker and footer, switched from `usetalkie.com` to `Lattices`,
confirmed both UI feedback and daemon state, then switched back through Ply.
