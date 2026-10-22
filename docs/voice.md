---
title: Voice
description: Voice commands for window management and the lats voice reference, including speech output forwarded to Speech
order: 7
---

Voice commands let you control Lattices by speaking. Press **Hyper+D**
to open the voice command window, hold **Option** to speak, release to
stop. Lattices transcribes your speech via its **embedded Hudson Voice /
Vox runtime**, matches it to an intent, and executes it.

The `voice` domain has two directions with two owners:

| Direction | Verbs | Owner | Transport |
|-----------|-------|-------|------|
| Input: voice commands | `voice.listen`, `voice.stopListening`, `voice.simulate`, `voice.status` | Lattices menu bar app | `lattices.sock`, `voice.sock` |
| Output: spoken text | `voice.say`, `voice.stop`, `voice.pause`, `voice.resume`, `voice.skip`, `voice.seek`, `voice.list`, `voice.select`, `voice.lease`, `voice.release` | Speech (`Voice.app`), reached through the Lattices daemon | `lattices.sock`, `speech.sock` |

This page is the reference for both directions of `lats voice`. Speech output
itself (providers, queue and playback rules, the direct `speech.*` API) is
documented in the [Speech docs](/speech/docs/overview).

## Embedded voice runtime

Lattices **hosts** the voice engine inside the menu bar process. You do not
need a separate `voxd` for normal use. On app boot, Lattices starts an
in-process live-session server and tears it down on quit.

Lattices 0.15.1 and Speech 0.3.0 use private local connections. Install the
Lattices app and CLI at the same version.

### Private connection

| Service | Endpoint |
|---------|-----------------------|
| Agent API / daemon | `~/.lattices/run/lattices.sock` |
| Voice runtime | `~/.lattices/run/voice.sock` |
| Speech's `Voice.app` | `~/.lattices/run/speech.sock` |

The voice runtime uses Vox's private transport: a Unix socket that accepts only
same-user peers and requires the `x-lattices-token` header on the WebSocket
upgrade. Hudson Voice connects with the token for you. The capability file at
`~/Library/Application Support/Lattices/Voice/hudson-voice-runtime.json`
points at the socket. These sockets are local only;
remote voice input is not exposed through the tailnet gateway.

## Quick start

1. Grant microphone access when prompted (Settings → Voice if you skipped it)
2. Optionally connect a voice provider in **Settings > Voice** for provider-backed interpretation and speech services
3. Press **Hyper+D** to open the voice command window
4. Hold **Option** and speak a command
5. Release **Option**. Lattices transcribes and executes

## Voice API

The `voice` domain covers listening and speaking. The daemon serves
listening. Speech's `Voice.app` speaks: the daemon renames each output verb
to its `speech.*` method and forwards it to `Voice.app` through `speech.sock`. Install
or open `Voice.app` from the Lattices menu under **Apps**.

| Verb | CLI | Does |
|------|-----|------|
| `voice.say`     | `lats voice say "text"` | Speak text. Returns the job id; the job is queued, not finished. |
| `voice.stop`     | `lats voice stop` | Stop speaking and clear the queue. |
| `voice.pause` / `voice.resume`     | `lats voice pause` / `resume` | Pause or resume the current job. |
| `voice.skip`     | `lats voice skip` | Skip to the next queued job. |
| `voice.seek`     | `lats voice seek <seconds>` | Seek the current job. |
| `voice.list`     | `lats voice list` | List voices. |
| `voice.select`     | `lats voice select <voice>` | Choose the default voice for a provider. |
| `voice.lease` / `voice.release` | none | Hold the speaker so other agents do not talk over you. A lease also ends when the connection closes. |
| `voice.listen`     | `lats voice listen` | Start voice capture. |
| `voice.stopListening`     | `lats voice stopListening` | Stop voice capture and run the transcript. |
| `voice.simulate`     | `lats voice simulate "text"` | Parse and run a command as if spoken. |
| `voice.status`     | `lats voice status` | Listening state, plus the Voice helper under `helper`. |

`voice.stop` used to stop listening. It now stops speaking. For one
release, a `voice.stop` made while Lattices is listening and nothing is
speaking fails with `voice_stop_changed` and points to
`voice.stopListening`.

If the Voice helper is not installed, the speaking verbs fail with
`helper_not_installed` and the fix: **Lattices › Apps › Install Voice**.
If it is installed but not running, they fail with `helper_unreachable`;
open Voice from **Lattices › Apps**. There is no fallback. Speaking verbs
need the helper's local capability
(`~/Library/Application Support/Speech/RPC/capability`), which exists only
while Voice runs; the `lats` CLI sends it for you, and a client that
does not gets `helper_unauthorized`. The daemon still accepts the older `speech.*` names, and
sends each `speech.changed` event again as `voice.changed`.

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| **Hyper+D** | Open/close voice command window |
| **⌥ (hold)** | Push-to-talk: hold to record, release to stop |
| **Tab** | Arm/disarm the mic |
| **Escape** | Cancel recording or dismiss window |

## Built-in commands

### Search

Find windows by app name, title, content, or category.

```
"Find all vox windows"
"Find terminals"           → expands to iTerm, Terminal, Warp, etc.
"Show me all browsers"     → expands to Safari, Chrome, Firefox, Arc, etc.
"Where is my editor?"      → expands to VS Code, Cursor, Xcode, etc.
```

