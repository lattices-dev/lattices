# Explainer batch 02

Audience: mid-level Mac users who want to become power users. Source review: 2026-10-02. The three clips extend the existing Learn, Compare, and Watch pilot. They explain one practical decision each, with diagrams and readable labels. They do not demonstrate a live Mac workflow or benchmark a product.

## Content and delivery

| Watch route | Reader question | Next step |
| --- | --- | --- |
| `/watch/macos-automation-permissions` | Which permission matches this task? | Existing permission guide and Lattices app docs |
| `/watch/observe-act-verify` | Did my automation finish the job? | Existing AX versus screenshots lesson and verification reference |
| `/watch/window-snapping-vs-tiling` | Do I need placement, automatic layout, or a work context? | Existing comparison directory and Lattices layer docs |

Each composition uses four ten-second beats, with silent on-screen explanation, captions, a poster, and a complete visual transcript. The media manifest must use measured output duration and dimensions. A render date is not a public upload date.

The website metadata and related links are authored locally. All three final videos are rendered and verified; see the render evidence and the batch verification section below. No new interactive lesson is required for this batch. The existing window-management lesson remains a backlog candidate.

The five video records each own their title, description, takeaway, sources, and related links. A watch page no longer assumes that its slug also names an interactive lesson. This allows a useful explainer to point directly to the existing tool directory or documentation.

## Three permissions, three different jobs

Goal: identify the access involved before changing settings. The clip distinguishes Accessibility, screen capture, and Apple Events Automation. A workflow can use more than one. Permission category names can vary by macOS version; no version-specific settings screen is imitated.

| Time | On-screen copy | Diagram |
| --- | --- | --- |
| 0–10 seconds | **Operate a control** · Accessibility · Read or use the controls an app exposes. | An automation tool points to a named Save button. |
| 10–20 seconds | **Capture the screen** · Screen & System Audio Recording · Capture access is separate from control access. | A window becomes an image frame. |
| 20–30 seconds | **Send app commands** · Automation · Apple Events can let one app command another. | An app sends a command to another app. |
| 30–40 seconds | **Start with the task** · One workflow may need more than one permission. · Check the requesting app. Names vary by macOS version. | The three diagram branches meet at a workflow. |

The permission guide links to the watch page. The watch page links back to the guide so a reader can choose a concrete task.

Source basis:

- [Apple: allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac) describes explicit access for apps that use accessibility features to control the Mac.
- [Apple: control screen and system audio recording](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac) describes the capture access category.
- [Apple: allow apps to automate and control other apps](https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac) describes authorization and the Automation category.
- [Apple: Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) connects the permission prompt to sending Apple Events to other apps. The official Markdown form was read because the rendered reference requires JavaScript. The clip does not claim that every Apple Event needs a new prompt.

## A click is not a completed task

Goal: separate an accepted action from the outcome the user needs. The save dialog and its failure are synthetic. The observe, act, verify sequence is editorial guidance based on the documented limits of action responses. It is not a promise that a particular tool uses this sequence.

| Time | On-screen copy | Diagram |
| --- | --- | --- |
| 0–10 seconds | **Observe** · Goal: save Weekend plans · Find the right window and the Save control. | A modeled note dialog with its window and button identified. |
| 10–20 seconds | **Act** · Press Save once · An accepted action does not prove the file was saved. | The action is sent; the app displays Could not save. |
| 20–30 seconds | **Verify** · Check the result · The error means the goal is still unmet. | Compare Expected: Saved with Observed: Could not save. |
| 30–40 seconds | **Recover with a limit** · Inspect the cause before retrying. · If one safe correction fails, stop and ask for help. | Inspect, make one safe correction, retry and verify; an unresolved result leads to Stop. |

The bounded retry is specific to the teaching example. It is not a universal retry count or an instruction to repeat an unknown or irreversible action. The accompanying page says to retry only when both the correction and the repeated action are safe. A changed screenshot or a visible success message does not, by itself, establish durable file storage.

Source basis:

- [Apple: the accessibility model](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html) explains the information and actions exposed by accessible elements. This is an archived conceptual reference, not a current OS behavior test.
- [Hammerspoon: performAction](https://www.hammerspoon.org/docs/hs.axuielement.html#performAction) explicitly distinguishes an accepted action from guaranteed success. The save error is an invented example of that distinction.
- Repository `docs/api.md`, section `computer.verify`, describes checking post-action text, AX values, or artifact changes. The watch page links to [the API reference](/docs/api). No local daemon or native app was operated to prove this example.

## Window snapping, tiling, and workspaces

Goal: choose the kind of help before choosing a product. The clip compares concepts, not exclusive product categories. A snapping app can also offer multi-window commands, and an automatic tiler can also have workspaces.

| Time | On-screen copy | Diagram |
| --- | --- | --- |
| 0–10 seconds | **Snap a window** · You choose the position. · Put the selected window on the left. | One window moves into the left half; the other windows remain where they were. |
| 10–20 seconds | **Tile automatically** · Rules arrange the windows. · The layout adapts as a managed window joins. | A conceptual tiler changes a two-window arrangement to a three-window arrangement. |
| 20–30 seconds | **Group a workspace** · Keep related work together. · Windows, projects, or sessions share a context. | A Planning group contains a browser, note, and terminal. |
| 30–40 seconds | **Choose the job** · Place one · Arrange several · Return to a context · Tools overlap. Workspace behavior varies by app. | Three small diagrams summarize the choices. |

The grouping animation does not promise that closed apps, terminal processes, or document state will be restored. A tool’s workspace is not automatically a native macOS Space. No competitor logo appears inside the conceptual interface as if it were a recorded product demonstration.

Source basis:

- [Rectangle](https://rectangleapp.com/) documents window placement through shortcuts and snap areas. It supports the snapping example without implying that snapping is its only capability.
- [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide) documents tree-based tiling, layouts, and its own virtual workspaces. Its workspace implementation is distinct from native macOS Spaces.
- Repository `docs/concepts.md` describes Lattices projects, placement, and optional tmux sessions. [Public concepts reference](/docs/concepts).
- Repository `docs/layers.md` describes grouping projects and windows into contexts. [Public layers reference](/docs/layers). The clip makes no claim about current native layer membership or installed app state.

## Verification and publication status

Content source review, independent content/integration review, TypeScript, production build, and the content audit pass. The audit checks seventeen routes and 204 internal content/media links, including exact VTT/manifest and full-transcript consistency. All three MP4s measure 40.000 seconds at 1280×720, 30fps, with 1,200 H.264 frames and no audio. Full decoding passes, and both preview and encoded frames were visually reviewed after fixing two overlaps. The source review is documentation-based; no native benchmark is claimed. Public deployment, upload dates, indexing, analytics receipts, traffic, and conversion remain unverified.

Browser playback loaded all three clips at the measured dimensions and duration. Permissions advanced beyond 32 seconds; the verification and window clips reached their 40-second ends. At a 421-pixel viewport, document width was 421 and the players preserved 16:9. Browser records and the page screenshot are under `studies/seo-pilot-evidence/batch-02/`; render records, hashes and decoded frames are under `studies/seo-explainers/batch-02/evidence/`. The existing site bundle-size warning remains; deployed performance was not measured.

The batch produces three additional watch routes: seventeen learning routes in total, including five watch pages. The backlog has thirty-one records after adding the window-concepts clip. The neighboring window lesson remains a candidate rather than a delivered page. The source audit validates internal documentation paths and any referenced anchors as well as official HTTPS sources. The five produced video records are marked locally-produced, with public publication fields still null. The first batch MP4 hashes remain unchanged.
