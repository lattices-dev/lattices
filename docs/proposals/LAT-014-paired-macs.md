# LAT-014: Paired Macs, and driving one from another

Status: Proposed, 2026-10-07. Builds on [LAT-012](LAT-012-domain-api.md) (domains and verbs),
[LAT-013](LAT-013-linux-host.md) (the Linux host) and the run ledger from #170. The pairing model is OpenScout's mesh enrollment, as fab ported it to Swift
for Hush (`~/dev/fab/design/notes/hush-pairing-study.md`). The shared parts move into a new Hudson
package so Lattices, fab and later Scout's native apps use one implementation.

## Summary

Today Lattices on one Mac can't be driven from another, except over SSH. Anyone with a shell is
trusted completely, nothing is asked, and nothing records which Mac did it.

This proposal adds:

- **Paired Macs.** Each Mac has a Keychain identity. Two Macs pair once by confirming the same six
  words on both, and then talk over pinned mutual TLS.
- **The link.** A listener, separate from the agent API, that passes calls from paired Macs into the
  same router, limited to what that Mac was granted.
- **Remote addressing.** `lats --on arts-mini search vox`, and a `host` parameter on MCP tools. The
  local app makes the call; the CLI never holds keys.
- **`HudsonLink`.** Identity, pairing, pinned TLS, trust records and the peer store, pulled out of
  fab's `HushLink` into Hudson. Fab moves onto it, then Lattices builds on it.

## What exists

### LAT-013, the Linux host

`lattices-host` (`packages/host-linux`) already serves the daemon protocol on the tailnet and admits
a connection when `tailscale whois` says it's one of the owner's untagged devices. That answers
LAT-013's open question of whether a Mac should expose itself too: it should, but through the pairing
here, not tailnet identity alone. Tailnet identity says the device is yours. Pairing and grants say
what that device may do to this Mac. Once HudsonLink exists, the Linux host can accept a paired
identity alongside `whois`, so one fleet has one trust story.


### Lattices

- **Agent API.** `DaemonServer` on `127.0.0.1:9399`, with no authentication. The trust model is "you
  are a local process".
