# Lattices learning and discovery program

Research date: 2026-10-02. Status: proposed editorial program with an implemented local pilot. See `pilot-delivery.md` for verification and launch requirements. This document does not report a deployment, indexing, traffic, installed-app tests, or scheduled work.

Help a capable Mac user become an effective power user. Teach them why an automation works, help them choose the right tool, and let them try the idea before installing anything. Use structured content records to publish and maintain this library. Each indexed page must earn its place through a different question, working teaching tool, decision, or demonstrated result.

The primary reader already uses keyboard shortcuts and installs utilities. They want to automate repeated work but do not yet know the difference between Accessibility (AX), screenshots, Apple Events, app shortcuts, and window management. Lead with the task and explain the mechanism when it helps. Swift code and API details belong in optional deeper sections and the existing developer docs.

## Position and product boundary

The site's current proposition is organizing windows, running tools, and controlling a Mac through shortcuts, gestures, or code. The current repository documents workspace layers, window placement, screen text, and a local agent API. These are the natural next steps after the lessons. Sources: `apps/site/src/components/LandingPage.tsx`, `docs/concepts.md`, `docs/workspace-map.md`, and `docs/api.md`, reviewed on the research date.

Use Lattices for workspace control. Direct readers interested in focused native computer use and capture to Action, with its separate installation and lifecycle. Do not imply that a browser teaching tool inspects the reader's Mac or that every Lattices-family feature comes with one download. Source claims describe the repository; a live demonstration requires its own evidence.

The editorial proposition is **understand your Mac, choose your tools, make the next task repeatable**. A lesson should still be useful to someone who never installs Lattices. Put a specific product bridge after the useful result: inspect a workspace, arrange a window, or understand an action receipt. Avoid inserting the same download pitch into every section.

## What the research establishes

