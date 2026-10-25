# Lattice surfaces

Interactive design studies for Machines, Overview, and Layers. These are browser prototypes for review before native implementation.

**Review status — October 24 (revised):** **Refined** opens by default. Opus authored it after inspecting the three supplied screenshots and current native source, following [`NATIVE-REFINEMENT.md`](NATIVE-REFINEMENT.md). The parent completed narrow fit, keyboard-selection, viewer-target, and scope-metadata corrections and verified the rendered study. The user endorsed this direction and requested the readability, monitor-detail, and window-title refinements documented below. These remain Studio changes; nothing has been ported to native. **Plan** (Opus) was rejected as an entirely different design language. Gallery, Instrument and Paperlight (Codex) were rejected earlier. All four remain reachable under the discreet **Archive** control as rejected history.

- Studio: <http://localhost:3050/studio/studies/lattice>
- Full-size comparison: <http://localhost:3050/embed/lattice>
- Source: `design/studio/src/studio/studies/Lattice.tsx` (review shell), `lattice/Refined.tsx`, `lattice/refined.css`, `lattice/refined-model.ts`. Plan and the Codex treatments stay in `lattice/` unchanged.
- Current screenshots: `/study-assets/lattice/current-{overview,layers,machines}.png`, unchanged copies of the October 24 captures.

## Refined — retained and refined

The review bar sits outside the mock app. Its controls are Refined / Current / Both, the surface (Overview, Layers, Machines), the Machines scenarios (archie offline, AW input unknown) and Archive. Current shows the unchanged native screenshot. Both stacks Current above Refined for the same surface. The mock sidebar and the review surface tabs stay in sync.

**Retained from native:** native sidebar (Workspace, Agents, System, Settings) with the green grid mark; graphite palette from `Theme.swift`; system type with small mono metadata; 46px toolbar and 26px status bar; small bordered 24px buttons; dotted canvas (minor and major dots) with native monitor proportions; Machines canvas above a full-width table. Table columns keep native widths (Status 112, Build 176, Displays 64, Actions 116) with 46px rows, a reserved Visit slot and a View menu (Lattices viewer, VNC in Screen Sharing…). Also kept are Overview's layers rail, displays at one scale with the 1.12 small-display boost, desktop strip and scope counts; Layers' workspace context, emerald display map and chat composer; green used only for live state; coral reserved for Visiting.

**Refined:**
- **Chips.** Each chip has one job and a fixed corner: host name above its group, input top-right, monitor bottom-left, eye on hover.
- **Input ownership.** An away input reads "Showing ‹owner›" with a dashed border and a dimmed picture.
- **Geometry.** Canvas monitor frames use a 6px outer radius and 3px recessed screen, with group 7 and well 10. Their existing placement and bounds are preserved.
- **Previews.** Schematic by default. The review-only **Captured previews + long titles** checkbox uses screen content from the supplied October 24 screenshot, cropped without baked-in labels and with its aspect ratio preserved. These are captured references, not live screens.
- **Desk mode.** Shows each monitor once, with its cabled inputs in a capsule; legend hover highlights a host's monitors.
- **Machines table.** Display silhouettes are solid when the host is showing and dashed when the screen is elsewhere. The row, canvas group and inspector share selection and hover.
- **Below the table.** A compact strip lists the selected host's windows and This Mac's screens, with Bring everything here and Make main.
- **Overview.** Gains kind chips and a `/` filter, ⌘-click multi-select, a focused-desktop list with rule tags, Focus and Move to Desktop, and Tile [T] / Distribute [D].
- **Layers.** Fixes the clipped table (Window, App, Placed here on, Rule), synced with the map. Workspace mode shows the full table.
- **Fit.** All surfaces fit the native 1760 × 760 window with table rows visible.

