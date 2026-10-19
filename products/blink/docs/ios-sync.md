# Canvas iOS snapshot contract

## Scope

The first iOS surface is a read-only, offline-capable view of the same note files
the Mac app and `canvas` CLI use (`blink` remains compatible). It starts with
LAN as its only enabled route,
but its transport boundary can later use Hudson's Tailscale or managed-relay
providers without changing Canvas's replication model.

This describes the current source companion, whose display and product names
are Canvas. The rename is not evidence of a published iOS release. The Xcode
project and target remain `BlinkMobile`, and the bundle ID stays
`dev.arach.blink.mobile`. The Mac keeps `dev.arach.blink`. Existing Keychain
services, cache and preference keys, Bonjour service `blink-notes`
(`_blink-notes._tcp`), and the `BlinkPeer` wire format are unchanged, so the
rename alone does not invalidate paired devices or cached notes.

## Ownership

- Hudson owns generic peer identity/trust models, route providers, route
  settings, cascade, and diagnostics.
- Canvas owns snapshots, note revisions, tombstones, quarantine, workspace/style
  projection, attachment policy, offline cache, iOS UI, and the first proven LAN
  peer channel in `BlinkPeer`.
- OpenScout donates generic route and connection behavior to Hudson while OSN
  remains an OpenScout provider.

## V1 snapshot

The Mac returns one complete `BlinkSnapshot`:

- exact UTF-8 bytes of each frontmattered Markdown file;
- a SHA-256 revision for each note;
- a strong whole-snapshot ETag;
- parsed summary fields for native list rendering;
- durable tombstones for absent notes;
- quarantine issues for unreadable, malformed, or identity-divergent files.

Each quarantine issue names the expected filename identity. An iOS cache keeps
its last known value for that identity until the file becomes readable again or
an explicit tombstone arrives; quarantine is never interpreted as deletion.

The mobile app atomically replaces its cached snapshot on a successful changed
response and retains it on an authenticated not-modified response. The cache is
atomically bound to the authenticated Mac agreement public key that produced
it: connecting to a different key forces a full snapshot and never merges
quarantined notes across hosts. The same record stores the latest successful
sync time, including authenticated not-modified responses. Because the cache is
replaceable and contains note bodies, every atomic replacement is marked
excluded from device backup. **Remove Notes** disconnects any live or pending
peer operation before deleting it, so an automatic refresh cannot recreate the
cache after confirmation.

`generatedAt` is diagnostic and is excluded from the ETag. A corpus that has not
changed therefore remains cacheable across requests and app launches.

## Consistency

V1 deliberately avoids a manifest-then-live-file race: note bodies travel in the
same snapshot response as their revisions. `BlinkSnapshotBuilder` requires two
identical consecutive directory reads before publishing. Atomic note writes
prevent torn individual files; the repeated capture prevents a directory change
from being presented as a stable snapshot.

If the corpus later becomes too large for full snapshots, the replacement must
use immutable snapshot leases keyed by generation. Fetching a manifest and then
reading current live files by id is not an acceptable incremental design.

## Encrypted LAN transport

On a new Mac install, enable **Mobile Access** in Canvas's right-click menu to
start pairing. The 2.3.0 upgrade preserves explicit `behavior.mobileAccess`
choices. If an older config has no such key, valid existing Keychain approvals
keep access enabled without rewriting the config. Missing or malformed trust
data and Keychain failures leave it off. This preserves already approved
devices without enabling sharing for a new installation.

The snapshot replication and cache layer depends only on `BlinkPeerTransport`.
The current mobile model selects its concrete LAN discovery client directly; a
future route cascade requires a separate discovery/connection orchestrator but
does not require a new snapshot format. The first implementation uses Bonjour
discovery through Multipeer Connectivity with
`MCEncryptionPreference.required`; there is no plaintext HTTP listener. Bonjour
advertises a stable Mac host identity and Curve25519 agreement public key. Every
application payload is then sealed end to end with a per-connection key using
ChaChaPoly, independently of the Multipeer transport encryption.

