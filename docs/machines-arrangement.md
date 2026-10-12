# Machines: free arrangement, more computers

Follow-up to `docs/machines-tab.md`, on the same branch. The user, after using
the first version: "now we need to move and rearrange the monitors. and add
more computers".

## 1. One arrangement canvas, like System Settings › Displays

Replace the four Left/Top/Right/Bottom slots with one canvas, drawn to scale:

- **This Mac's displays**: drag to rearrange, snapping edge to edge like
  System Settings. This changes the real macOS arrangement
  (`CGBeginDisplayConfiguration` / `CGConfigureDisplayOrigin` /
  `CGCompleteDisplayConfiguration(.permanently)`), so a drag only moves the
  drawing. An **Apply** button commits it and a **Revert** button undoes it, and
  after applying it reverts automatically after 15 s unless kept.
  Never apply without the button.
- **Other machines**: each one is a block made of its own monitors at their
  real proportions, labelled with the machine's name. Ask the host for its
  displays if it can tell you (look at what `host.describe` / the Linux host
  return: Archie has HDMI-A-1 3440×1440 and a virtual LATS-1 1920×1080). If it
  can't, draw one generic screen. Drag the block anywhere against this Mac's
  displays. Where it touches is where the cursor crosses.
- **Elsewhere displays**: still drawn, dim, and you can drop a machine *onto*
  one ("this display shows arts-mini"). Store that, show it, and when the
  pointer is pushed off an elsewhere display that a machine is on, start a visit
  to that machine.

Fix from the first version:
- Only the real main display gets "This Mac". Number the others, and label an
  elsewhere display with the machine it shows if one is set.
- Draw elsewhere displays clearly dimmer.
- No green: the selected rail icon in this page (and wherever this tint is
  coming from) uses the app's normal selection, or coral if it has to be a hue.

## 2. Placement replaces `side`

Today a machine has one `VisitTrust.Side` and `VisitController` allows one
machine per side. Generalise:

- A machine's placement is a rect in global display coordinates (the same
  space as `CGDisplayBounds`), stored with the pairing. Its side and the span
  along it are derived from where it touches this Mac's displays.
- Crossing: the exit point on an edge belongs to whichever machine's rect
  touches that stretch of edge. So two machines can share a side (e.g. two on
  the right, one per display). `enter`'s `edge` and `at` stay as they are in
  `docs/visit.md`; compute `at` along the machine's touching span, not the
  whole display.
- Migrate existing pairings: an old `side` becomes a rect beside the outermost
  display on that side, vertically centred. Keep `visit.side` working as a
  shortcut, and add `visit.place {name, x, y}`. Mirror both in `lats visit`.
- Keep the edge push threshold and quiet period exactly as they are.

Put the geometry (touching spans, snapping, migration, which machine owns an
exit point) in pure functions with tests.

## 3. More computers

- An **Add machine** button opens a sheet. Fill in name and address, then pick
  what it is:
  - a Lattices host (writes `~/.lattices/hosts.json`, like `lats hosts add` if
    that exists; add it if not);
  - a visit host to pair (the existing pairing flow);
  - or both.
  The new machine appears on the canvas off to one side, unplaced, until it's
  dragged against a display.
- Unplaced or unreachable machines still show, dimmed, so the user can arrange
  them before they're online.
- **arts-mini** (a Mac, `ssh arts-mini`) is the next machine the user wants. A
  Mac has no visit host yet: the Linux one is in `packages/host-linux` and the
  protocol is `docs/visit.md`. Build the Mac side of it in the app, behind a
  setting that's off by default ("Let other machines visit this Mac"). It should:
  - accept the signed `/visit` upgrade on the existing bridge;
  - post the CGEvents;
  - draw the visiting cursor (small rounded coral dart with a soft glow and a
    name pill, like `visitor/shell.qml`);
  - send `exit` when the cursor leaves by the edge it came in.
  Unit test the message handling. Don't deploy it to arts-mini or ssh there.

## Constraints

Same as `docs/machines-tab.md`:
- Work only in this worktree. Don't launch, quit or restart the running app.
- No real display reconfiguration, pairing, arming or sharing while developing.
  Display reconfiguration only ever happens through Apply.
- Gitmoji on every commit, no co-author lines or footers, don't push. Bun only.
- `cd apps/mac && swift build -c release` must pass, along with the tests.
- Write the report to `~/.cache/machines-arrangement-report.md`.