**Kept distinct:** viewing (viewer dialog, which doesn't move input), VNC (a separate menu item), Visiting (coral, End visit, armed/disarmed) and physical input ownership (chips and the Desk capsule). Offline archie stays explicit: dimmed group, red "Unreachable", viewer and Visit disabled, VNC still listed. An unknown input says "Input unknown" and claims no owner. All data is illustrative; nothing connects to a machine.

**Deliberate deviation:** native draws the input-on dot in coral. Refined uses green for it, because coral now means only Visiting.

## Design problem

The supplied October 24 screenshots show host names, physical display names, input labels, connection state, and actions competing over small screen previews. The lists below do not clearly carry the same selection or grouping. This study separates host identity from the screen image, gives monitor captions a stable location, and repeats selection consistently in the canvas, inventory, and inspector.

## Refined verification — October 24

### Monitor frame

Added the requested physical-monitor treatment within the existing graphite design: a narrow beveled edge, recessed black screen seam, soft shadow, and slightly deeper lower lip. Canvas previews share a smaller version of the frame. The expanded viewer follows each display's pixel aspect ratio and fits both viewport width and height; individual-window previews use a slimmer frame without the monitor lip.

Viewing-only and Visiting labels sit above the frame. Viewing another host leaves the current visit intact, and the footer names the actual keyboard/pointer destination. End visit remains available while viewing the visited host. Close receives initial keyboard focus and retains it after End visit. Captured references remain dated October 24 and explicitly disconnected.

Visually checked the ultrawide viewer at 1760 × 760 and the laptop and long-title window viewers at 1000 × 850. Verified independent viewing/visiting state, ending a visit without closing the viewer, and keyboard focus. Browser warnings/errors were empty. This is a Studio-only change; native source and app lifecycle are untouched. Pre-frame preservation snapshot: `/tmp/lattice-monitor-frame-20261024-223800`.

### Approved detail polish

Host names are slightly larger, input chips are more legible, and away/offline dimming affects preview content rather than status text. Single-display hosts reveal their monitor caption on hover, selection, or keyboard focus. Archie names its configured HDMI-2 connection separately from the current input owner; the full model, resolution, port, and status are also available in the tile's hover text and accessible description. Offline detail disclosure preserves last-seen information in that description without overlapping the caption.

Window rows reserve the View button and let monitor metadata shrink before the title. Full titles are available on hover in Machines, Overview, and Layers. The Layers table gives more width to the window name. The optional Machines content check includes long illustrative titles and the supplied captured screens; it does not change the default fixtures or contact a host.

Checked the polish at 1760 × 760 and 1000 × 850, including captured Hosts/Desk previews, keyboard detail reveal, selected/offline/unknown states, full-title viewing, and Layers column widths. Browser warnings/errors were empty. Typecheck continues to report only the existing `studio/live/server` module error. Pre-polish preservation snapshot: `/tmp/lattice-detail-polish-20261024-221659`.

### Earlier refinement verification

Visually inspected Machines Hosts and Desk, Overview, and Layers at 1760 × 760 and 1000 × 850. The frame fits the viewport; narrower machine details stack and scroll. Overview uses one scale constrained by both canvas dimensions, preserving monitor proportions, captions and 56 × 56 desktop cells. Layers rows retain their height and scroll within the roster.

Verified Current loads the unchanged supplied screenshot, layer scope metadata updates, Enter selects machine and window rows, and an individual-window viewer identifies the selected app and title. Offline archie disables Visit and window viewing; unknown input is distinct from offline. Console inspection returned no warnings or errors. Fixture interactions make no machine connections.

`bun run typecheck --incremental false` reports only the pre-existing `app/api/studio/live/route.ts` missing `studio/live/server` module. No new TypeScript errors. Screenshot routes serve byte-identical PNG copies and reject unregistered asset names. Whitespace checks pass. Native source, builds and app lifecycle were not changed. Unrelated dirty files, HEAD and index were preserved; pre-revision snapshot: `/tmp/lattice-native-refinement-20261024-213235`.

## Treatments

| Treatment | Monitor and host treatment | Lists | Tradeoff |
| --- | --- | --- | --- |
| **Refined** (default) | The current native canvas, tightened: consistent chips, explicit away/unknown/offline | Native full-width machine table; Overview panes; fixed Layers table | Smallest departure; refines rather than replaces |
| Plan — Opus (rejected) | Physically scaled panels, measured grid, local and remote host outlines, coral selection and input rails | Host/display outline linked to a selection inspector; flat window rows in Overview and Layers | Precise and restrained; tiny screen contents simplify to icons as the canvas fits |
| Gallery | Stronger host nameplates, proportionate displays on one baseline, softly lit bezels and visible stands | Aligned library rows, display silhouettes, selected-host detail alongside the list | More space per host; visual direction rejected in review |
| Instrument | Compact host bays, a registration grid, thin frames, coral selection | Denser rows with restrained metadata | More technical and less relaxed |
| Paperlight | Warm work surface, graphite frames, host identity below the display | Opaque warm rows with more breathing room | Larger departure from the dark canvas |

## Plan review interactions (archived)

Use Machines, Overview, and Layers in the mock sidebar. In Plan, Desk shows each physical monitor once and its attached inputs. Hosts shows every computer's full display arrangement, including This Mac. Selecting a shared monitor marks its corresponding attachment under the other host. Host and monitor selection drive distinct inspectors. Input ownership remains independent of selection.

The host inspector separates Lattices viewer, VNC, and Visit. Monitor inputs offer a separate Show here action. Overview desktops are independent per display; selecting a window row reveals its desktop. Search demonstrates filtered and empty lists. Review toggles show an offline host and a monitor whose input is unknown. Switching between Plan and the earlier treatments resets the prototype's local selection.

All data and window geometry are illustrative. Remote viewers, Visit, and input switching do not operate a real machine. Pan/drag, display rearrangement and Apply/Revert/Keep confirmation are outside this visual study; the existing native interaction contracts remain the authority. Fit chooses the largest physical scale that fits the canvas width and available height, using one row of host groups on short wide windows and two rows on taller or narrower windows. Manual zoom preserves the selected arrangement. Narrower screens stack the inspector below the outline.

## Plan verification — October 24

Rendered and visually inspected Hosts, Desk, Overview, and Layers. Verified monitor/host selection, shared-monitor identity, unknown inputs, offline capture availability, viewer opening and Escape dismissal, and selecting a window on another desktop. Confirmed Hosts and the lower list appear together at 1760 × 760, and checked a compact 1000 × 850 desktop. Browser console had no errors.

After the viewport-fit correction, `bun run typecheck --incremental false` reports only the existing `app/api/studio/live/route.ts` import error for `studio/live/server`. No new TypeScript errors. The Plan route returns HTTP 200. Native source and app lifecycle were not changed by this study.

Opus's final capture command did not return a completion receipt. The parent verified the rendered design directly and completed the fit correction; this review status is based on inspected files and browser behavior, not Scout's running flag. The pre-build preservation snapshot is `/tmp/lattice-opus-plan-20261024-205657`; the pre-fit component is `/tmp/lattice-plan-fit-20261024/Plan.tsx`.

## Native references

Read from `/Users/arach/dev/lattices`, without editing or rebuilding:

- `apps/mac/Sources/AppShell/MachinesPageView.swift`
- `apps/mac/Sources/AppShell/DeskCanvas.swift`
- `apps/mac/Sources/AppShell/MachineArrangementCanvas.swift`
- `apps/mac/Sources/Core/Overlays/Overview/OverviewDesk.swift`

Preserve the native distinction between physical monitor input ownership and remote viewability. Build differences are informational; capture availability and VNC availability are independent. A monitor group must retain its display arrangement when moved. Existing native behavior is not replaced by this prototype.

## Earlier treatment verification — October 24

Opened the registered Studio page and full-size study in Chrome for Testing. Visually reviewed all three treatments, Machines in Desk and Hosts modes, Overview, and Layers, including the narrower content area inside the Studio sidebar. Verified shared-monitor host selection, independent desktop selection, selected-host window rows, offline availability, empty search, and browser-window preview with Escape dismissal and focus restoration. This was desktop review, not a mobile acceptance pass.

The scoped whitespace check passes. `bun run typecheck` reports only the existing `app/api/studio/live/route.ts` import of the unfinished `studio/live/server` module. The study routes return HTTP 200.

The mutable shared Studio dependency contained incomplete live-feature files. This consumer now uses an isolated copy of committed Studio `672c52bba73b31e38842491e8b5573c3a807f786` under `/Users/arach/dev/.studio-dependency-cache/lattices-design/`; the shared source and its dirty work are preserved. The original dependency link and verification receipt are recorded in `/tmp/lattices-studio-dependency-repair-20261024.json`. The pre-edit workspace snapshot is `/tmp/lattices-studio-baseline-20261024-130528`.

## Gallery refinement — October 24

Refined the Studio study after the initial comparison. Host names now lead the hierarchy, display widths follow their aspect ratios, and monitor feet share a baseline. The shared U32J59x names its current desk input beside its caption. Gallery uses a darker graphite canvas, restrained bezel highlights, and a fine sage selection rule.

The machine inventory now uses display silhouettes and 54–58px library rows. At wide widths, the selected host's windows and View menu sit beside the list; build details live in that inspector. The inspector stacks beneath the list at compact widths. The window lists in Overview and Layers share the same typography and selection treatment.

Verified all three treatments in the browser, plus Desk, Hosts, Overview, Layers, compact desktop and narrow review layouts. The narrow page retains horizontal scrolling within the canvas and table. Typecheck continues to report only the pre-existing `studio/live/server` import error. No native source, app build, or installed app was changed by this pass. Pre-edit snapshots are in `/tmp/lattice-gallery-refinement-20261024-141650`.