Category synonyms are built in. Saying "terminals", "browsers", "editors",
"chat", "music", "mail", or "notes" automatically expands to search for
the actual app names.

### Tile

Move windows to screen positions.

```
"Tile this left"
"Snap to the right half"
"Maximize the window"
"Put this in the top right corner"
```

Voice tiling should resolve into the same canonical daemon mutation used
by other agent surfaces: `windows.place`.

### Focus

Bring a window or app to the front.

```
"Focus Safari"
"Switch to Slack"
"Go to the lats window"
```

### Open / Launch

Open applications or project workspaces.

```
"Open Spotify"
"Launch the vox project"
```

### Kill

Close windows or quit applications.

```
"Kill this window"
"Close Safari"
"Quit Spotify"
```

### Scan

Trigger an OCR scan of visible windows.

```
"Scan the screen"
"Read what's on screen"
```

### Other

```
"List all windows"
"Show my sessions"
"Switch to layer 2"
"Help"
```

## AI advisor

Every voice command can ask the selected voice provider for
commentary and follow-up suggestions in the **AI corner** (bottom-right
of the voice command window).

When local matching handles the command well, the AI corner shows
"no AI needed" with an optional "ask AI" button. When the advisor
has something useful, it shows a one-line comment and an actionable
suggestion button.

### How it works

1. You speak a command
2. Local intent matching runs immediately (fast, free)
3. The selected voice provider runs in parallel when connected
4. If the advisor suggests something, a button appears in the AI corner
5. Click the suggestion to execute it
6. If you engage with a suggestion that the local matcher missed,
   it's recorded in `~/.lattices/advisor-learning.jsonl` for future
   improvement

## Hands-off inference

Hands-off voice uses the shared inference wrapper in `bin/infer.ts`.
By default it chooses the lowest-latency configured provider and, when
Groq credentials are present, uses `groq/llama-3.1-8b-instant`.

Credentials are read from process env, `.env.local`, `.env`,
`~/.lattices/inference.json`, then the macOS Keychain.
For Groq, either `GROQ_API_KEY` or the common typo `GROK_API_KEY` works
when the key has Groq's `gsk_` prefix.

Override the voice engine if needed:

```bash
LATTICES_VOICE_PROVIDER=groq
LATTICES_VOICE_MODEL=llama-3.1-8b-instant
```

## Configuration

Open **Settings > AI** to inspect Scout chat status, and **Settings > Voice**
to configure the optional voice provider:

| Setting | Default | Description |
|---------|---------|-------------|
| Workspace chat | Scout | Uses the existing local Scout broker and Scout-owned authorization; Lattices does not store a separate chat key. |
| Voice provider | OpenAI | Optional direct HudsonAI provider used only by provider-backed voice interpretation and speech services. OpenAI, Anthropic, and OpenRouter are supported. |
| Voice provider credentials | Not authenticated | Save an optional voice-only API key locally in the macOS Keychain. |

## Layout

The voice command window has four sections:

| Section | Position | Content |
|---------|----------|---------|
| **History** | Left column | Past commands with expandable details |
| **Voice Command** | Center column | Current transcript, matched intent, results |
| **Log** | Top-right | Rolling diagnostic log (last 12 entries) |
| **AI Corner** | Bottom-right | Advisor commentary, suggestions, provider readiness |

## Search architecture

Voice search uses the same backend as `lats search`:

1. **Quick search**: window titles, app names, session tags (instant)
2. **Complete search**: adds terminal cwd/processes + OCR content
3. **Synonym expansion**: category terms like "terminals" expand to
   actual app names before searching
4. **Query cleanup**: strips natural language qualifiers ("and sort by...",
   "please", "for me") before searching

## Processing resilience

- **15-second timeout**: if processing doesn't complete, returns to idle
- **Cancellation on dismiss**: closing the window cancels in-flight work
- **Double-execution prevention**: streaming and stop callbacks can't
  both fire the intent

## Advisor learning

When the local matcher fails but the AI advisor suggests something that
you engage with, the interaction is recorded:

```
~/.lattices/advisor-learning.jsonl
```

Each line is a JSON object:

```json
{
  "timestamp": "2026-03-15T18:30:00.000Z",
  "transcript": "find all terminals",
  "localIntent": "search",
  "localSlots": {"query": "terminals"},
  "localResultCount": 0,
  "advisorIntent": "search",
  "advisorSlots": {"query": "iterm"},
  "advisorLabel": "Search iTerm"
}
```

This dataset captures where the local system falls short and what the
right answer was. Future work can mine it for automatic synonym
mappings and phrase pattern improvements.

## Requirements

- **Embedded voice runtime**: the in-process Vox runtime on `voice.sock` provides
  speech-to-text. It ships inside builds that include Hudson Voice; no
  separate `voxd` install is needed
- **Microphone** permission: for voice capture
- **Voice provider**: enables provider-backed AI suggestions from
  **Settings > Voice** (optional, voice commands still work without it)
- **Accessibility** permission: for window tiling and focus
- **Screen Recording** permission: for window discovery
- **Speech (`Voice.app`)**: only for the output verbs such as `lats voice say`.
  See [Speech quickstart](/speech/docs/quickstart)
