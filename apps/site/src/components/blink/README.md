# Canvas landing integration

These sections are ported from `products/blink/landing/components/homepage`, the
source for blink.arach.dev. Preserve the spatial demo, real film, agent walkthrough,
sheet previews, copy and parchment/green visual identity when changing this page.

Adaptations for the Lattices site:

- `Chrome.tsx` uses the existing family mark and Products menu, plus Canvas section links.
- `Hero.tsx` uses a native image instead of Next Image.
- Theme controls affect only `#blink-landing`, so SPA navigation does not alter other pages.
- Media lives in `/blink/media`; downloads use `/canvas/download`, and agent documents
  use `/canvas/AGENTS.md` and `/canvas/llms.txt`. Sources retain the `products/blink` repository path.
- `blink-integration.css` contains the narrow header and typography adjustments.
- `scripts/build-blink-styles.mjs` compiles the original Blink CSS/Tailwind utilities
  and scopes every rule to this page. Run `bun run blink:styles` after editing utility
  classes; normal site dev/build also runs it. Do not edit the generated CSS directly.

Media was copied unchanged from the original product landing's public assets:
`hero-memory-field-warm.jpg`, `demos/blink-spatial-demo.mp4`, and its poster.
No new artwork or synthetic demo footage was produced for this integration.
