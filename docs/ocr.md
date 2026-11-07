---
title: Screen OCR & Search
description: Screen-text indexing and search through Accessibility and Vision
order: 3.5
---

In current source builds, quick and single-window scans read eligible
on-screen windows through Accessibility. Deep scans use Apple's Vision
framework to recognize text in window images. The latest results stay in
memory for screen-text search.

Bundle builds also store changed text in a local SQLite database with FTS5
full-text search. `ocr.search` and `ocr.history` read that
history; the free build doesn't have them.

[Screen-text security](security-screen-text.md) defines collection rules,
exclusions, retention and remote grants for the unshipped source changes.
Window capture can include covered content. Indexing does not guarantee
private-tab detection or secret removal.

## Enabling OCR

Open **Settings** (via command palette or gear icon) and toggle
**Search & OCR** on. OCR is disabled by default.

In current source builds, turning indexing off blocks scheduled and manual
scans. Excluded apps are skipped by all scan types. Changing either setting
invalidates pending results before publication or persistence. Existing saved
history remains until expiry or **Clear saved history**.

### Accuracy modes

| Mode | Description |
|------|-------------|
| **Accurate** (default) | Higher quality recognition, slower processing |
| **Fast** | Lower latency, reduced accuracy |

Both modes use `VNRecognizeTextRequest` with language correction enabled.

## How scanning works

The app runs two scan schedules:

| Schedule | Interval | Window limit | Purpose |
|----------|----------|-------------|---------|
| **Quick scan** | 60 seconds | Top 5 eligible windows | Refresh Accessibility text |
| **Deep scan** | 2 hours | Up to 15 eligible windows | Recognize text from window images |

Both intervals and limits are configurable in Settings.
Deep scans prioritize stale windows and limit Vision work to the configured
per-pass budget, which defaults to three windows.

### Change detection

Before Vision processing in a deep scan, the app captures the window image and
computes a SHA-256 hash of the pixel data. If the hash matches the
previous Vision scan, the cached result is reused without new recognition.

This keeps CPU usage low when windows haven't changed. A 100ms throttle
between windows further limits processing bursts.

## Browsing results

The **Recent Captures** section in Settings shows OCR results grouped by
app. Each entry displays the window title, recognized text preview, and
timestamp.

## Searching

### From the command palette

The OmniSearch bar (Control+Option+Space) searches OCR content alongside windows,
projects, and sessions. Matches show as "Screen Text" results with
contextual snippets.

### From the CLI

```bash
# Search window and terminal metadata
lats search "error"

# Search the cached screen-text index explicitly
lats search "error" --sources=ocr

# Deep search includes OCR, terminal metadata and processes
lats search "myproject" --deep

# Same as --deep (all search sources)
lats search "myproject" --all

# Search + focus + tile the top result
lats place "myproject" left

# View current OCR snapshot
lats scan

# Search OCR history directly (FTS5 syntax)
lats scan search "error OR failed"

# Trigger an immediate deep scan
lats scan deep

# View OCR history for a specific window ID
lats scan history 12345
```

### From the agent API

Agents can read the live index or request a scan. Bundle builds also provide
the history methods:

| Method | Description |
|--------|-------------|
| `ocr.snapshot` | Latest cached results for indexed windows |
| `ocr.search` | Full-text search across history (FTS5 syntax) |
| `ocr.history` | Timeline of OCR results for one window, or all windows without `wid` |
| `ocr.scan` | Request a deep scan while indexing is enabled; exclusions still apply |

#### `ocr.snapshot`

Returns the latest cached results for indexed windows. It does not trigger a
scan or guarantee coverage of every on-screen window.

```js
import { daemonCall } from '@lattices/lattices'

const snapshot = await daemonCall('ocr.snapshot')
// [{ wid, app, title, frame, fullText, blocks, timestamp }, ...]
```

Each result includes:
- `wid` — window ID
- `app` — application name
- `title` — window title
- `frame` — `{ x, y, w, h }` screen position
- `fullText` — all recognized text concatenated
- `blocks` — individual text blocks with `{ text, confidence, x, y, w, h }`
- `timestamp` — Unix timestamp of the scan

#### `ocr.search`

Full-text search across OCR history using FTS5 query syntax.

```js
const results = await daemonCall('ocr.search', {
  query: 'error OR failed',  // FTS5 query (required)
  app: 'Terminal',            // filter by app name (optional)
  limit: 50,                  // max results (optional, default 50)
  live: false                 // search in-memory snapshot instead of history (optional)
})
// [{ id, wid, app, title, frame, fullText, snippet, timestamp }, ...]
```

The `snippet` field contains FTS5-highlighted text with `«` and `»`
delimiters around matched terms.

#### `ocr.history`

Get the OCR content timeline for a specific window, or across every window
when `wid` is omitted.

```js
const history = await daemonCall('ocr.history', {
  wid: 12345,  // window ID (optional; omit for every window)
  limit: 50    // max results (optional, default 50)
})
```

#### `ocr.scan`

Request an asynchronous deep scan of eligible windows within the configured
limits. The reply acknowledges the request, not completion. If indexing is
disabled, no new scan starts. Subscribe to `ocr.scanComplete` when a workflow
depends on completion rather than the existing cache.

```js
await daemonCall('ocr.scan')
// { ok: true }
```

## Storage

Bundle builds store OCR history in `~/.lattices/ocr.db`, a SQLite database in
WAL (Write-Ahead Logging) mode. Store operations share a serial queue. The
database and sidecars use owner-only permissions (`0600`).

The schema uses two tables:
- `ocr_entry` — stores window ID, app, title, frame, full text, and timestamp
- `ocr_fts` — FTS5 virtual table indexing `full_text`, `app`, and `title`

Triggers keep the FTS index in sync with inserts, updates, and deletes.

The retention default is seven days. Each query applies the current cutoff;
periodic maintenance deletes expired rows. Turning indexing off or excluding
an app does not delete saved history. **Clear saved history** invalidates old
scans and deletes saved rows and search terms. New scans can start while
indexing remains enabled. Clearing is not a forensic purge and does not remove
backups.

## Agent usage

Search the existing cache or saved history for an immediate result. A
requested refresh runs asynchronously and can finish after that search.

```js
import { daemonCall } from '@lattices/lattices'

// Request a refresh; the reply does not mean scanning has finished
await daemonCall('ocr.scan')

// Search saved history, which can precede the requested refresh
const errors = await daemonCall('ocr.search', { query: 'error OR warning' })

for (const result of errors) {
  console.log(`[${result.app}] ${result.title}`)
  console.log(result.snippet)
}

// Read the latest cached screen-text results
const snapshot = await daemonCall('ocr.snapshot')
for (const win of snapshot) {
  console.log(`${win.app}: ${win.fullText.slice(0, 200)}`)
}
```

## Requirements

- **Screen Recording** permission — required to capture window images
- Grant via System Settings > Privacy & Security > Screen Recording
- Add the lattices menu bar app to the allowed list
