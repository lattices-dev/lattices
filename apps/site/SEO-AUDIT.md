# SEO audit

The baseline below records the September 29 audit before the fixes. The October 15 integration preserves the current Learn routes, Action schema, namespace migration, and 0.14.1 download. Full build/export, lint, 46 focused tests, and the 17-route Learn audit pass. Native icon packaging has not been built during this integration.

Crawler view of `apps/site/dist` after `bun run build` on 2026-09-29. No JavaScript. Origin is `https://lattices.dev` (`public/CNAME`, the canonical in `index.html`, and `SITE_URL` in `scripts/export-static.mjs`).

`robots.txt` allows all crawlers and points at `https://lattices.dev/sitemap.xml`. `sitemap.xml` is generated at build with that origin. It lists the home page, product pages, `/action/agents`, `/blink/agents.md`, `/blog`, each published post, and each `/docs/<slug>` page. It omits `/docs`, the `/docs/blog` aliases, and the noindex download URLs. `og.png`, `og-docs.png`, `og-action.png`, `og-blink.png`, and `og-speech.png` are real files. `og-api.png`, `og-cli.png`, and `og-site.png` are in `dist` and unused. No page has JSON-LD. Draft post `lats-dev-ipad-companion` is correctly omitted.

| Route | What a crawler gets |
| --- | --- |
| `/` | Title, description, canonical `https://lattices.dev/`, and OG/Twitter tags are unique and `og.png` exists. `#root` is empty: no `h1`, no body text. No JSON-LD. |
| `/experiment`, `/concept` | Not exported. GitHub Pages serves `404.html`. The SPA knows both paths. |
| `/action`, `/blink`, `/speech`, `/products`, `/family`, `/brand` | Unique title, description, canonical, and OG/Twitter. Image file exists. One `h1`. Prerendered body text. No JSON-LD. |
| `/blog`, `/blog/<slug>` | Same as the product pages. Descriptions come from post front matter. No JSON-LD. |
| `/docs/blog`, `/docs/blog/<slug>` | Same HTML as `/blog` and each post, with a different canonical (`https://lattices.dev/docs/blog/...`). Duplicate. Not in the sitemap. |
| `/docs` | Title `Docs — Lattices`, description `Lattices documentation`, `h1` `Overview`. Body duplicates `/docs/overview`. Not in the sitemap. No JSON-LD. |
| `/docs/overview` | Description is the short front matter line `What lattices is and who it's for`. One `h1`. No JSON-LD. |
| `/docs/agents`, `/docs/api`, `/docs/app`, `/docs/assistant-knowledge`, `/docs/concepts`, `/docs/config`, `/docs/embedded-sdk`, `/docs/layers`, `/docs/ocr`, `/docs/quickstart`, `/docs/release`, `/docs/voice`, `/docs/workspace-map` | Unique front matter descriptions. One `h1` except `/docs/mouse-gestures` (listed below). All use `og-docs.png`, including the API and CLI pages that already have `og-api.png` and `og-cli.png`. No JSON-LD. |
| `/docs/mouse-gestures` | Two `h1`s, both `Mouse Gestures` (page header plus the markdown heading). |
| `/docs/agent-execution-plan`, `/docs/agent-layer-guide`, `/docs/ai-chat-ux-review`, `/docs/companion-deck`, `/docs/companion-deck-builder-spec`, `/docs/component-extraction-roadmap`, `/docs/gesture-customization-proposal`, `/docs/handsoff-test-scenarios`, `/docs/hudson-overlay-alignment`, `/docs/hudson-overlay-next-steps`, `/docs/hyperspace-grid-snappiness`, `/docs/mcp`, `/docs/pi-lattices`, `/docs/presentation-execution-review`, `/docs/repo-structure`, `/docs/terminal-kit`, `/docs/tiling-reference`, `/docs/voice-command-protocol`, `/docs/voice-error-model` | Description is the shared fallback `Lattices documentation`. Two `h1`s (slug title plus the markdown title). `/docs/ai-chat-ux-review` has three. No JSON-LD. |
| `/action/agents` | Prerendered, with its own title and description. Canonical and `og:url` use a trailing slash; the sitemap entry does not. Twitter card is set, but `twitter:title`, `twitter:description`, and `twitter:image` are missing. No JSON-LD. |
| `/action/download`, `/blink/download` | `noindex`. No description, no `h1`. Not in the sitemap. |
| `/404.html` | Own title, description, and `h1`, with real suggestion links. Canonical, `og:url`, and OG/Twitter title and description are still the homepage. No `noindex`. |
| `/blink/agents.md` | Markdown file. In the sitemap. No HTML head. |

