# Screen-text security

Lattices searches app text with controls for collection, retention and remote
access. This document describes the
native source changes reviewed on November 6, 2026, not a released build.
Build results and live app acceptance must be recorded separately.

## Collection policy

Screen-text indexing is off by default on new installs. Existing preferences
remain in effect. Turning indexing off blocks timer scans, direct scans and
single-window scans. Turning it off or changing exclusions invalidates pending
scans before they can publish results or write saved history.

An eligible window must be on screen, have a known app bundle ID, use the normal
window layer (`0`), and measure at least 50 by 50 in window coordinates.
Lattices excludes its own process. Users can exclude other apps in Settings.
An on-screen window can contain covered content that a window capture includes;
eligibility does not guarantee capture of only unobscured pixels.

The initial exclusions use locally verified app identities:

- Apple Passwords: `com.apple.Passwords`
- Keychain Access: `com.apple.keychainaccess`
- 1Password: `com.1password.1password`

Users can add or remove exclusions. The same app policy applies to
Accessibility text extraction and Vision OCR, including manual scans.
Accessibility traversal skips secure-field and hidden subtrees. An explicitly
empty visible-children list stays empty. When an app supplies a visible text
range, extraction clips text to that range.

These checks depend on the app's Accessibility implementation. If visibility
information is unavailable, extraction can still use the full exposed text
value or child list. Lattices does not detect private/incognito tabs or identify
every secret. A revealed password in an ordinary document, terminal or browser
page can enter the index.

Explicit screenshot tools and `computer.observe` have separate purposes and
permissions. The indexing toggle and exclusions do not govern those tools.
Remote access to their screen content requires the corresponding gateway grant.

## Saved history

The bundle profile stores history in `~/.lattices/ocr.db`; the free profile
keeps the live index without this persistent store. The retention default is
seven days. Every history query applies the current cutoff, so expired entries
stay unavailable between maintenance runs.

Turning indexing off or excluding an app stops future collection. Existing
saved history remains until expiry or **Clear saved history**. Clearing history
invalidates pending scans before deleting saved rows and rebuilding the search
index. New scans can start while indexing remains on.

The database and SQLite sidecars use owner-only permissions (`0600`). The
store serializes reads, writes and clearing. SQLite secure deletion and a WAL
checkpoint reduce residual data; clearing is not a forensic purge and does not
remove backups. The database contains plaintext. FileVault and protection of
the macOS account remain relevant. Same-user processes with file access are
inside the local trust boundary.

## Remote access

The gateway preserves exact method grants and checks content-sensitive
parameters. Remote `windows.search` defaults to `ocr: false`. A search that
requests OCR needs both its original method grant and
`lattices:ocr.snapshot`. Aliases, legacy modes and mixed source lists receive
the same checks. Malformed content flags are rejected.

Remote `runs.list`, `runs.get` and `runs.artifacts` return allowlisted metadata
with `metadataOnly: true` by default. Requesting `includeContent: true` also
requires `lattices:files.read`. Metadata can itself be sensitive, including
window titles and app names; read access is still a deliberate grant.

## Evaluation

| Setup and action | Required result |
| --- | --- |
| Enable indexing and scan an eligible ordinary app | Text can enter the live index |
| Disable indexing, or exclude the app, then request any scan type | No new scan starts; pending results cannot publish or persist |
| Change policy while a worker or database write is queued | The old generation cannot publish or persist |
| Replace indexed text with an empty, short, secure or hidden AX tree | A successful scan replaces stale live text; communication failures remain distinguishable |
| Query temporary history across the retention boundary | Expired rows are absent from search, history and recent results |
| Write and clear a temporary database | Files remain private; clear removes rows and searchable terms |
| Open history through a linked parent or linked database filename | A normal parent alias works; a symlink or hardlink at the database filename is refused |
| Exercise remote aliases, mixed sources and malformed flags | Missing content grants cannot expose OCR or run content |

Automated checks use synthetic policy fixtures and temporary databases. They
do not inspect personal history. Live acceptance must separately verify app
identities, Accessibility visibility behavior, permission prompts and settings
transitions against the installed build.
