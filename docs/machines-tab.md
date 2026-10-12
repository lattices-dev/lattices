# Machines tab

A page in the app's Workspace group, beside Overview and Layers, for the
machines around this Mac: where each one sits, and whether the cursor and
keyboard can go there.

## Starting point

This branch (`feat/machines-tab`) is `feat/visiting-cursor` plus the Hosts page
commit cherry-picked from `origin/feat/hosts-page` (never merged). The Hosts page
already lists `~/.lattices/hosts.json` hosts with a live still and window list
(`AppShell/HostsPageView.swift`, `Core/Hosts/RemoteHostsModel.swift`,
`Core/Hosts/RemoteHostConnection.swift`). Grow that page into this one rather
than adding a second page: rename the case to `machines` (title "Machines",
SF Symbol of your choice), keep `hosts` working through `AppPage.named`, and keep
the still and window list as the detail for a selected machine.

## What it shows

One list of machines, merged by name/address across the sources:

- **Visit hosts**: `VisitTrust.shared.list()` (name, address, side, bridge
  fingerprint). Paired over the authenticated bridge; see `docs/visit.md`.
- **Lattices hosts**: `~/.lattices/hosts.json` / `LATTICES_HOSTS` (the existing
  Hosts page model).
- **This Mac's displays**: `VisitController.screens()` with the elsewhere mark
  (`visit.elsewhere` in UserDefaults). A display marked elsewhere is plugged into
  another machine; the pointer stays off it.

Per machine: name, address, reachable or not, paired or not, which side it sits
on, visiting now or not. Status is read on page appear and on
`VisitController.changed`; nothing polls while the page is hidden (the Hosts page
already follows this rule, keep it).

## What it does

- **Arrangement.** A small spatial map: this Mac's displays drawn at their real
  proportions (from `screens()`), elsewhere displays drawn dim, and each paired
  machine as a tile you drag to a side (left/right/top/bottom; one machine per
  side, as `VisitTrust` enforces with `host(on:)`). Dropping it re-pairs or
  updates the side. `VisitTrust` has no "set side" yet: add one rather than
  forgetting and re-pairing, since that would need the host's pairing code again.
- **Connect / disconnect.**
  - The visiting cursor: arm/disarm (`VisitController.shared.arm(_:)`), end a
    visit (`end(because:)`), pair (`VisitTrust.pair(name:address:side:)`;
    needs the host's code, so it's a small sheet), forget (`forget(_:)`).
- **Displays.** Toggle here/elsewhere per display, including the main one
  (`VisitController.shared.setElsewhere(_:_:)`). Optionally pick which machine an
  elsewhere display shows; store it next to the mark. It's display only for
  now, with no behaviour.

Every action the page takes should also exist on the daemon API and the CLI,
so agents and `lats` can do the same thing. Already there: `visit.status`,
`visit.pair`, `visit.arm`, `visit.end`, `visit.screens`, `visit.elsewhere`
(`Core/Daemon/LatticesApi.swift`), and `lats visit ...` (`bin/lattices.ts`,
usage in `bin/cli/usage.ts`). Also available: `visit.forget` and `visit.side`.

## Style

- HudsonUI primitives for structure; native `Typo` / `Palette` for type and
  colour (see `Core/Overlays/Long/LongCard.swift` for the current controls).
- Coral `#ef6a47` (`Long.coral`) is the only accent, and only for live state:
  visiting now. Everything else uses text dim levels. No green.
- No explainer copy that restates the UI. Tight labels; the layout does the work.
- Rows have equal geometry whatever their state (reserve columns; don't let a
  row grow when a badge appears).
- Passive by default: opening the page never starts a visit.

## Constraints

- Build: `cd apps/mac && swift build -c release`. Add tests under
  `apps/mac/Tests/` for any new pure logic (merging sources, side assignment).
- Don't launch, quit or restart the running Lattices app, and don't touch
  `~/dev/lattices` or `~/dev/lattices-main`. Work only in this worktree.
- Don't change real state: no pairing, arming or display changes
  while developing. No network calls to real hosts.
- Bun for anything JS (`bun bin/lattices.ts ...`); no npm/pnpm.
- Commits: gitmoji on every message, small and focused. No co-author lines, no
  "Generated with" footers. Don't push.
- Finish with a short report at `~/.cache/machines-tab-report.md`: what's built,
  what's stubbed, and what needs a decision.