The Mac accepts a peer session but serves nothing until the mobile app requests
access inside that sealed channel. Each app installation keeps a private random
seed in a non-migrating, ThisDeviceOnly Keychain item and derives a different
credential for each Mac public key; the reusable seed never leaves the device
or travels in a backup. A short, non-secret seed fingerprint distinguishes
otherwise generic iPhone/iPad names in approval and revocation UI. Allowing the
request stores only that host-scoped credential, so later connections from the
same installation do not repeat the prompt. A relay, lookalike host, or
same-network observer cannot decrypt the payload or reuse the credential.
Same-network presence is discovery, never authorization.

The credential — not the Multipeer peer identity — is the authorization
boundary. `MCPeerID` carries a client-chosen display name and an undocumented
hash, so it is only bookkeeping for revoke-time disconnects. Every data-bearing
request re-presents the host-scoped credential inside the sealed payload, and
the Mac re-checks it against the trust list per request.

The Mac keeps the approved-device list and its own agreement private key in the
Keychain, matching what the companion does with its seed. Both are bearer
secrets, and the Mac app is unsandboxed, so a preferences plist would be readable
by any process running as the user. The pre-Keychain `UserDefaults` values are
deleted rather than migrated, for the same reason the companion refuses to
migrate its own: a plist travels in backups and can clone an approved identity.
Devices still using pre-Keychain credentials must be approved again; the
product rename does not reset Keychain-backed approvals. If the Keychain
refuses a trusted-list write, pairing still works for that launch and **Mobile Access**
says approvals will not persist. If either platform cannot read or create its
stable agreement/credential key, it does not advertise or discover with an
ephemeral replacement identity; the UI surfaces the Keychain failure instead.

Approval prompts are rate limited. One prompt is outstanding process-wide, so
two peers cannot stack nested modals, and a denial silences new prompts for a
minute — an unapproved device that loops connect → request cannot drive
repeated focus-stealing alerts.

Approved devices are listed under **Mobile Access** in Canvas's right-click menu.
Revoking a device deletes its stored credential and disconnects its live session;
the device must be explicitly approved again before it can fetch another
snapshot. The offline snapshot already on the device remains available because it
is a replaceable local cache, not continuing access to the Mac.

The wire format is versioned (`BlinkPeerWire.version`), and discovery filters on
the same value, so a Mac and a companion from different protocol generations
never pair.

`BlinkPeer` is kept separate from the app UI so the encrypted peer channel can be
proven here and later donated to Hudson without moving Canvas's snapshot model.
Ordinary LAN HTTP with only a bearer token or request MAC remains prohibited
because it can expose note contents to passive network observers.

LAN is the only implemented route. Tailscale and hosted relays remain future
providers for a route orchestrator, not implemented fallback paths today.

The Mac peer host does not start with a nonempty `CANVAS_HOME` or `BLINK_HOME`.
The first nonempty `CANVAS_HOME`, then `BLINK_HOME`, selects the file-backed
root; empty values are ignored. Agent and test sandboxes therefore cannot
advertise their notes under the production Mac's persistent identity or
approved-device trust list. The default Mac store remains
`~/Library/Application Support/Blink`; older releases recognize `BLINK_HOME`
only.

## Building the companion

The checked-in XcodeGen source lives at `apps/ios/project.yml`:

```sh
cd apps/ios
xcodegen generate
xcodebuild -project BlinkMobile.xcodeproj -scheme BlinkMobile \
  -destination 'generic/platform=iOS Simulator' build
```

The generated project consumes the repository's local `BlinkCore` and
`BlinkPeer` Swift package products. The fixture in `apps/ios/Fixtures` documents
representative offline list and detail states without pretending to be
production data. The iOS target bundles `PrivacyInfo.xcprivacy`, declaring the
app-only `UserDefaults` use for appearance preferences with Apple's `CA92.1`
required reason.
