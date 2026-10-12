# Remove lan-mouse

The user: "i want us to remove the lan-mouse and just have lattices only cursor
and keyboard". The visiting cursor (`docs/visit.md`) is the only way the cursor
and keyboard go to another machine now. lan-mouse goes from both sides.

## Mac (`apps/mac`)

- Delete `Core/Desktop/PointerShare.swift` and everything that calls it:
  - the `mouse.share`, `mouse.keep`, `mouse.stop` and `mouse.status` API
    methods, plus anything else lan-mouse-only in `Core/Daemon/LatticesApi.swift`;
  - the menu bar items in `AppShell/MenuBarController.swift`;
  - Long's card pointer section (`Core/Overlays/Long/LongCard.swift`);
  - the Machines page controls and the lan-mouse merge source
    (`AppShell/MachinesPageView.swift`, `Core/Hosts/MachinesModel.swift`).
- `PointerHome.bringHome()` and `lats mouse home` stay. Bringing the cursor
  home ends a visit and warps the cursor to this Mac. Drop the lan-mouse half.
- `VisitController`: remove anything that waits for, stops or checks
  lan-mouse.
- Keep **Find mouse** / mouse finding (`MouseFinder`, `lats mouse find` or
  similar): it isn't lan-mouse.

## Linux host (`packages/host-linux`)

- Remove `src/mouse.ts` (the lan-mouse pointer trial) and its endpoints in
  `src/endpoints.ts`, plus `test/mouse.test.ts` and
  `test/pointer-trial.test.ts`.
- Tray (`src/tray/*`, `scripts/install-tray.ts`): remove the pointer sharing
  items and anything that installs, configures or starts `lan-mouse.service`.
  Keep cursor recovery if it's useful without lan-mouse (e.g. after a visit).
  Otherwise remove it too.
- `README.md`: drop the lan-mouse sections.
- Check `capabilities` / `host.describe` for a pointer-sharing capability and
  remove it. Keep `input.trackpad`: visits use it.

## CLI, docs, tests

- `bin/lattices.ts`, `bin/cli/usage.ts`: remove `lats mouse share|keep|stop`
  (and the status bits that only report lan-mouse). Keep `lats mouse home` and
  anything that isn't lan-mouse.
- `docs/visit.md`, `docs/api.md`, `docs/machines-*.md`: remove lan-mouse
  mentions. Don't add a "we removed lan-mouse" note: just describe what exists.
- `tests/machines-cli.test.ts` and any other test: update.
- Grep the repo at the end for `lan-mouse`, `lanmouse`, `lan_mouse`,
  `PointerShare` and `mouse.share`: zero hits outside lockfiles and
  `docs/reports/`.

## Constraints

- Work only in this worktree. Don't launch, quit or restart the running app.
  Don't ssh anywhere; I'm handling the services on the machines.
- Run `bun install` if `dbus-next` is missing (main added it) so
  `bun run check:types` can pass.
- `cd apps/mac && swift build -c release`, the Swift tests, the bun tests and
  `bun run check:types` must pass.
- Gitmoji on every commit; no co-author lines or footers; don't push. Bun only.
- Report to `~/.cache/remove-lan-mouse-report.md`.
