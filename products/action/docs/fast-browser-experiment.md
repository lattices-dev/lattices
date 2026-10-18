# Fast browser experiment

Action's Chrome companion has an opt-in observation-bound execution path inspired by
[Jev Ultrafast](https://github.com/browser-use/jev-ultrafast). It uses the existing
Chrome companion bridge and an explicit tab ID. It does not change native Action
execution or Lattices app behavior.

## Run

Build the companion with `bun run chrome:companion:build` and reload the development
extension in the dedicated Action browser profile. The bridge must be running and
connected. This source change does not update an already loaded extension.

Create a trusted local policy module, for example:

```ts
import { createFastBrowserPolicy } from "@action/runtime";
export default createFastBrowserPolicy({
  baseURL: process.env.ACTION_FAST_MODEL_BASE_URL!, // API base, including /v1 if required
  apiKey: process.env.ACTION_FAST_MODEL_API_KEY!,
  model: process.env.ACTION_FAST_MODEL!,
  textModel: process.env.ACTION_FAST_TEXT_MODEL,
  // Define an independent, task-specific outcome assertion before starting.
  // Example for a goal whose outcome is reaching one exact article:
  verify: async (_goal, page) => page.url === process.env.ACTION_FAST_EXPECTED_URL,
});
```

From the Action product directory:

```sh
bun packages/cli/src/fast-browser.ts <tab-id> <policy-module-path> '<goal>'
```

The policy module is executable operator-supplied code. Never load a module named
by page content or model output. Model calls use an OpenAI-compatible JSON chat
completion endpoint. The caller selects models; no vendor or model is pinned.
This provider combines operation and target in one JSON response. It does not
implement TypeSafe's speculative heads or imply equivalent inference latency.

## Contract

- `action.fast.observe`, params `{ surface: { tabId } }`, returns an observation ID,
  URL, title, bounded visible text, and at most 80 controls with compatible operations.
- `action.fast.act`, params `{ surface: { tabId }, observationId, target, operation,
  text? }`, returns `executed`, `stale`, `invalid`, or `uncertain` and execution timing.
- Only CLICK and TYPE_TEXT are offered. Text generation is separate and invoked
  only for TYPE_TEXT. Password/file fields and unsupported input types are excluded.
- Each observation can be consumed once. A new observation replaces the previous
  one. Targets retain DOM node identity; execution never resolves a model selector.
- Before input, check document URL/viewport/form values, target semantics and nearby
  context, eligibility, current geometry, and occlusion. Unrelated changes outside
  the target's context do not automatically invalidate a decision.
- Confirmed stale rejections may retry from a fresh observation. Lost execution
  replies and uncertain mutations stop the loop. Executed means input was issued;
  it does not prove the application accepted it.
- DONE requires a fresh observation and the caller's independent verifier. False
  verification ends as `unverified`. The default budget is 20 decisions.

Each step emits observe, choose, text, and execute durations. Execution receipts are
emitted before another observation. Total elapsed time includes initial observation
and final verification, but excludes browser setup and policy module loading.
The snapshot also reports time inside the DOM reader. JSON traces can contain
field-derived/page information; store them appropriately for the task.

## Verify and measure

```sh
bun test packages/runtime/src/fast-browser.test.ts packages/runtime/src/providers/fast-browser-model.test.ts
bun run typecheck
bun run chrome:companion:build
# Supply a Playwright module path if it is not installed locally.
ACTION_PLAYWRIGHT_MODULE=/path/to/playwright \
ACTION_CHROME_EXECUTABLE=/path/to/chrome \
bun packages/chrome-companion/scripts/check-fast-actions.mjs
```

The browser checks run the actual content-script message handlers in an isolated
headless browser. They cover changed/replaced/covered/hidden/disabled/moved targets,
form changes, unrelated updates, duplicate requests, invented targets, and typing.
They do not exercise the installed extension's bridge or a live model. A
recorded presentation run is reproducible via
`packages/chrome-companion/scripts/demo-presentation.mjs` (dedicated fixture
browser, video artifact under `artifacts/presentation-demo-*`).

Compare identical tasks and model settings with the existing path, retaining failed
runs. Report independent completion, wrong actions, stale rejections, uncertain
execution, timings, and model cost separately. No speedup has been established by
these implementation/guard checks.

Limitations: common light-DOM controls only; no frames, shadow DOM, canvas, native
selects, scrolling, arbitrary keyboard widgets, or full page stabilization.
Text and target context are bounded and do not implement the full accessible-name
algorithm. The extension uses DOM click/value events, which may be rejected by sites
requiring trusted physical input. After executed input, the loop waits up to two seconds for a visible snapshot
change before choosing again. An unchanged snapshot blocks rather than repeating
input. Unrelated visible changes can also release this wait; it is not a general
page-ready signal. All decisions count toward the budget. One loop at a time per tab.


## Live Jev runner

`createJevPolicy` calls TypeSafe System One with the `jev-latest` alias. Operation,
click target, and typing target use parallel choice heads in one request. The
runtime consumes only the target head matching the selected operation and records
the concrete model version, confidence, probabilities, and usage. Typing content
comes from a separately configured text provider.

From the Action directory, with the extension connected to its local bridge:

```sh
# Inject credentials through your secret manager; do not put them in source.
# TYPESAFE_API_KEY is required. Typing also needs TEXT_MODEL,
# TEXT_MODEL_BASE_URL, and TEXT_MODEL_API_KEY.
bun scripts/demo-jev.ts <tab-id> <exact-result-url> '<goal>'
```

`TYPESAFE_MODEL` optionally overrides the alias. `ACTION_DEMO_OUTPUT` selects the
artifact directory. Use a fresh directory per attempt. The runner saves decisions,
execution receipts, timings, and an independently checked exact destination URL.

Live evidence on 2026-09-19: Jev resolved to `jev-1.13.0` and drove the installed
Action extension from Wikipedia's main page to Gödel's incompleteness theorems.
The corrected run took 2774 ms: TYPE_TEXT, CLICK, DONE, with the destination URL
verified. Google Gemini Flash Lite supplied the search text. The preceding run
repeated Search while navigation was pending; this prompted the progress wait and
its regression tests. This is a single task result, not a comparative benchmark.
The replay captures Chrome's actual rendered frames; desktop capture was unavailable
because the dedicated window remained on another macOS Space.


## Watchable mode

Set `ACTION_WATCH=1` for the single-search runner. The transport activates the
explicit tab and focuses its Chrome window. The executor shows a soft coral
disc pointer and target outline before input, revalidates after the movement,
and shows an input receipt. This is a synthetic Action pointer, not the OS
cursor. Confirmed clicks bloom ripple bubbles at the point of input; stale
rejections never produce a bubble or pulse. TYPE_TEXT enters text in real
progressive chunks, and each chunk plays a subtle WebAudio tick and outline
flash — sound marks characters actually written, never simulated replay.
`ACTION_SOUND=0` mutes ticks; `ACTION_VOLUME` (0–1, default 0.35) sets tick
level. Reduced-motion settings skip spatial animation and bubbles. Feedback
lives in an isolated, non-interactive closed shadow tree excluded from
observations and target resolution. Presentation time is included in execution
timing, so compare it separately from fast mode. Native recording captures it
when the Chrome window is on screen.

`bun scripts/demo-jev-ten.ts <tab-id>` runs ten Wikipedia searches with this mode,
independent exact-URL verification, per-search traces, and 2.2-second result holds.
It stops on failure or uncertainty and writes `summary.json` after every result.
Supply the same Jev and text-provider environment as the single-search runner.

Navigation receipts for same-tab links and form submission require a changed URL
before the next decision; changing autocomplete suggestions alone are insufficient.
Brief missing-content-script errors during navigation retry observations only.
Input is never replayed on a lost execution reply.