Apple documents accessibility objects as representations of UI elements with hierarchy, geometry, information, actions, and notifications. That supports an interactive model in which selecting a visible control reveals its role, label, and available action. It does not establish that every app exposes a complete tree. [Apple AXUIElement reference](https://developer.apple.com/documentation/applicationservices/axuielementref), [Apple AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h).

Apple treats Accessibility access, screen capture access, and permission to automate other apps as separate settings. A task-based permission guide can explain which mechanism is involved before asking the reader to change a setting. The pilot uses the labels in the linked Apple guidance and notes that names vary by macOS version. Any future version-specific instructions must name and verify that version. [Accessibility access](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac), [screen and audio recording](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac), [Automation access](https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac).

Four public query samples were inspected on the research date. They establish an editorial starting point, not search volume or a reproducible ranking report. Results vary by location, time, and search system.

| Query sampled | Observed result types and source examples | Editorial implication |
| --- | --- | --- |
| `macOS AX tree inspector` | Working CLI and native inspectors, including [ax-cli](https://github.com/watzon/ax-cli), alongside Apple's [Accessibility Inspector](https://developer.apple.com/documentation/accessibility/accessibility-inspector) | Explain the tree before asking a learner to install an inspector. Clearly label the browser example as a model. |
| `macOS accessibility permission screen recording difference` | Apple support pages and utility-vendor permission guides | Answer “I can see the app, why can’t I click it?” with a decision tool and a specific next step. |
| `macOS UI automation tools` | Apple [UI test automation](https://developer.apple.com/documentation/XCUIAutomation), app automation products, and [agent tool references](https://macos-mcp.com/docs/tools/) | Disambiguate personal automation, software testing, and agent control before comparing tools. |
| `macOS window manager comparison yabai AeroSpace Rectangle` | Vendor comparison hubs, project documentation, directories, and videos; [Loop's comparison](https://github.com/MrKai77/Loop) is one example | Generic lists already exist. Compare the work a person wants to do and the setup they are willing to maintain. |

The inference is that teaching tools offer a more distinctive starting point than an undifferentiated “best Mac apps” article. This has not been validated against Lattices Search Console data or a paid keyword dataset. We have no measured query volumes, keyword difficulty, rankings, backlink counts, conversion rates, or forecast.

## The first 11 pages

The local pilot uses three route families. The three hubs, `/learn/`, `/compare/`, and `/watch/`, organize these pages; they are not counted in the 11 detail pages.

| Reader's question | Page and useful object | Product bridge | Primary success signal |
| --- | --- | --- | --- |
| How does an automation know which button to press? | `/learn/ax-tree`: select controls in a modeled Mac window and inspect their roles, labels, and actions | Read the workspace and inspection docs; explore Action for native computer use | Complete one select-and-inspect exercise |
| Why can it see my screen but not control an app? | `/learn/macos-automation-permissions`: select a task and get a permission explanation | Match the intended Lattices feature to its documented permission requirements | Reach a decision and open the relevant setting instructions |
| When do I need a screenshot instead of a UI element? | `/learn/ax-vs-screenshots`: compare the same scenario as pixels and structured elements | Understand inspection and verification before trying a local action | Change scenario and reach the selection guidance |
| Do I need more than window snapping? | `/compare/rectangle`: fit analysis for keyboard and edge snapping | Workspace layers and programmatic placement when the task needs them | Open the relevant product or docs link |
| Can my launcher also manage the workspace? | `/compare/raycast`: launcher-led workflow and window-management fit | Dedicated workspace control and local API | Follow the option that matches the chosen task |
| Should I write my own Mac automations? | `/compare/hammerspoon`: Lua configuration and automation fit | Predefined workspace operations through Lattices | Inspect a representative workflow and its maintenance cost |
| Should I build a repeatable macro? | `/compare/keyboard-maestro`: macro authoring and repeatable app work | Workspace setup around an automation; Action for the separate computer-use need | Open the macro or workspace documentation |
| Do I want a command-driven tiling setup? | `/compare/yabai`: tiling, rules, commands, and feature-specific requirements | Workspace organization through Lattices' documented surfaces | Read the setup tradeoff and choose a next step |
| Do I want keyboard-driven workspaces? | `/compare/aerospace`: tree-based tiling and workspace model | Compare the way workspaces are declared and activated | Open the relevant workflow documentation |
| Show me how the invisible UI tree works | `/watch/ax-tree`: short animation, transcript, and link to the exercise | Continue to the AX teaching tool | Reach 90% playback, then try the exercise |
| Show me why pixels and UI elements differ | `/watch/ax-vs-screenshots`: one scenario, two representations, a verification step | Continue to the selection lesson | Reach 90% playback, then explore a scenario |

Competitor sources are the [Rectangle site](https://rectangleapp.com/), [Raycast window-management page](https://www.raycast.com/core-features/window-management), [Hammerspoon docs](https://www.hammerspoon.org/docs/), [Keyboard Maestro site](https://www.keyboardmaestro.com/main/), [yabai repository](https://github.com/asmvik/yabai), and [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide). The competitor records hold their own claim-level references and review dates. These are source-reviewed fit analyses until reproducible use tests exist. Do not call them hands-on reviews or award a winner from documentation alone.

## Programmatic production model

`topic-backlog.json` is the editorial inventory. A record is a commission, not a route to auto-publish. Each record has one intent, a distinct useful object, primary sources, a product bridge, an evidence requirement, and a review state. The initial inventory contains 30 records: 11 pilot pages and 19 candidates.

Shared templates should supply navigation, source citations, review metadata, related lessons, transcripts, and structured data. Editors own the task explanation, original exercise or analysis, limitations, and conclusion. Generate variants inside a tool when the teaching mechanism is the same. Do not create one indexable URL per role, error code, app name, screen resolution, or permission combination.

Priority reflects reader fit, evidence availability, a distinct learning outcome, and connection to the product. It does not represent estimated demand. The backlog uses P0 for the pilot, P1 for likely next commissions, and P2 for candidates that need additional evidence. Null evidence fields mean unverified, not complete.

Each publishable record must add:

- `evidence`: reviewed source URLs and dates, exact claims they support, fixture origin, tested macOS/app versions, test procedure, result, and stored artifact paths when a use test exists.
- `review`: named editorial and technical reviewers, review date, next review date, and an approval decision. A source reviewer and a use-test reviewer can be the same person, but the evidence states must remain separate.
- `publication`: canonical path, content revision, published date, deployment URL, live check date, and indexability decision.

For comparisons, record whether a capability is documented, directly tested, unavailable in the tested configuration, or unknown. Missing documentation is not proof of absence. Prices, supported OS versions, licensing, privacy claims, and optional system changes require exact current sources. Keep edition and feature scope explicit. Present a competitor's good fit before explaining where a different product might help. Disclose that Lattices publishes the comparison. Google's [review guidance](https://developers.google.com/search/docs/specialty/ecommerce/write-high-quality-reviews) supports explaining decision factors and providing evidence of actual experience.

## Expansion and indexing gates

The following are proposed internal quality gates, not claims about Google's ranking formula.

1. **Distinct intent:** the editor can explain why the existing page cannot satisfy the task through another section or scenario. Merge redundant candidates.
2. **Useful result:** a reader can finish an exercise, make a bounded decision, or follow a reproducible procedure. A rewritten source summary fails this gate.
3. **Evidence:** source claims have citations; demonstrated claims have artifacts and versions. A modeled interaction is labeled as modeled. A permission selector must not claim to diagnose the current computer.
4. **Review:** technical review checks mechanism and limitations; editorial review checks that an aspiring power user can follow the explanation without knowing AX terminology.
5. **Usability:** verify keyboard operation, visible focus, readable mobile layout, reduced motion, alternative text, and a text equivalent to visual teaching. No native permissions or installation are required to use the browser exercises.
6. **Delivery:** verify the built and deployed route, HTML title/H1/body, self-canonical, internal links, 200 response, crawl permissions, and sitemap entry. Static route generation must not produce a 200 fallback page for unknown slugs.
7. **Measurement:** check the proposed event payloads in a real browser and verify receipt in the configured analytics property before calling instrumentation operational.

Google asks whether content adds original value and serves an existing audience. Its [people-first guidance](https://developers.google.com/search/docs/fundamentals/creating-helpful-content) and [scaled-content policy](https://developers.google.com/search/docs/essentials/spam-policies#scaled-content) support keeping the useful teaching object as the unit of publication. AI can prepare records, drafts, and source-change diffs; it must not publish pages merely because a template can fill a keyword.

Keep unfinished pages, uncertain claims that affect the decision, placeholders, and broken tools out of the public sitemap. If those pages are available publicly for review, use `noindex` until the failed gate is resolved. Do not block those URLs in robots.txt while relying on Google to read their `noindex` directive. [Google noindex guidance](https://developers.google.com/search/docs/crawling-indexing/block-indexing).

Query-string states and tool presets should resolve to the main lesson rather than form an indexable URL inventory. Permanently combine duplicate lessons with a redirect to the useful replacement. Low traffic alone is not a reason to delete or noindex a useful page, especially before there is enough observation time.

## Animation publishing contract

Use the same reviewed teaching mechanism across the lesson and animation. Keep each animation’s storyboard, captions, and transcript tied to its exact controls and labels. The pilot lesson uses Save and the animation uses Export to illustrate the same named-button mechanism. Show one idea per clip: the tree exposes meaning; a screenshot exposes appearance; an action needs verification. Use an explicit label when the animation represents a conceptual interface rather than footage from a tested Mac app.

Render work can run on the user's SSH `hetz` host. Record source revision, renderer version, render command, duration, dimensions, media hash, and returned output path. Rendering remotely does not verify macOS AX behavior. Review the opening, key transitions, final frame, timing, transcript, and playable output before connecting a video to its watch page. The renderer must not need personal desktop captures or secrets for the synthetic pilot scenes.

Each watch page should make one playable video the main content, with a stable thumbnail and media URL, accessible controls, a transcript, and a related exercise. Use `VideoObject` only when its fields match the real asset; duration and upload date must come from the delivered media and publication. A build timestamp is not an upload date. Google's [video guidance](https://developers.google.com/search/docs/appearance/video) distinguishes indexed pages from indexed videos and recommends dedicated watch pages. Eligibility does not guarantee video indexing. A lesson can also embed the clip while retaining its distinct instructional purpose.

## Six-week launch sequence

This is a proposed sequence. It does not create a schedule or authorize publication. Weeks are relative to the approved public launch date.

| Week | Deliverable | Acceptance and decision |
| --- | --- | --- |
| 1 | Finish the 11-page local pilot; reconcile current public routes and sitemap; capture the pre-launch Search Console/analytics baseline if access exists | All pilot quality gates pass. Record unknown baselines explicitly. Publish only through the project's authorized deployment workflow. |
| 2 | Verify the deployed learning tools and two watch pages; make indexing requests through available first-party tools | Check real rendered HTML, media availability, canonical URLs, analytics receipts, and video status. Fix delivery issues before commissioning more pages. |
| 3 | Ask three willing target readers to complete the learning exercises; review six competitor pages for fit and clarity | Record where readers fail to explain the result or choose a tool. Review observed behavior and feedback before interpreting engagement rates. This document does not authorize outreach. |
| 4 | Commission at most two P1 lessons from actual reader questions or qualified Search Console queries | Each new lesson passes the distinct-intent gate. Candidates: choosing an automation approach and understanding clicks that stop working. |
| 5 | Add two reproducible competitor scenarios with saved screenshots or recordings; create a third video only if a lesson has a demonstrable visual teaching need | Keep source review and hands-on evidence separate. Update existing comparison pages before creating new competitor permutations. |
| 6 | Compare qualified discovery, useful interactions, and product bridges by route family; decide expand, improve, or hold | Expand one demonstrated topic cluster by at most three pages. If samples are small or indexing incomplete, keep collecting evidence and improve the pilot; do not manufacture a winning conversion claim. |

## Measurement specification

The current source loads Google Analytics through `apps/site/index.html` and sends a `cta_click` event from the landing page. Source configuration is verified; live event collection and property access are not verified by this strategy work. The following is the proposed learning event contract. Implementation can map equivalent existing events into these definitions without duplicate firing.

| Event | Trigger | Allowed dimensions |
| --- | --- | --- |
| `learning_tool_start` | First deliberate change in a teaching tool per page visit | `page_id`, `tool_id`, `content_revision` |
| `learning_tool_complete` | Defined exercise result reached once per scenario | Above plus a fixed `scenario_id`, `result_id` |
| `comparison_filter` | Reader chooses a workflow category in the directory | `page_id`, fixed `workflow_id` |
| `source_open` | Reader follows a citation | `page_id`, fixed `source_id`, `source_type` |
| `content_bridge_click` | Reader opens relevant docs, product page, or lesson | `page_id`, fixed `destination_id`, `bridge_type` |
| `explainer_start` | Video starts after a reader action | `page_id`, `video_id`, `content_revision` |
| `explainer_progress` | Playback first crosses 25%, 50%, or 90% | Above plus `milestone` |
| `content_feedback` | Reader selects useful / unclear, if implemented | `page_id`, fixed `answer_id` |

Do not send typed text, copied AX trees, app/window titles, local paths, screenshot contents, or permission-state guesses. Use fixed identifiers. Deduplicate repeated render events and disable development/staging traffic in production reports. Cross-link using normal URLs; internal UTM tags would obscure the original acquisition source.

The primary report should connect a landing-page family to a useful result and then a qualified next step. Report tool completion per tool start, exercise visits after video playback, and product/docs bridge clicks per engaged lesson visit. Report download clicks as download intent, not installations. Installed activation requires separate product-side evidence that this program does not add.

In Search Console, separate non-brand learning queries, competitor queries, and Lattices brand queries. Review query relevance, indexed pages, impressions, clicks, and video indexing. Compare periods only after checking deployment dates, indexing coverage, and denominators. No numerical lift target is defensible before the baseline. The first decision is whether the content attracts the intended reader and helps that reader complete a task.

## Maintenance and regeneration

Review fast-changing competitor, OS, permission, and installation claims before publication and at least monthly while the pilot is active. Review conceptual lessons quarterly and after a relevant Apple API change. These are proposed editorial intervals, not installed automations.

Automation may check source availability, identify changed claims, validate records, rebuild approved templates, and regenerate media from approved storyboards. Automation must not silently change verdicts, remove caveats, replace official links with summaries, declare a test passed, or move a record into the published state. A source change creates a review item. It does not rewrite the conclusion automatically.

Preserve the previous claim, new source, reviewer decision, and content revision in the change record. Update the public review date only when a substantive review occurs. Do not refresh dates merely because the build ran. A failed source fetch leaves the previous reviewed claim and date visible unless the claim is known to be wrong. Correct known errors promptly and hold affected pages from expansion until their evidence is repaired.
