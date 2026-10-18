# Agent Guide: Generating Layers

How to create and manage Lattices workspace layers programmatically. This guide is for AI agents (Claude Code, etc.) that want to generate layers from high-level user descriptions.

## Quick Reference

```bash
# See what's on screen
lats windows --json

# Create a layer with tiling
lats layer create "Design" --json '[
  {"app": "Figma", "tile": "left"},
  {"app": "Google Chrome", "title": "Tailwind", "tile": "right"}
]'

# Snapshot current windows as a layer
lats layer snap "my-context"

# Add a window to the layer you're on, or to a named one
lats layer add wid:1234
lats layer add wid:1234 --to "Design"
lats layer remove wid:1234 --from "Design"

# List / switch / rename / delete
lats layer
lats layer "Design"
lats layer rename "Design" "Figma work"
lats layer delete "Design"
```

## How It Works

Layers live in `~/.lattices/workspace.json`, and they're the ones on the ⌘⌥ pad: the first four layers are ⌘⌥1–4, the next four ⌘⌥6–9 (5 is the pad's centre), and any after that have no digit. The CLI, the daemon API, voice ("save this layout as deploy") and ⌘⌥T all write that file, and a change takes effect at once.

Each window is saved as an entry of its app and its title at the time, which is how the layer finds it again after a restart. While the window stays open it's pinned in, so a title that changes later (a browser switching tabs) doesn't drop it. To make an entry broader, edit its `title` in `workspace.json` down to the part that stays put.

## Step-by-Step: Generating a Layer

### 1. Discover what's available

```bash
lats windows --json
```

Returns an array of window objects:
```json
[
  {
    "wid": 1234,
    "app": "iTerm2",
    "title": "lattices — zsh",
    "latticesSession": "lattices-abc123",
    "frame": { "x": 0, "y": 25, "w": 960, "h": 1050 },
    "spaceIds": [1]
  },
  {
    "wid": 5678,
    "app": "Google Chrome",
    "title": "GitHub - lattices-dev/lattices",
    "frame": { "x": 960, "y": 25, "w": 960, "h": 1050 },
    "spaceIds": [1]
  }
]
```

Key fields for matching:
- `wid` — unique window ID (most precise)
- `app` — application name
- `title` — window title (use for disambiguation when multiple windows of same app)
- `latticesSession` — tmux session name (for terminal windows)

### 2. Decide on a layout

Pick tile positions based on how many windows and what makes sense:

| Windows | Good layout | Tile values |
|---------|-------------|-------------|
| 2 | Side by side | `left`, `right` |
| 2 | Stacked | `top`, `bottom` |
| 3 | Main + sidebar | `left` (60%), `top-right`, `bottom-right` |
| 3 | Columns | `left-third`, `center-third`, `right-third` |
| 4 | Quadrants | `top-left`, `top-right`, `bottom-left`, `bottom-right` |
| 1 | Focused | `maximize` or `center` |

Full position reference:
- **Halves**: `left`, `right`, `top`, `bottom`
- **Quarters**: `top-left`, `top-right`, `bottom-left`, `bottom-right`
- **Thirds**: `left-third`, `center-third`, `right-third`
- **Sixths**: `top-left-third`, `top-center-third`, `top-right-third`, `bottom-left-third`, `bottom-center-third`, `bottom-right-third`
- **Fourths**: `first-fourth`, `second-fourth`, `third-fourth`, `last-fourth`
- **Special**: `maximize`, `center`
- **Custom grid**: `grid:CxR:C,R` (e.g. `grid:5x3:2,1`)

### 3. Create the layer

**Option A: By window ID (most reliable)**
```bash
lats layer create "Coding" --json '[
  {"wid": 1234, "tile": "left"},
  {"wid": 5678, "tile": "right"}
]'
```

**Option B: By app name** (picks the first open window that matches)
```bash
lats layer create "Research" --json '[
  {"app": "Google Chrome", "title": "docs", "tile": "left"},
  {"app": "Notes", "tile": "right"}
]'
```

**Option C: Simple wid list (no tiling)**
```bash
lats layer create "Focus" wid:1234 wid:5678
```

**Option D: Snapshot everything visible** (also what `create` does with no windows named)
```bash
lats layer snap "Current Context"
```

### 4. Switch between layers

```bash
lats layer           # list layers
lats layer "Coding"  # switch to "Coding"
lats layer 1         # switch to the layer on ⌘⌥1
```

Or press ⌘⌥ and the layer's slot number.

## Daemon API (Advanced)

For finer control, use raw daemon calls:

```bash
# Create a layer from window IDs (omit windowIds to save what's on screen)
lats call layers.create '{"name":"Coding","windowIds":[1234,5678]}'

# Add windows to a layer (default: the active one)
lats call layers.assign '{"layer":"Coding","windowIds":[9012]}'

# Take a window out (drops the entries that hold only it)
lats call layers.unassign '{"layer":"Coding","wid":9012}'

# Tile a specific window
lats call windows.place '{"wid":1234,"placement":"left"}'

# Switch layer
lats call layers.activate '{"name":"Coding","mode":"focus"}'

# List layers
lats call layers.list

# Rename / delete
lats call layers.rename '{"layer":"Coding","name":"Deep work"}'
lats call layers.delete '{"layer":"old-layer"}'
```

## Composing Layers from Intent

When a user says something high-level, here's how to think about it:

### "Make me a coding layer"
1. Find terminal windows (iTerm2, Terminal, Warp, etc.)
2. Find browser windows with dev-related titles (GitHub, docs, localhost)
3. Main editor/terminal on `left`, reference material on `right`

### "Set up a design layer"
1. Find design tools (Figma, Sketch, Adobe XD)
2. Find browser windows with design references
3. Design tool `left` (or `maximize`), references `right`

### "Create a writing layer"
1. Find text editors, notes apps (Notes, Obsidian, iA Writer, VS Code with .md)
2. Find research/reference windows
3. Writing app `left` or `center`, references `right`

### "Give me a communication layer"
1. Find messaging apps (Slack, Discord, Messages)
2. Find email (Mail, Gmail in browser)
3. Arrange by priority — primary tool `left`, secondary `right`

### "Split my work into layers by project"
1. Group windows by project (match on title keywords, session names, or app)
2. Create one layer per project group
3. Use the 3-window layout pattern: main `left`, support `top-right`, `bottom-right`

## App Grouping Heuristics

When deciding which windows go together:

| Category | Common apps | Goes well with |
|----------|-------------|----------------|
| **Code** | iTerm2, Terminal, VS Code, Xcode | Chrome (docs/GitHub), Simulator |
| **Design** | Figma, Sketch, Pixelmator | Chrome (design systems), Preview |
| **Writing** | Notes, Obsidian, iA Writer | Chrome (research), Preview |
| **Communication** | Slack, Discord, Messages, Mail | Calendar, Notes |
| **Media** | Spotify, Music, Podcasts | (background, no tile needed) |
| **Reference** | Chrome, Safari, Preview, Finder | (depends on content) |

Browser windows are chameleons — use `title` matching to assign them to the right layer based on their content.

## Tips

- Prefer `wid` when the windows are already open — it's unambiguous.
- Don't put more than 4-5 windows in a single layer — it gets cramped.
- Background apps (music, etc.) usually don't need to be in any layer.
- The `snap` command is great for "save what I have now" scenarios.
- Layers are saved as soon as they're made; `lats layer delete` removes one. The first save of each launch keeps the previous file as `workspace.json.bak`.
- You can create multiple layers in sequence, then switch between them with `lats layer <name>` or ⌘⌥ + slot.