- **Action agent.** `127.0.0.1:4319`. Drive leases record `client` and `clientProcess` (#170), but
  any local connection can take one. Attention approval isn't built.
- **Companion bridge** (`apps/mac/Sources/Bundle/Companion/`):
  - Listens on port 5287 and advertises `_lattices-companion._tcp`.
  - Pairs the iPad with a Mac-side alert ("Allow a device to control this Mac?").
  - Per-device Curve25519 keys; signed, encrypted, replay-checked requests.
  - Per-device capabilities, checked by `requireCapability`.
  - It's in the bundle tier only, and it's built for one iPad, not a set of Macs.
- **Voice runtime.** Meant to listen on loopback (`LatticesLocalEndpoints.loopbackHost`), but 0.13.3
  on arts-mini listens on `*:9398`. That's a bug, fixed in phase 0.

### fab Hush

`~/dev/fab/cli/native/FabPanel/Sources/HushLink/` is about 3,400 lines of Swift. It shipped in fab
0.2.9 with confirm-on-both pairing. Most of it is general, not Hush-specific:

| File | What it is | Moves to Hudson |
|---|---|---|
| `Identity.swift` | P-256 key and self-signed cert, in the Keychain | yes |
| `TLS.swift` | TLS 1.3, both certs, verify by pin | yes |
| `Store.swift` | identity and pins in the Keychain, peers on disk | yes, with the paths injected |
| `Confirm.swift` | commit, reveal, words, confirm MACs, the Busy rule | yes, words count injected |
| `PairLink.swift` | pairing listener and Nearby over Bonjour | yes, service names injected |
| `Trust.swift` | signed tombstones and introductions | yes |
| `Framed.swift` | framed reads for short exchanges | yes |
| `Link.swift` | Bonjour link, one connection per pair, hello | the connection and hello; messages stay |
| `Wire.swift` | frames, messages, peer table | frames and peer table; Hush messages stay |
| `Control.swift` | `hush.sock` commands | no, stays in fab |
| `Pair.swift` | v2 typed-code pairing | no, superseded by v3 |

### OpenScout

The same shape in TypeScript, in the broker: `packages/runtime/src/mesh-sas.ts`,
`mesh-trust-enrollment.ts` and `docs/proposals/mesh-trust-cone.md`. We follow its decisions (commit
then reveal, approval on both sides, six words when the grant is agent control) and leave its code
where it is.

### Hudson

- #255 added held notch cards (`HudNotchHeld`, `HudNotchHold`), the words row and the you/them state
  (`HudNotchConfirmViews`).
- `HudsonUICapture/HudPairing.swift` has a pairing payload and an in-memory trust store. The fab study
  lists a Keychain trust store as missing.
- Lattices links `HudsonUI`, `HudsonShell`, `HudsonAI` and `HudsonObservability`, not `HudsonNotch`.

## HudsonLink

Two targets, following the Notch split:

- **`HudsonLinkCore`.** Pure and testable without a network: the pairing transcript, commit, words,
  confirm MACs, the pairing state machine and the Busy door, tombstones and introductions, frames,
  the peer table. Depends on CryptoKit and Foundation.
- **`HudsonLink`.** The parts that touch the system: Keychain identity and pins, TLS 1.3 with pinning,
  Bonjour advertise and browse, the pairing listener, the link connection and its hello.

Each app configures it:

```swift
let link = HudsonLink(configuration: .init(
    product: "lattices",                       // ALPN "lattices-link/1", "lattices-pair/3"
    linkService: "_lattices-link._tcp",
    pairService: "_lattices-pair._tcp",
    port: 9396,
    words: 6,                                  // fab passes 4
    keychainService: "com.arach.lattices.link",
    stateDirectory: latticesHome.appending(path: "link")
))
```

`words` is the only security parameter. Each word indexes a 256-word list with one byte, so six words
is 48 bits. A man in the middle gets one blind guess per attempt, and every failed attempt shows
"Not mine" to a person and starts a one-hour cooldown.

What stays in each app: the messages carried over the link, what a peer is allowed to do, and the UI
copy.

## The Lattices link

### Listening

- The link listens on port **9396**, next to the speech companion (9397), the voice runtime (9398) and
  the agent API (9399). It's the only Lattices listener that isn't on loopback.
- An unpaired Mac fails the TLS handshake and never reaches the router.
- The agent API stays on `127.0.0.1:9399`, unchanged.
- `Info.plist` declares `_lattices-link._tcp` and `_lattices-pair._tcp` in `NSBonjourServices`, and
  sets `NSLocalNetworkUsageDescription`. fab found that macOS won't advertise or browse without the
  declaration (fab `c19109d`).

### Calls

- Over the link, a call is the same `{method, params}` the daemon router already takes, plus the
  caller: `{peerId, name, fingerprint, grants}`.
- The router checks grants before dispatch. A method that isn't in the grant table is refused.
- The reply goes back over the link unchanged.

### Grants

| Grant | Allows | Default at pairing |
|---|---|---|
| `read` | windows, search, layers, OCR search, status | on |
| `act` | focus, place, tile, layer switch, launch | on |
| `drive` | `computer.*` (Action drive leases, clicks, typing) | off |

- The paired Mac's row in Settings turns grants on and off.
- Turning on `drive` asks on this Mac, never on the asking Mac. It's the same rule as the companion
  bridge's capability upgrade ("Allow more access for this device?").

### Driving through Action

- A `computer.*` call from a peer begins its Action lease with:
  - `client` set to `Lattices link: <peer name>`;
  - `clientProcess` set to the peer's short fingerprint.
- The run ledger then shows which Mac drove each run, with no new fields.
- The supervision HUD on the driven Mac already shows the agent and task, so a person at that Mac sees
  remote driving while it happens.

### Remote addressing

- `lats --on <peer> <command>` and an optional `host` parameter on MCP tools.
- The CLI asks the local app (`link.call {peer, method, params}` on 9399), and the app makes the call
  over the link. Keys never leave the app. That's fab's rule: the app owns the Keychain, so it works
  over SSH too.
- `lats link nearby` lists Macs that advertise the link and aren't paired.
- `lats link pair <peer|host>` starts a pairing.
- `lats link list` shows paired Macs, their grants and whether they're linked.
- `lats link forget <peer> [--all]` forgets a Mac here, or on every paired Mac.

## Tier

Paired Macs ship in the bundle (full) build only, like the companion bridge. The free build has no
link listener, no pairing and no `--on`; `lats link` there says it needs the full build. Decided
2026-10-07.

The Lattices side lives under `apps/mac/Sources/Bundle/Link/`, beside `Bundle/Companion/`, and
`HudsonLink` is linked only into the bundle build. Phase 0 is the exception: the loopback fix ships
in both builds.

## Pairing

The same ceremony as fab Hush, with six words:

1. On mini, Settings › Paired Macs › Nearby lists arts-mini. Click **Pair…**, or run
   `lats link pair arts-mini`.
2. Both Macs finish the handshake and show the same six words.
   - mini shows them inline in Settings, or in the terminal.
   - arts-mini shows them in a held notch card: "mini wants to drive this Mac.", the words, and the
     model, user and short fingerprint of the asking Mac.
3. Confirm on both, in either order. The card waits as long as it takes; after the usual peek it
   folds to a one-line chin and stays valid.
4. Each side pins the other only after its own confirm and the peer's. The link connects.

Errors and recovery follow the fab study unchanged: not mine, later, can't reach, two asked at once,
new identity, keychain locked, and a 30-minute quiet cap.

**Over SSH.** `lats link pair` prints the words and asks "Same six words on arts-mini? [y/N]". `y`
counts as that Mac's confirm. A shell already means ownership, and that's how arts-mini gets paired
when nobody is at it.

**Introductions.** On by default, as in fab. Pair a new Mac once with any of your Macs, and the
others learn it with a signed record. A Mac learned this way starts with `read` only. Grants are never
introduced, so `drive` is always granted on the Mac being driven.

## UI

- **Settings › Paired Macs.**
  - This Mac: name, short fingerprint, Reset identity.
  - Your Macs: status, last seen, grants, rename, forget.
  - Nearby, and Add by address (tailnet).
  - Introductions toggle.
  - Built with HudsonUI primitives and Lattices' own type and color (the settings token split).
- **Notch.** Lattices links `HudsonNotch` for the held pairing card, the words row and the you/them
  state from #255. It's only used for pairing and its results; the notch never holds management.

## Phases

0. **Loopback audit.** Bind the voice runtime to `127.0.0.1`, and add a test that every Lattices
   listener except the link is on loopback.
1. **HudsonLink.**
   - Extract `HudsonLinkCore` and `HudsonLink` from fab's `HushLink`, with its tests.
   - Move fab onto it in the same pass, with no change in behavior: Hush pairs, links and forgets as
     in 0.2.9.
   - Hudson PR first, then the fab PR.
2. **Pair and link.**
   - Lattices identity, the 9396 listener, pairing, Settings › Paired Macs and the notch card.
   - `read` and `act` grants, the `lats link` commands and `--on`.
3. **Drive.**
   - The `drive` grant and `computer.*` over the link.
   - Run ledger attribution.
   - MCP `host` parameter.
4. **Later.**
   - Typed words for Macs out of view (CPace, from fab's phase 2).
   - "Scout says so" pairing (fab's phase 3).
   - Moving the iPad companion bridge onto HudsonLink, so there's one trust system.

## Open questions

- **Permission for each drive.** Should a peer with `drive` also need a held notch card for each new
  lease ("arts-mini: mini wants to drive · Codex · Rename the layer")? It's off in this proposal: the
  grant and the supervision HUD carry it.
- **Fab copy.** Do fab and Lattices on the same Mac share one identity? This proposal keeps them
  separate: different Keychain services, separate pairing. Sharing would need one owner app.
- **Wake.** Waking a sleeping Mac for a call (Bonjour Sleep Proxy) or failing fast. fab waits.
