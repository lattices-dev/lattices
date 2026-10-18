# Lattices on Linux

A local desktop window built with Quickshell and Qt Quick. It uses the existing
Linux host API over loopback. Desktop updates use events; the virtual preview
refreshes at up to four frames per second while either preview is visible.

For a standalone app, CLI, host and tray installation, follow
[Install on Linux](../../docs/install-linux.md). The installed runtime does not
depend on keeping a source checkout.

## Install

Run this inside a Hyprland desktop on Arch/Omarchy:

```sh
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
```

From this checkout, run `bash install.sh` at the repository root. With Bun and
all system dependencies already installed, `bun run linux:install` runs the
same app installer.

The installer copies the CLI and Linux runtime into the user account, installs
the app launcher, enables the host and tray user services, checks `lats doctor`,
and opens the app. The source checkout can be removed afterward.

| Option | Behavior |
| --- | --- |
| `--gestures` | Add Forward-button gestures and the pen trail on Omarchy |
| `--wheel-gestures` | Also reserve wheel-click for gestures |
| `--no-start` | Copy files without starting services or opening the app |
| `--dry-run` | Show the plan without writes, downloads or service changes |
| `--no-deps` | Skip distribution packages; install JavaScript dependencies normally |
| `--replace-existing` | Back up and replace older/manual installation files |

Gestures map left/right to spaces, down to the Lattices overlay, and down then
left to Enter in the original window. Up sends the Fab recording toggle when
Fab is separately installed. The installer does not install Fab or Scout.

Plain wheel-click keeps its existing behavior unless `--wheel-gestures` is
selected. **Super+Ctrl+G** opens the button tester; **Escape** cancels it.

Repeat the install command to update. Existing gesture choices are retained.
An activation failure leaves the copied runtime installed and reports the
service or desktop error. Changed files are backed up under
`~/.local/state/lattices/install-backups/`.

See [Install on Linux](../../docs/install-linux.md) for the full requirements,
verification commands, SSH setup, installed paths and recovery instructions.

## Run from source for development

Keep this checkout available when running the development app. With Bun and
Quickshell installed, run from the repository root:

```sh
bun install --cwd packages/host-linux --frozen-lockfile --ignore-scripts --omit optional
bun packages/host-linux/src/main.ts  # if the host is not already running
bun run linux:app
```

The repository root and `packages/host-linux` are separate Bun packages.
The host declares `dbus-next` in its own manifest and lockfile; a root-only
install does not install it. For root typechecking and host tests, install both:

```sh
bun install --frozen-lockfile
bun install --cwd packages/host-linux --frozen-lockfile --ignore-scripts --omit optional
bun run check:types
bun test packages/host-linux/test
```

The host install skips dependency lifecycle scripts and the optional native
Unix-FD addon, matching the host's documented JavaScript D-Bus setup.

The shell follows the macOS app's layout and navigation. Home shows running
sessions, active windows, and saved layer layouts. Layers saves windows into named
contexts, chooses In place, Auto, Columns or Master stack, and switches them on
the current display and desktop. Show all restores windows put away by a layer
switch. New layers can start with visible windows or be filled with Add windows.
Rename, remove and delete edit the same `~/.lattices/workspace.json` used on Mac.
The first edit backs up an existing file to `workspace.json.bak`.

Overview is **Flight Deck**, a continuous map of the existing spaces on one display with
search, a target panel and exact window controls. Activity records actions and errors from this app session. Settings,
in the sidebar footer, contains host health and local device pairing controls.

Click the L-shaped brand mark or wordmark to collapse or expand the navigation.
Ctrl+K opens window search; Ctrl+1 through Ctrl+4 open Home, Overview, Layers, and
Activity. Ctrl+6 opens Mission Control; Ctrl+7 opens Operator Console.
F1 or Ctrl+5 opens Hints. New session opens a project-directory launcher. Desktop changes update
the app through host events; Refresh reconnects after the host stops.