Image `alt` attributes are present on exported `<img>` tags (decorative images use an empty `alt`). The homepage download control is an icon with `aria-label="Download Lattices for macOS"`. No `click here` / `read more` links in the React pages. Pagefind indexes 47 pages and skips HTML without `data-pagefind-body` (home and product pages).

## Done / Not done

Checked again with `bun run build` and `bun run lint` after the fixes. `bun /tmp` checks were local; the committed proof is the export script plus a pass over `dist` (one `h1` per HTML file, sitemap locs, canonicals, and JSON-LD parse).

### Done

- `0b262649` records the findings above.
- `c361151b` is the fix. `src/seo/routes.ts` is the catalog for the static pages. `scripts/export-static.mjs` writes each page's title, description, canonical, Open Graph, and Twitter tags from that catalog, from doc front matter, or from the first prose paragraph. The sitemap is that same list. `robots.txt` still points at `https://lattices.dev/sitemap.xml`.
- `/`, `/experiment`, and `/concept` are prerendered. `/concept` canonicalizes to `/experiment`. Only `/experiment` is in the sitemap.
- `/docs` canonicalizes to `/docs/overview`. `/docs/blog` and `/docs/blog/<slug>` canonicalize to `/blog` and `/blog/<slug>`. Those aliases stay out of the sitemap.
- `/docs/api` uses `og-api.png`. `/docs/config` uses `og-cli.png`. Other routes keep the card `routeBrand` already selected. Each `og:image` URL is a file in `dist`.
- JSON-LD on `/`: `Organization`, `WebSite`, and `SoftwareApplication` (macOS, `DeveloperApplication`, download `v0.14.1/Lattices.dmg`). `/blink` and `/speech` get `SoftwareApplication`. `/action` preserves its richer existing graph from `actionSchema`, including Linux remote use and setup instructions. Posts get `BlogPosting` from their front matter. Blink sets `isAccessibleForFree` because the install section says free. Action and Blink `downloadUrl` values are `https://lattices.dev/action/download` and `https://lattices.dev/blink/download`. Speech uses `speech-v0.2.0/Speech.dmg` and `softwareVersion` `0.2.0`.
- Doc pages keep a single `h1`. A markdown `h1` that repeats the title is removed. Any other markdown `h1` is an `h2`. Descriptions that were the shared fallback `Lattices documentation` now come from `nav.json` or the first paragraph of at least 40 characters.
- `404.html` is `noindex`. Its social title and description match the 404 page. It does not canonicalize to the homepage.
- `/action/download` and `/blink/download` stay `noindex` and now have an `h1` and a description.
- `/action/agents/` keeps the trailing slash already used by its HTML and by the site footer. The sitemap uses that same URL. The export adds the missing Twitter title, description, and image from the page's own tags.
- `284bcc5e` clears Blink lint errors that were already failing `bun run lint` (`SpatialDemo` callback order, empty `catch`, and effect `setState` timing). Theme application is unchanged. The reveal flag and the theme-switcher label update on a microtask.

### Not done

- `og-site.png` is still unused. The homepage keeps `og.png`, which is the card `bun run og` writes for Lattices.
- Pagefind still ignores the homepage and the product pages. They do not set `data-pagefind-body`.
- Proposal and internal docs stay indexable. They were already public HTML.
- Short front matter is unchanged. `/docs/overview` is still "What lattices is and who it's for".
- No price, rating, or review markup. The pages do not state a currency.
- No Search Console property, sitemap submission, or change to the existing gtag snippet.
- JSON-LD is in the static HTML for a full page load. A client-side route change updates `document.title` from the same catalog and leaves the JSON-LD of the first document in place.

### Needs a person

- Confirm `https://lattices.dev` in Search Console and submit `https://lattices.dev/sitemap.xml`.
- Confirm how GitHub Pages treats a trailing slash. Generated routes omit it. `/action/agents/` keeps it, matching the footer.
- Decide whether `/experiment` belongs in the sitemap. It was an unlinked SPA path. It is now a real page at priority `0.4`.
- Decide whether engineering proposals and internal notes should be `noindex`.
- Decide whether to use or remove `og-site.png`.
