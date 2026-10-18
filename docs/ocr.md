---
title: Screen OCR & Search
description: Vision-powered screen reading with full-text search for agents
order: 3.5
---

The menu bar app reads text from visible windows using Apple's Vision
framework and keeps the latest results in memory, so `windows.search`,
the command palette and Omni search match windows by what they show.
Agents can use this to "see" what's on screen.

Bundle builds also store every scan in a local SQLite database with FTS5
full-text search. `ocr.search` and `ocr.history` read that
history; the free build doesn't have them.

## Enabling OCR

Open **Settings** (via command palette or gear icon) and toggle
**Search & OCR** on. OCR is disabled by default.

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
| **Quick scan** | 60 seconds | Top 5 windows | Keep recent content fresh |
| **Deep scan** | 2 hours | Up to 15 windows | Catch less-active windows |

Both intervals and limits are configurable in Settings.

### Change detection

Before running OCR on a window, the app captures the window image and
computes a SHA-256 hash of the pixel data. If the hash matches the
previous scan, the cached result is reused. No Vision processing needed.

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
# Search windows by title, app, session, and OCR content
lats search "error"

# Deep search — also inspects terminal tabs and processes
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

Agents can query OCR data through four API methods:

| Method | Description |
|--------|-------------|
| `ocr.snapshot` | Current OCR results for all visible windows |
| `ocr.search` | Full-text search across history (FTS5 syntax) |
| `ocr.history` | Timeline of OCR results for one window, or all windows without `wid` |
| `ocr.scan` | Trigger an immediate deep scan |

#### `ocr.snapshot`

Returns the latest OCR results for all on-screen windows.

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

Trigger an immediate deep scan (all visible windows up to the deep limit).

```js
await daemonCall('ocr.scan')
// { ok: true }
```

## Storage

OCR data is stored in `~/.lattices/ocr.db`, a SQLite database in WAL
(Write-Ahead Logging) mode for safe concurrent reads.

The schema uses two tables:
- `ocr_entry` — stores window ID, app, title, frame, full text, and timestamp
- `ocr_fts` — FTS5 virtual table indexing `full_text`, `app`, and `title`

Triggers keep the FTS index in sync with inserts, updates, and deletes.

Entries older than 3 days are automatically deleted.

## Agent usage

A typical agent workflow: trigger a scan, then search for relevant content.

```js
import { daemonCall } from '@lattices/lattices'

// Trigger a fresh scan
await daemonCall('ocr.scan')

// Search for compilation errors across all windows
const errors = await daemonCall('ocr.search', { query: 'error OR warning' })

for (const result of errors) {
  console.log(`[${result.app}] ${result.title}`)
  console.log(result.snippet)
}

// Read everything currently visible
const snapshot = await daemonCall('ocr.snapshot')
for (const win of snapshot) {
  console.log(`${win.app}: ${win.fullText.slice(0, 200)}`)
}
```

## Requirements

- **Screen Recording** permission — required to capture window images
- Grant via System Settings > Privacy & Security > Screen Recording
- Add the lattices menu bar app to the allowed list