`Theme.qml` defines the Linux instrument palette and retains the Mac app's
navigation dimensions. `ShellChrome.qml` gives the views one title strip and
shared navigation. The mark follows the Mac's `LatticesMarkAvatar`.
Flight Deck, Mission Control and Operator Console use the design selected from
the Linux Studio studies and refined by the Opus design pass.

The shell uses black, gray and white with the theme's accent for selection and
keyboard focus. Live desktop state uses the primary text color with dots, rules
and labels. Previews, inspected spaces and parked windows use a pale caution
color and explicit labels. Red marks failed requests.
The shared shell shows **LIVE**, **WORKING** or **OFFLINE** from the app state.
Keycap legends show each view's keyboard controls.

## Appearance

Lattices follows the current Omarchy background, foreground, accent and light or
dark mode. It reads `~/.local/state/omarchy/current/theme/colors.toml` and
`current/theme.name`, honoring `XDG_STATE_HOME` and falling back to the older
`~/.config/omarchy/current` layout. Theme changes appear within about a second,
even while the host is offline. A partial theme switch keeps the last valid
palette. Without Omarchy, the app uses neutral black, gray and white with amber.

An optional `~/.config/lattices/appearance.toml` (or the same path under
`XDG_CONFIG_HOME`) controls the appearance:

```toml
follow_system = true
# accent = "#e68e0d"  # override the accent in any theme
translucency = 0.94
ui_font = "Adwaita Sans"
mono_font = "JetBrains Mono"
```

Set `follow_system = false` for the built-in neutral and amber palette.
`translucency` is the surface opacity: `1` is opaque; smaller values reveal more
of the desktop. It is clamped to `0.88`–`1` to preserve readability. Text and
controls retain their own opacity. This material uses transparency without
compositor blur. Appearance files are read every second; the app does not write
Omarchy configuration or change the desktop theme.

## Mission Control

Open it with `lats app mission` or **Ctrl+6**. The inventory includes live windows
across spaces and windows parked by layers. Counts show windows, existing spaces,
tmux sessions and parked windows. The side panel shows saved layers, sessions,
recent app actions and host health.

**Ctrl+K** filters by title, app, decimal window ID or layer. Space buttons filter
the inventory. **Go to space** changes the desktop. **↑ / ↓** select a row;
**Enter** focuses the selected live window. **Flight Deck** opens its spatial map
with the same target selected. **Esc** clears the filters.

Parked windows cannot be focused or inspected on the map. **Show all · current
spaces** (or **Restore here** in a narrow window) restores parked windows whose
original spaces are currently active. Switch to another original space before
restoring its windows.

## Operator Console

Open it with `lats app console` or **Ctrl+7**. Run supported Lattices commands and
read selectable results in a transcript. Each request has its own result ID.
The console accepts typed Lattices actions; it does not execute arbitrary shell
commands.

```text
lats doctor
lats windows --json
lats spaces
lats sessions
lats search "Project notes"
lats window place 123 right --dry-run
lats space next --dry-run --json
lats layer "Build tools" --tile
session /absolute/project/path
help
```

**Tab** completes commands, exact window IDs and saved layer names. Press Tab
again to cycle matches. **↑ / ↓** step through history and recover your draft.
**Ctrl+L** clears completed entries and preserves running commands and history.
History and results stay in memory until the app closes.

Add `--dry-run` to preview focus, placement or space changes. Previews have an
amber **PREVIEW** label. Add `--json` to data commands for structured output.
`lats doctor` can diagnose an offline host. Other host actions require a
connection. `session <path>` creates a detached tmux session; attach to it from
a terminal. New session also opens the project-directory launcher.

## Flight Deck

Open it with `lats app overview` or **Ctrl+2**. Existing spaces on the selected
display form a continuous canvas with live window geometry. Scroll or pinch to
zoom around the pointer. Drag empty canvas to pan; hold **Space** to drag over
windows, or use the middle mouse button. Horizontal scrolling also pans.
Wheel zoom and space framing ease into place. A fresh drag or pinch interrupts
that motion immediately; a quick pan carries a short, bounded release momentum.

