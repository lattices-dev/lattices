# Cluster verbs

The user's number one priority is managing several hosts: "I have ... four
[hosts] in a cluster ... two main keyboards". They want convenience functions
like "bring everything to the DELL" and "make the Dell main", in both the CLI
and the app.

## The setup

| Machine | OS | Keyboard | Role |
|---|---|---|---|
| mini (this Mac) | macOS | yes | drives the others; Dell (main) + U32 (elsewhere) |
| arts-mini | macOS | yes | drives the others; probably on the U32's other input |
| Archie | Linux / Hyprland | no | visited (`packages/host-linux`) |
| air | macOS (MacBook Air) | no | visited |

Both keyboards are on Macs. So every Mac sends and receives visits (both
sides exist in the app now: `VisitController` sends, `MacVisitHost` receives),
and Archie only receives. Lattices hosts are in `~/.lattices/hosts.json`
(`lats hosts`, `bin/hosts.ts`, `callHost`). Visit pairing is per direction:
see `docs/visit.md`.

## 1. One CLI for every host

- `lats @<host> <command...>` runs a lats command against another host's
  daemon. `lats @archie display list` is the same as running `lats display list`
  there. Route through the host's daemon API (`callHost`), not ssh. Any
  subcommand that's a thin wrapper over a daemon call should work remotely; the
  rest should say they're local-only. `@local` is this machine.
- `lats machines` lists every machine on one screen. It merges hosts.json,
  visit pairings and the local machine. For each it shows: reachable, Lattices
  version/commit (`host.describe` already reports build identity on Linux; add
  it on the Mac if it's missing), OS, display count, whether it's paired to
  receive visits from here, and where it's placed. `--json` too.

## 2. Convenience verbs

Short commands for the things the user does by hand, each a daemon method so
it works with `@host` and from the app. They build on what exists: don't
duplicate `display.gather`, `visit.main`, etc. Alias or compose them.

- `lats bring <display>`: every window from every other display onto this one
  (`display.gather` for each). "bring everything to the DELL" =
  `lats bring dell`. `lats bring --undo` restores.
- `lats main <display>`: make it the main display (the existing `visit.main`
  15s trial). `--keep` keeps it at once.
- `lats elsewhere <display> [machine]` / `lats here <display>`: top-level
  aliases of the `visit` ones.
- `lats visit <machine>`: start a visit now without pushing against an edge
  (enter at the middle of its touching span). `lats home` ends it (alias of
  `mouse home`).
- Displays are named by number or by any part of their name, case-insensitive
  (`dell`, `u32`), everywhere a display is taken. Use the same resolver as
  `display.gather`.

Add them to `bin/cli/usage.ts` in one "Machines and displays" group, and to
`docs/api.md`.

## 3. The app

- **Machines page**:
  - Per display: Bring everything here, Make main, Elsewhere.
  - Per machine: Visit now; reachability with version/commit, flagged when it's
    behind this Mac's; Open (the existing still/live view).
  - Keep row geometry equal; coral only for live state; no explainer copy.
- **Command bar** (`Core/Overlays/UnifiedCommandBar`): the same verbs as
  commands, e.g. "Bring everything to DELL", "Make U32 main", "Visit archie",
  generated from the current displays and machines.
- **Menu bar**: a Machines submenu with Visit <machine> for each paired one,
  and Bring everything to <display> for each display.

## Out of scope

Deploying to or configuring arts-mini, air or Archie. I'll do that with the
user. Don't ssh anywhere and make no calls to real hosts.

## Constraints

- Work in this worktree (`feat/machines-tab`, pushed; don't push).
- Don't launch, quit or restart the running app.
- No real display, pairing, arming or window changes while developing; tests use
  mocks/injection (see the existing `MachinesTests`, `tests/machines-cli.test.ts`).
- `cd apps/mac && swift build -c release`, Swift tests, bun tests and
  `bun run check:types` pass.
- Gitmoji on every commit, small focused commits, no co-author lines or footers.
  Bun only.
- Report to `~/.cache/cluster-verbs-report.md`.
