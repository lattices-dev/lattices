---
name: "Hyperspace website showcase"
description: "Scoped landing-page frame for the approved Luminous Hyperspace browser demo."
colors:
  preview-ground: "#d7e0ef"
  control-surface: "#f7f9ff"
  control-hover: "#fff"
  control-ink: "#101518"
  focus-coral: "#ef6a47"
typography:
  heading:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "clamp(28px, 3.5vw, 44px)"
    fontWeight: 550
    lineHeight: 1.1
    letterSpacing: "-.035em"
  control:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.2
rounded:
  preview: "14px"
  preview-compact: "10px"
  control: "9px"
spacing:
  caption: "16px"
  heading: "24px"
components:
  button-try:
    backgroundColor: "{colors.control-surface}"
    textColor: "{colors.control-ink}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0 22px"
  button-try-hover:
    backgroundColor: "{colors.control-hover}"
  preview-stage:
    backgroundColor: "{colors.preview-ground}"
    rounded: "{rounded.preview}"
---

# Design System: Hyperspace website showcase

## Overview

**Creative North Star: "A clear frame for Luminous Hyperspace"**

The landing-page wrapper gives the approved desktop scene room to carry the visual story. A short heading and description precede a large rounded preview; a small caption identifies the simulation. Page typography and theme colors come from the existing website.

This document covers only [the React wrapper](../../src/components/HyperspaceShowcase.tsx) and [its stylesheet](../../src/styles/hyperspace-showcase.css). The embedded scene retains the authority of [Luminous, made precise](../../../../studies/hyperspace-visual-directions-2026-11-08/luminous-precise/DESIGN.md); its packaged files live in [public/demos/hyperspace](../../public/demos/hyperspace/). The scene's glass, geometry and app-content treatments remain scoped there.

**Key Characteristics:**
- A broad scene preview with restrained surrounding copy.
- A light launch button over the poster and quiet text links outside it.
- On-demand desktop interaction with a compact poster presentation on mobile.

## Colors

The neutral preview ground and light control surface hold the scene. Control Ink labels the launch action; Focus Coral makes keyboard position visible. The wrapper inherits page text and secondary text through the site's theme, including `--text-dim`; it introduces no replacement page palette.

**The Scene Authority Rule.** Reuse the approved scene and its scoped design guidance when updating the demo.

## Typography

The heading and launch control inherit the website's sans-serif family. The heading balances across lines; supporting copy has a readable measure (53ch) and open line height (1.6). The external link is small (13px); the caption is smaller (12px, becoming 11px at the compact breakpoint).

## Layout

The section occupies the existing landing-page content rail and inherits its section divider. Local vertical padding scales with the viewport (`clamp(40px, 6vw, 88px)`). On desktop, copy sits left and the full-screen link sits right. The poster spans the stage at its intrinsic aspect ratio (1672:941); the launch control is centered horizontally, one fifth of the stage height above its lower edge.

Activating the preview replaces the poster with an iframe whose height scales between 600px and 780px (`clamp(600px, 55vw, 780px)`). The caption remains below it. At viewport widths up to 640px, the stage shows the poster, the heading stacks, and launch, full-screen and close controls are hidden. This compact landing-page treatment is separate from the standalone scene's own responsive layout.

**The Intentional Launch Rule.** Load the simulation iframe only after the visitor activates Try Hyperspace.

## Elevation & Depth

The stage uses a broad cool shadow; the launch control has a smaller, stronger shadow. These separate the large preview and its action without adding more glass around the already luminous scene. Exact shadows and the launch control's short background transition are recorded in the sidecar. Reduced motion removes that transition.

## Shapes

The preview has gently rounded corners, reduced at the compact breakpoint. The launch button uses the smaller control radius. Directional icons are authored inline SVG strokes.

## Components

**Poster and stage.** The poster loads lazily, includes descriptive alternative text and provides the initial scene at every size. The iframe has an accessible title and is sandboxed with `allow-scripts`.

**Try Hyperspace.** The light launch control has a minimum height (46px), white hover state and visible coral focus outline (2px, offset 4px). Activation focuses the iframe.

**Full-screen link and Close preview.** The former opens the standalone demo in a separate tab; the latter unmounts the iframe and returns focus to Try Hyperspace. Both use the same focus treatment. Their arrows use SVG where present.

## Do's and Don'ts

### Do:
- **Do** keep the wrapper's typography and theme colors connected to the existing website.
- **Do** preserve the poster-first desktop launch and mobile poster presentation.
- **Do** retain visible focus and focus restoration when closing the preview.

### Don't:
- **Don't** turn this local wrapper into a new global website design system.
- **Don't** describe simulated browser windows as access to the visitor's Mac.
- **Don't** replace the approved scene with a screenshot containing interactive hotspots.