**0** fits all spaces. **1** zooms into the inspected space. **+ / −** zoom at the
viewport center. The **All** and **Space** controls provide the same actions.
Click a space to inspect it; double-click empty space to zoom into it. Camera
navigation does not change desktop focus or switch the actual workspace.

Arrow keys select the nearest window in that direction; **Enter** focuses the
selected window. Clicking a tile selects it; double-clicking focuses it.

The space strip and **[ / ]** inspect existing workspaces without switching the
desktop. **Go to space** switches the real workspace. The current space has a
filled dot; an inspected space has an amber label. **Esc** clears search and
previews and returns the map to the current space. A display chooser appears
when multiple displays are connected.

**Ctrl+K** searches window titles, apps and session tags across spaces. Choose a
result to inspect its space. Prefix commands with `>` or use a supported `lats`
command to run them. The command field never executes shell text:

```text
> focus "Project notes"
> space next
lats window focus 123 --dry-run
lats window place 123 right --dry-run
> layer "Build tools"
> hints
```

Relative space commands operate on the focused display, as they do in the CLI.
The target panel shows decimal window IDs and a selectable CLI command. Placement
controls move the selected window; **Preview placement** changes them to a dry
run and draws the planned frame in amber. A preview does not move or focus a
window. Selecting another target clears it.

Layer buttons raise and arrange saved windows on the current space. They are
disabled while inspecting another space. **Show all** restores parked windows
whose original spaces are currently active.
The independent virtual desktop remains available from **Virtual space**.

Run `bun run test:linux-app` for Qt Quick keyboard, command, receipt and layout
checks. It uses an offscreen renderer and writes fixture images to `/tmp`.
`bun run test` includes the pure map/navigation and command-parser tests.

Start Host uses the existing `lattices-host.service` user unit. If that unit is
not installed, run the host command above in your graphical session.
`LATTICES_LINUX_PORT` selects another local host port; the address stays loopback.

Layers requires an updated Linux host. Its `layers.*` endpoints also work from
the CLI. Linux supports focus and tile switching; launch commands, Mac app
hiding, layer undo and project companion rules are not implemented. Saved pins
hold the original live window and process. Reopened windows can be added again.
Window classes in hand-written app rules should use the Linux app identifier.
Parked windows and the active layer are recorded in `layers-stage-linux.json`
so Show all remains available after the host restarts. Windows on other desktops
are restored when those desktops are showing.

`lats app` opens the Linux window or brings an existing one forward. During
development, the CLI must point at this source checkout. The standalone installer
copies its own runtime. Host and tray services remain independent of the app window.

## Linux hints pack

Open **Hints** in the sidebar, or press **F1** or **Ctrl+5** while Lattices is
focused. Search by action, shortcut or command, and choose a category to learn
one group at a time. The page works while the local host is offline.
Desktop spaces choose where windows live. Layers organize windows within the
current desktop; Linux layer activation does not gather windows from other spaces.

The pack covers Omarchy navigation, Lattices app shortcuts, layers, terminal
sessions and floating windows. Desktop keys are labelled as Omarchy defaults;
personal bindings can override them. Recognized Ctrl+Left/Right space navigation
and the Lattices cursor-home binding in `~/.config/hypr/bindings.lua` appear in
**Your shortcuts**. The app and CLI use the same pack.

```sh
lats hints             # read the pack without the app or host
lats hints --json      # reusable structured pack
lats hints --open      # open the app's Hints page
lats app hints         # same page
```

The Linux installer adds Lattices to Omarchy's Apps menu. The desktop entry
includes a **Keyboard hints** action that opens this page. It uses the installed
runtime, so opening Hints does not require a source checkout.

## Desktop CLI

```sh
lats spaces                         # current spaces and window counts
lats space next                     # cycle existing spaces forwards
lats space prev                     # cycle backwards
lats space previous                 # return to the former space
lats space 4 --dry-run --json        # preview a switch without changing focus
lats window focus 123 --dry-run      # resolve an exact window ID first
lats window focus 123                # focus the window, switching space if needed
lats place org.quickshell right --dry-run --json  # preview a placement by app
lats doctor --json                  # read host health; nonzero when a check fails
lats app status --json               # app page and host connection
lats app quit                       # close only the app window
lats app restart                    # reopen on the same page
```

