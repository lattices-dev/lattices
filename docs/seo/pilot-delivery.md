# Local SEO pilot delivery

Built on 2026-10-02 in the canonical web workspace, `/Users/arach/dev/lattices-design`, branch `codex/web-workspace`. Audience: mid-level Mac users who aspire to become power users. Publication and measurement remain separate launch steps.

## The delivered play

Lead with a useful question, let the reader try the mechanism, and offer a relevant next step into Lattices or Action. The program has three connected route families:

| Family | Local delivery | Reader outcome |
| --- | --- | --- |
| Learn | Three interactive lessons: AX tree, permission selection, AX versus screenshots | Explain the mechanism and choose a first diagnostic step |
| Compare | Six sourced analyses: Rectangle, AeroSpace, yabai, Hammerspoon, Keyboard Maestro, Raycast | Match a tool to a job and understand setup tradeoffs |
| Watch | Five silent animations: two at 36 seconds, three at 40 seconds, all with captions and complete visual transcripts | Understand the concept, then enter a relevant lesson, comparison, or reference |

Three hubs plus fourteen detail pages produce seventeen static HTML routes. The content engine draws from typed lesson records, competitor JSON, and the measured media manifest. Adding an approved record rebuilds metadata, citations, related links, static HTML, sitemap inclusion, and the Pagefind index. The 31-topic backlog is an editorial queue. Adding a record does not automatically publish a route; the three follow-on clips were explicitly commissioned in the second batch.

The strategy and proposed six-week rollout are in `strategy.md`; topic commissions are in `topic-backlog.json`; competitor source decisions are in `competitor-research.md`. The second batch scripts and verification are in `explainer-batch-02.md`.

## Implementation map

- `apps/site/src/lib/learning.ts`: lessons, route inventory, canonical metadata, breadcrumb schema, optional analytics dispatch.
- `apps/site/src/data/learning-competitors.json`: reviewed competitor records with official sources and caveats.
- `apps/site/src/components/LearnPage.tsx`: interactive exercises, directory filters, comparison template, watch pages and full transcripts.
- `apps/site/src/styles/learning.css`: responsive light and dark treatments; shared header wrap is in `styles/docs.css`.
- `apps/site/scripts/export-static.mjs`: built HTML and sitemap. Content remains readable before client JavaScript runs.
- `apps/site/scripts/audit-learning.mjs`: route, source, metadata, internal content/media link, caption, transcript and media checks.
- `apps/site/public/learn/media/`: five MP4s, posters, VTT captions, text transcripts and measured manifest.
- `studies/seo-explainers/`: reusable HyperFrames sources, Hetz render instructions, source ledger and render evidence.

## Verification

TypeScript, production build and the content audit pass. The audit checks all seventeen generated routes and 204 internal content/media links, including self-canonicals, unique titles and descriptions, one H1 per page, breadcrumbs, sitemap entries and complete visual transcripts. Pagefind indexes the new content. The build still reports the site's shared JavaScript bundle size warning; deployed mobile performance has not been measured.

Browser checks cover keyboard operation of the AX exercise, task selection in the permission guide, directory filtering, and client navigation metadata. Mobile header overflow and dark-theme brand contrast were corrected. The learning and existing docs pages were measured at 421 CSS pixels with document width also 421; source contrast checks pass for light and dark text/button pairs. Temporary viewport emulation produced inconsistent screenshot scaling, so no exact desktop screenshot measurement is claimed. Captured evidence is under `studies/seo-pilot-evidence/`.

The first two videos were encoded on the user's `hetz` host: H.264, 1280×720, 30fps, 36 seconds. HyperFrames checks passed, final MP4s decoded, and decoded frame samples were reviewed. Each footer uses `lattices.dev/learn`. Browser playback loads the delivered dimensions and duration. The AX tree clip advanced past 24 seconds, and the AX-versus-screenshots clip reached its 36-second end. The responsive player measured 385 by 216.6 pixels, preserving 16:9. These are illustrative diagrams, not evidence of running a native AX workflow. Detailed render results and hashes are in `studies/seo-explainers/evidence/media-verification.json`.

The second batch adds permissions, outcome verification, and snapping/tiling/workspaces. All three clips measure 40 seconds, 1280×720 and 30fps; full decoding and strict HyperFrames checks pass. Root reviewed their encoded contact sheets. Browser playback advanced the permission clip beyond 32 seconds and reached the end of the other two. Captions and transcript files exactly match the shared manifest. Batch verification is recorded in `explainer-batch-02.md` and `studies/seo-pilot-evidence/batch-02/verification.json`.

A separate reviewer checked the initial claims, static routes, interactions, transcripts, final frames, contrast and the corrected mobile screenshot. The second batch also passed independent content and integration review. No material findings remain after the corrections. The six competitor pages are documentation analyses, not hands-on benchmarks.

## Measurement available in this pilot

The existing optional production GA tag receives fixed-value events only on `lattices.dev`. Local previews send no learning events. No typed text or local desktop information is collected by these tools.

| Implemented event | Meaning |
| --- | --- |
| `lesson_interaction` | Reader changes a modeled control or visual scenario |
| `lesson_complete` | Reader activates Save in the AX exercise |
| `permission_result` | Reader selects a task in the permission guide |
| `comparison_filter` | Reader chooses a tool category |
| `product_bridge_click` | Reader follows the lesson's product/docs call to action |
| `explainer_play` | Video starts or resumes |
| `explainer_complete` | Video reaches its end |

Events are interaction counts, not deduplicated visitor/session completion metrics. The broader proposed contract in `strategy.md` includes additional milestones and source clicks not implemented here. Analytics receipt, Search Console access, baseline traffic, keyword volumes, ranking and conversion lift have not been verified.

## Launch steps

1. Review the local pilot and choose the public launch date; publish through the website's existing deployment workflow.
2. Verify deployed status codes, canonical URLs, robots behavior, sitemap, unknown-route 404 handling, media byte-range playback and mobile performance. Local static generation is verified; deployed behavior is not.
3. Add `VideoObject` metadata when the real public upload date and final media URLs are known. Do not substitute a render or build timestamp for publication. Current pages emit truthful WebPage and BreadcrumbList schema.
4. Verify production analytics receipts and record Search Console coverage before judging discovery or conversion.
5. Use reader questions and qualified queries to select the next two lessons from the backlog. Expand the cluster only after the existing pages prove useful.

No deployment, outreach, indexing request, recurring job, commit or push was performed by this task.
