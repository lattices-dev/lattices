---
name: "Native Hyperspace — Luminous, made precise"
description: "A luminous native window-arrangement session using the existing HUD, survey and placement system."
colors:
  action-coral: "rgb(93.7% 41.6% 27.8%)"
  primary-ink: "rgb(14% 16% 19%)"
  secondary-ink: "rgb(36% 38% 41%)"
  hud-ivory: "rgb(93.7% 95.7% 100% / 34%)"
  hud-edge: "rgb(100% 100% 100% / 72%)"
  selection-wash: "rgb(93.7% 41.6% 27.8% / 12%)"
typography:
  title:
    fontFamily: "macOS system"
    fontSize: "13pt"
    fontWeight: 600
  action:
    fontFamily: "macOS system"
    fontSize: "12pt"
    fontWeight: 600
  status:
    fontFamily: "macOS system"
    fontSize: "11pt"
    fontWeight: 400
  layout-label:
    fontFamily: "macOS system"
    fontSize: "9pt"
    fontWeight: 500
rounded:
  layout: "7pt"
  control: "8pt"
  hud: "16pt"
  preview: "18pt"
spacing:
  hud-inset: "16pt"
  bottom-offset: "20pt"
  cluster-gap: "28pt"
components:
  hud:
    backgroundColor: "{colors.hud-ivory}"
    textColor: "{colors.primary-ink}"
    rounded: "{rounded.hud}"
    width: "860pt maximum"
    height: "72pt wide; 116pt compact, before roster or notice"
  button-apply:
    backgroundColor: "{colors.action-coral}"
    textColor: "{colors.primary-ink}"
    typography: "{typography.action}"
    rounded: "{rounded.control}"
    width: "102pt"
    height: "28pt"
  layout-choice-selected:
    backgroundColor: "{colors.selection-wash}"
    textColor: "{colors.primary-ink}"
    typography: "{typography.layout-label}"
    rounded: "{rounded.layout}"
    width: "59pt maximum"
    height: "44pt"
---

# Design System: Native Hyperspace — Luminous, made precise

## Overview

**Creative North Star: "Luminous, made precise"**

The native adaptation carries the approved study's cool glass, crisp edges, dark ink and restrained coral into the existing Hyperspace session. The user's cached wallpaper supplies the overview ground. Actual window previews retain their app content and palette; controls provide the common visual language.

The floating instrument keeps the task legible: choose Desktop or Overview, select windows, preview an arrangement, then Apply. Native AppKit controls remain native. The existing HUD preview, Hyperspace survey and placement components share one selection and geometry session.

**Key Characteristics:**

- Cool translucent controls with crisp ink labels and fine optical edges.
- Coral identifies selection, proposed geometry and the commit action.
- Existing window previews and app clusters provide the visual content.
- One session retains ordered selection and staged geometry across both views.

Authority: the approved [Luminous, made precise study](/Users/arach/dev/lattices-design/studies/hyperspace-visual-directions-2026-11-08/luminous-precise/DESIGN.md). This record is scoped to native Hyperspace; source tokens come from [HyperspaceChrome.swift](../../Sources/Core/Overlays/Motion/HyperspaceChrome.swift), [HyperspaceDesktopHUD.swift](../../Sources/Core/Overlays/Motion/HyperspaceDesktopHUD.swift), [WindowMotionMode.swift](../../Sources/Core/Overlays/Motion/WindowMotionMode.swift) and the preview adapter in [HUDRightBar.swift](../../Sources/Core/Overlays/HUD/HUDRightBar.swift).

## Colors

The recurring native values are normative in the frontmatter. Native color-space construction remains defined in `HyperspaceChrome`.

### Primary

- **Action Coral:** selected edges, order badges, proposed geometry, layout diagrams and Apply. Labels on filled coral use Primary Ink.
- **Selection Wash:** the chosen layout's quiet fill, paired with a fine coral boundary.

### Neutral

- **Primary Ink / Secondary Ink:** actions, app and window labels, counts and supporting instructions.
- **Cool Ivory:** the tint over active native HUD material.
- **Optical Edge:** the fine white rim that separates translucent surfaces.
- Existing app content retains its own palette. Keyboard aim uses the system focus color.

## Typography

Use the macOS system family throughout the instrument. Title and action weights establish hierarchy; the count and instructions remain quieter. Layout names use the compact label role, with semibold weight for the chosen plan. Survey headers, window titles and hover previews retain their existing `Typo` roles.

The selection count has a dedicated wide-layout allocation (90pt). It remains readable beside layout diagrams; it is plain status text rather than a separate chip.