`lats space` requires a Linux host with `spaces.focus`. Numeric IDs can create
new empty workspaces; next and prev cycle existing spaces. Quit and restart do
not stop the host, tray, tmux sessions or virtual space. The doctor checks are
read-only and never restart services or install tools.

The Linux CLI uses `windows.search` when the host does not offer unified search.
It matches app, title and session tags. `--deep` reports that terminal-content
and OCR sources are unavailable, and date filters return an error.

## Virtual space

The **Agent view** button in the sidebar shows a floating live preview on top
of your apps. **Show PiP** in Virtual space opens the same viewer. Drag its
header to move it and its lower-right corner to resize it. The viewer watches
only; **Open controls** opens the explicit virtual input controls in Lattices.

```sh
lats app preview             # show the viewer without focusing the main app
lats app preview hide        # hide it; background work continues
lats app preview toggle      # show or hide it
lats app pip show            # alias
```

Showing or hiding the viewer never starts or stops the virtual desktop. Hiding
both the PiP and the embedded preview stops frame capture. The shared feed
updates at up to four frames per second while either is visible, including
when the main window is hidden or on another page. Stale and offline previews
are marked. Closing the main window while PiP is shown keeps the viewer open;
`lats app quit` closes both views while the host's virtual session keeps running.

Open **Overview → Virtual space → Start virtual space**. Browser and Terminal
launch apps on a separate 1280 × 800 headless desktop, with a live preview in the
same view. **Control preview** enables clicks, scrolling, the key buttons and
Send text. Watching and agent input leave the physical desktop's pointer and
focus alone. Stop closes the virtual apps; closing this window leaves the space
running until the host stops.

Virtual space needs `sway`, `grim`, `wtype` and `dbus-run-session` on PATH. The
Browser preset needs Chromium or Chrome and keeps a separate profile in
`~/.lattices/virtual-space/browser`; Terminal needs `foot`. On Arch, install the
optional tools with `sudo pacman -S sway grim wtype foot chromium`. Existing
physical windows stay on their original desktop; launch new Wayland apps here.

Agents use `computer.virtual.start/status/launch/capture/stop` and add
`space: "virtual"` to `computer.*` input or observe calls. Input still stages by
default and requires `treatment: "execute"` to act. See the
[host API notes](../../packages/host-linux/README.md#virtual-computer-use).

## Opt-in acceptance checks

These checks are not part of the ordinary unit-test command. Run them from the
repository root after installing both packages:

```sh
bun packages/host-linux/test/virtual-runtime.acceptance.ts
mkdir -p /tmp/lattices-qml-evidence
LATTICES_ACCEPTANCE_ARTIFACTS=/tmp/lattices-qml-evidence \
  bun packages/host-linux/test/qml-runtime.acceptance.ts
```

The virtual check owns a fresh private Sway runtime and disposable foot windows.
The QML check uses a fresh private Sway runtime, a copied shell with a navigation
timer, and a fixture backend. It captures Home, Overview, Layers, Activity,
Settings, and the Virtual space view. It does not test host RPC integration.

For live Hyprland acceptance, an explicit opt-in permits creating two new owned
headless outputs and three disposable foot windows in the current compositor:

```sh
LATTICES_ACCEPT_LIVE_OWNED_OUTPUTS=1 \
  bun packages/host-linux/test/hyprland-runtime.acceptance.ts
```

This check does not edit compositor configuration or workspace assignments. It
uses temporary registry/workspace files, verifies floating and tiled move-back,
layer parking and restart recovery, and an injected lost acknowledgement after
a real park. It removes only its own outputs/windows, restores baseline focus
and pointer, and compares preexisting window geometry and workspace assignments.
Do not run it while someone is interacting with the desktop: concurrent changes
can invalidate the baseline assertions.
