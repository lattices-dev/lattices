# Competitor research for the learning pilot

Reviewed on October 2, 2026. The dataset is [learning-competitors.json](../../apps/site/src/data/learning-competitors.json).

These listings help readers choose a tool for a job. Rectangle, AeroSpace, yabai, Hammerspoon, Keyboard Maestro, and Raycast overlap with parts of Lattices, but they do not form one interchangeable product category. The useful comparison is window snapping, automatic tiling, macOS scripting, macro automation, or command launching.

The audience is a capable Mac user becoming a power user. Explain setup through concrete work: choosing shortcuts, editing a configuration file, assembling a macro, or writing a script. Define specialist terms where they first matter. Do not invent difficulty scores or assume that the reader already knows tmux, tiling trees, or Accessibility APIs.

## Evidence and method

Each entry uses the maintainer's website, repository, or documentation. This was a documentation review through public web sources. No competitor was installed or benchmarked for this work. There is no evidence here for comparative speed, memory use, battery impact, reliability, or universal app compatibility.

The `capabilities` fields summarize documented behavior. `bestFor` and `latticesFit` are editorial assessments inferred from that behavior. The sources apply to the competitor claims; Lattices positioning comes from the repository's [concepts](../concepts.md), [app guide](../app.md), and [API reference](../api.md), read in the web workspace. This review did not verify every capability in a running Lattices build.

The public listings must display their sources and review date. They must describe this evidence as documentation review, not hands-on testing. A `reviewedAt` date records an actual source check; rebuilding the site must not silently advance it.

## Source evidence

| Tool | Sources and supported claims | Editorial decision |
| --- | --- | --- |
| Rectangle | The [official site](https://rectangleapp.com/) describes shortcuts and snap areas. The [README](https://github.com/rxhanson/Rectangle) documents URL actions, layouts, and minimum-size constraints. | Give it a positive recommendation for deliberate window placement. Do not imply that it has no scripting entry or only operates on one window. |
| AeroSpace | The [project overview](https://github.com/nikitabobko/AeroSpace) describes the tree model, Beta status, and no requirement to disable SIP. The [guide](https://nikitabobko.github.io/AeroSpace/guide) explains TOML configuration, workspaces, callbacks, and monitors. | Explain the change from native Spaces to emulated workspaces. Do not repeat performance claims as measurements. |
| yabai | The [README](https://github.com/asmvik/yabai) covers binary space partitioning, CLI control, permissions, and an optional scripting addition. The [configuration guide](https://github.com/asmvik/yabai/wiki/Configuration) covers shell configuration and per-Space settings. | Preserve the distinction between ordinary use and extra features that require elevated privileges. Never state that all yabai use requires disabling SIP. |
| Hammerspoon | The [overview](https://www.hammerspoon.org/) explains Lua and Spoons. The [getting started guide](https://www.hammerspoon.org/go/) demonstrates window layouts. The [AX reference](https://www.hammerspoon.org/docs/hs.axuielement.html) explains target-app limits and state verification. | Present custom scripting as its strength. AX access is conditional on the target application's exposed interface. |
| Keyboard Maestro | The [product page](https://www.keyboardmaestro.com/main/) describes workflow actions, text, images, and windows. The [manual](https://wiki.keyboardmaestro.com/manual/How_do_I) covers macro construction, the separate engine, and mouse-click fragility. | Recommend it for broader app workflows. Do not reduce the product to click recording. |
| Raycast | The [window-management manual](https://manual.raycast.com/window-management) documents window commands, layouts, and constraints. The [Script Commands manual](https://manual.raycast.com/script-commands) explains local scripts and interpreters. | Treat it as a possible entry point into another tool's CLI. Any Lattices integration remains untested. |

## Uncertainty and exclusions

- Rectangle's homepage and repository give different minimum macOS requirements. The dataset omits compatibility numbers rather than merging those claims. Verify the chosen release before adding an installation guide.
- Raycast's manual combines platform material and has a Pro marker. The dataset does not promise that every documented feature belongs to a specific plan. Verify macOS and plan availability before writing a purchase comparison.
- Official documentation can describe development behavior ahead of a packaged release. Version-specific recipes need a release identifier and a reproducible check.
- No entry asserts that a missing mention proves a missing capability. There are no binary competitor scorecards, invented ratings, pricing tables, or measured performance claims.
- Simultaneous control by multiple window managers has not been tested. Complementary jobs do not establish compatibility between their layout engines.
- Action, Blink, and Speech are separate products. This dataset does not attribute their capabilities to the Lattices menu bar app.

## Expansion requirements

Add a comparison page only when its question changes the reader's decision. A page about choosing a tiling tree needs different evidence from a page about inspecting an AX element. Do not generate every product pair from the same paragraphs.

For a hands-on follow-up, record the app version, macOS version, permissions, target applications, commands, expected result, and observed result. Keep source review and hands-on evidence separate. Link each comparison to a relevant educational example and back to the tool directory.

Refresh an entry after a relevant release or before publishing new claims about price, compatibility, security requirements, or feature availability. Update the source, claim, and review date together.