## Layout

The floating panel is centered above the active display's visible-frame bottom. Width is capped at the recorded maximum or the display width minus 32pt. Below 760pt, its controls use the compact two-row arrangement. Empty Desktop adds an 80pt roster; an operation notice adds 24pt independently. The recorded base heights exclude these additions.

Desktop / Overview is a regular native segmented control. More contains Layers, Grid, Map, undo, restore and keyboard guidance; only one auxiliary section is disclosed at a time. Layout choices use a capped 62pt slot, leaving a 3pt gap between buttons.

Overview centers the existing app clusters with the recorded cluster gap. A pending layout expands the existing screen-map renderer into the main stage, with aspect-fit screenshots and ordered captions. When space permits, unaffected windows remain in a companion rail; it appears from 1000pt stage width and is capped at 240pt.

**The Same Session Rule.** Switching Desktop / Overview keeps ordered picks, original frames, history and the pending proposal in the same MotionPanel session.

## Elevation & Depth

`HyperspaceGlassView` uses active AppKit `hudWindow` material with behind-window blending and an Aqua appearance. Cool Ivory tints that material; the Optical Edge is drawn at 0.75pt. Floating panels retain their native shadow, and the hover preview uses a restrained offset shadow.

The overview loads the display's existing `SpaceCanvasWallpaper` cache, aspect-fills it and adds a white veil at .34 opacity. It does not change the user's wallpaper. Survey highlighting dims thumbnail content while preserving readable labels and badges. Existing `HyperspaceMotion` transitions remain the motion vocabulary.

**The Optical Edge Rule.** Separate translucent controls with a fine white rim and controlled shadow; keep their interiors quiet.

## Shapes

The instrument, preview, layout choices and controls use the frontmatter's scoped radius steps. Existing window tiles retain their rounded frames and numbered selection badges. Proposal windows use softly rounded corners with an inset glass caption. Idle Grid cells retain a visible 1pt ink boundary at .30 opacity; coral marks warm or active targets.

## Components

| Responsibility | Existing owner |
| --- | --- |
| Preview, loading state, previous-image retention and cache | `HUDHoverPreviewView`, `WindowPreviewCard`, `WindowPreviewStore` |
| App clusters, window tiles, Layers, map and Grid | `ExposeView` and its existing sections |
| Ordered picks, original geometry, history and proposal | `MotionPanel` |
| Precise placement and staged markers | Existing `placementStage` and Grid |
| Applying real window frames | `WindowTiler` |

The Desktop roster adapts hover and keyboard aim into `HUDState` for preview. Its nonactivating preview panel offers Select / Deselect through the shared view's optional action. Other HUD callers retain their default appearance and Inspect action.

Entry starts with no selected windows. Selecting or switching views leaves real frames unchanged. Choosing a feasible layout stages its geometry in the main proposal and existing Grid markers. Direct desktop drags also leave a proposal on release. Apply / Return commits a pending proposal; Escape clears it. Done closes the session. Command-Z clears a pending proposal before undoing applied geometry; Restore returns the original session geometry and closes.

**The Preview Before Change Rule.** Layout choices and direct desktop drags stage geometry before Apply / Return commits it through WindowTiler.

November 8 verification passed all 11 layout-planner tests and the passive [appearance fixture](../../Tests/HyperspaceAppearanceTests.swift) (one test, 22.539s). Native visual review accepted the seven crisp Action captures in [`.local/hyperspace-luminous-20261108/review/`](../../../../.local/hyperspace-luminous-20261108/review/): Desktop preview, Overview, selection, proposal, Layers, Grid and unavailable preview. The fixture uses inert synthetic windows and non-key panels on an existing Action agent display, with no global input tap or AX window mutation; the same 12 real windows retained their frames before and after. The canonical source-app restart then installed and launched the signed, source-digest-matched `apps/mac/Lattices.app`; strict signature verification and private-socket daemon health passed. Runtime verification covers restart and daemon health. Live MotionPanel/global-keyboard input, real layout mutation and release publication remain unverified.

## Do's and Don'ts

### Do:

- Do reuse the actual HUD preview, cache, survey and placement components.
- Do keep selection order, preview geometry and Apply on the same session state.
- Do keep dark labels readable on coral and over the native glass.
- Do distinguish component appearance evidence from live window-management verification.

### Don't:

- Don't move windows when selecting them or switching views.
- Don't crop proposal screenshots to fill their target geometry.
- Don't dim window labels with nonmatching thumbnail content.
- Don't add a launcher, action panel, mascot or alternate placement engine to this surface.
