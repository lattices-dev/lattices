# Canvas 1.0 / build 1: iOS submission dossier

**Updated:** October 19, 2026. **Status:** preparation in progress; not uploaded or submitted.

The user has authorized submission to App Review. Finish the validation and
App Store Connect steps below, then submit the verified build. Browser sign-in
is complete. The Apps page requires acceptance of an updated Apple Developer
Program License Agreement before submissions; the user has been asked to
review it at the developer account site. The release coordinator verified
healthy AmpLink API authentication. Creating the Canvas app record returned
the generic error “An error has occurred. Try again later.” The subsequent
API lookup still returned no record for `dev.arach.blink.mobile`. The generic
creation error has not been conclusively attributed to the agreement. No
upload or submission has been performed.

The previous dossier is preserved unchanged in
[history/SUBMISSION-20260804.md](history/SUBMISSION-20260804.md). It is historical
evidence, not the current release procedure or source of artifact claims.

## Release identity

| Item | Current value |
| --- | --- |
| Customer-facing name | Canvas |
| Platform | iPhone and iPad; iOS 17.0+ |
| Marketing version / build | `1.0` / `1` |
| iOS bundle ID / SKU | `dev.arach.blink.mobile` |
| Development team | `2U83JFPW66` |
| Product / internal target and module | `Canvas` / `BlinkMobile` |
| Hudson revision | `79ca548b2b30335a3c37fb031a753481dedaaf79` |
| App Store Connect app ID | **Absent:** bundle lookup verified; app record creation pending |
| Processed build ID / review submission ID | **Pending; no upload or submission performed** |

`apps/ios/project.yml` and `Package.resolved` pin the Hudson revision above.
The current `final2` candidate contains the Mac-only socket guards and the
sample-banner layout update. Its simulator build, signed archive, and App
Store export passed. Earlier archives and exports are **superseded**.

| Current candidate | Verified value |
| --- | --- |
| Archive | `.asc/artifacts/Canvas-1.0-1-final2.xcarchive` |
| Exported IPA | `.asc/artifacts/Canvas-1.0-1-final2/Canvas.ipa` |
| IPA SHA-256 | `67b172eaf446cc9134e710b7fd6ebfc1b7edf31163062f0c41af19758a67b912` |
| Validation receipt | `/tmp/canvas-ios-release-20261019/archive-final2-validation.json` |

Artifact paths above are relative to `products/blink/`. Strict signature
validation passed. The archive identifies Canvas `1.0 (1)`, iOS 17.0+, and
bundle `dev.arach.blink.mobile`. Its privacy manifest declares UserDefaults
reason `CA92.1`, no tracking, and no collected data types; the required-reason
import audit found no unexpected timestamp, disk-space, or file imports.
The physical iPad installation, launch, and data hash comparison for `final2`
passed. Physical iPhone acceptance remains pending because the device is
locked. Nothing has been uploaded or submitted.

## Preserved identities and data

The Canvas rename does not move or rename existing notes, cached personal
notes, preferences, or established Keychain identities. Preserve these values:

| Boundary | Exact identifier or location |
| --- | --- |
| iOS offline cache | App sandbox `Application Support/Blink/snapshot.json`; excluded from device backups |
| iOS preferences domain | `dev.arach.blink.mobile` |
| Appearance / theme keys | `blink.mobile.appearance`, `blink.mobile.theme` |
| iOS pairing Keychain service / account | `dev.arach.blink.mobile.peer` / `device-seed` |
| iOS Keychain attributes | Non-synchronizing; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Multipeer service / Bonjour service | `blink-notes` / `_blink-notes._tcp` |
| Peer wire and discovery version / key derivation salt | `4` / `dev.arach.blink.peer.v4` |
| Mac bundle ID / data root | `dev.arach.blink` / `~/Library/Application Support/Blink` |
| Mac trust Keychain service | `dev.arach.blink.peer.host` |
| Mac trust accounts | `blink.peer.trusted-devices`, `blink.peer.trusted-devices.host-agreement-key` |

The cache retains its saved snapshot, source identity, and successful-sync
timestamp independently of sample mode. The Mac remains the owner of the
original Markdown files. No private values or device backup contents belong in
this dossier.

An iPad install and launch of Canvas `1.0 (1)` preserved the actual cached
snapshot and the existing `blink.peer.device-credential` preference. Of 18
baseline files, 8 remained byte-identical; the changed or removed files were
OS-managed rendering caches, saved application state, and launch snapshots.
This verifies the earlier install/launch preservation. Receipts:
`/tmp/canvas-ios-release-20261019/ipad-install.json`, `ipad-launch.json`, and
`ipad-preservation.json`. The final2 physical iPad install and launch also
succeeded (`ipad-final2-install.json`, `ipad-final2-launch.json`). The final2
comparison in `ipad-final2-preservation.json` confirms byte-identical cached
notes and preservation of the existing `blink.peer.device-credential`
preference. Launch was verified from `Canvas.app`. Keychain contents were not
exported or compared; the bundle and access identities remain unchanged.
Physical-device reconnect to a real Mac host was not verified.

## App Review access

The current source provides a sample-mode review path without a Mac, an
account, credentials, or Local Network permission:

1. Open Canvas and choose **Try sample notes**. With saved notes, use
   **Settings → About → Try sample notes**.
2. Browse workspaces and notes, open a note, and use search.
3. Choose **Exit Samples** in the persistent **Sample Notes** banner.

Samples are bundled examples displayed in memory through the normal read-only
views. They do not replace the offline cache or change the pairing identity.
Personal notes require a Mac running Canvas, local-network access, and manual
device approval on that Mac. The downloaded copy remains readable offline.
Detailed review steps are in [review-notes.md](review-notes.md).

To remove the mobile copy, use **Settings → On This Device → Notes → Remove
Notes**. This disconnects the mobile app and removes its offline notes; the
original Mac files remain unchanged. Reconnecting can download a new copy.

The release coordinator verified the iPhone sample list, note reader, and
**Exit Samples**, plus the iPad workspace board, Settings, and blocked
connection attempts while samples are active. Manual verification of the
iPhone top toolbar remains outstanding: simulator accessibility did not expose
it, and the coordinate automation tool returned `noWindowsAvailable`. This is
an incomplete verification path, not evidence of a product defect.

The isolated simulator LAN fixture passed discovery, explicit Mac approval,
encrypted first-snapshot transfer, revision-2 sync, and offline relaunch and
reading on iPhone. On iPad it passed encrypted sync and reconnect with
remembered approval. Active trust revocation disconnected the iPad client. A
new request required fresh approval; denying that exact pending request
cleared it and left no approved devices. The unified receipt is
`lan-validation.json`; detailed receipts are `lan-reconnect-status.json`,
`lan-revoked-request-status.json`, and `lan-denied-status.json` under the release
receipt directory. The temporary host stopped cleanly. These checks used
synthetic notes, did not change production mobile-access settings or trust,
and do not establish physical-device LAN acceptance.

## Public website: verified live

- Support: <https://blink.arach.dev/support/>
- Privacy: <https://blink.arach.dev/privacy/>
- Published support contact: `arach@tchoupani.com`.

The standalone site is hosted by GitHub Pages for `arach/blink`, not Vercel.
[Commit 77e06a9d05aafc651441bab56a689bf5988fc9bb](https://github.com/arach/blink/commit/77e06a9d05aafc651441bab56a689bf5988fc9bb)
deployed through successful
[run 39353769954](https://github.com/arach/blink/actions/runs/39353769954).
Both pages returned HTTP 200 and rendered Canvas branding, sample guidance,
the removal steps, and the support contact in Chrome. Website analytics are
described separately from the apps. The unfinished main Lattices site was not
part of this deployment.

## Remaining evidence and submission steps

Record final paths, hashes, results, and App Store Connect IDs here as each
step completes. Existing August artifacts and superseded archives do not
satisfy final-candidate checks. Current local receipts are under
`/tmp/canvas-ios-release-20261019/`.

| Check | Status / evidence to record |
| --- | --- |
| Final source and dependency state | **Verified:** all 41 source/package inputs match the scoped release tree; local `source-manifest-1.0-1.json` SHA-256 `e40d885cf4ae3990c9a5aff1f613a96e5bfafc60838511d02f5199628f7c45ad`. Hudson pin verified. |
| Swift and iOS tests | **Passed to date:** 4 sample/cache-isolation tests, 0 failures (`tests-final.log`); 2 Mac IPC tests passed, reported by the implementation agent and recorded by the release coordinator. The `final2` simulator build passed (`simulator-final2.log`). |
| Final signed archive | **Passed:** `archive-final2.log` and `archive-final2-validation.json` verify the current signed archive and expected release identity. Source inputs are recorded in the verified manifest above. |
| App Store export | **Passed:** `export-final2.log` reports export success; IPA path, SHA-256, and signature/privacy validation are recorded above. |
| Device and UI acceptance | **Partly verified:** sample UI paths and physical iPad final2 install/launch passed; `ipad-final2-preservation.json` confirms cached note bytes and existing settings unchanged. Manual iPhone toolbar verification and physical iPhone acceptance remain pending; the physical iPhone is locked. Keychain contents were not compared. |
| LAN and offline acceptance | **Passed in isolated simulators:** discovery, explicit Mac approval, encrypted first snapshot, revision-2 sync, offline relaunch/read, remembered-approval reconnect, active revocation/disconnection, fresh approval requirement, and exact-request denial (`lan-validation.json`). The final receipt has no pending request or approved devices, and the test host stopped cleanly. Physical-device LAN/reconnect acceptance remains unverified. |
| Store screenshots and accessibility claims | **Local validation passed:** two iPhone images (`canvas-notes.png`, `canvas-reader.png`) at 1320 × 2868 and one iPad image (`canvas-workspace.png`) at 2064 × 2752; zero warnings/errors in `screenshots-iphone-final-validation.json` and `screenshots-ipad-final-validation.json`. Historical Blink images remain under `history/screenshots/20260804/`, outside upload sets. Final store selection and accessibility declarations remain pending. |
| API authentication / app record lookup | **Verified by the release coordinator:** AmpLink API authentication is healthy; no app record exists for `dev.arach.blink.mobile`. |
| Browser session / agreement / app record creation | **Signed in. Pending:** user review/acceptance of the updated Apple Developer Program License Agreement, then retry first app-record creation. The attempt used Canvas, iOS, `en-US`, and bundle/SKU `dev.arach.blink.mobile`; it returned a generic error, and API recheck still found no record. The cause of the creation error is not established. |
| Metadata and App Review information | **Offline metadata validation passed:** 3 local files, zero warnings/errors (`metadata-validation-final.json`). Applying version `1.0` metadata and review notes, and privately validating required review contact fields, remain pending. |
| App privacy, encryption, age rating, rights, pricing, availability | **Pending:** verify and complete the current App Store Connect declarations |
| Upload and processing | **Pending:** upload only the final exported IPA; record processed build ID and processing result |
| Build attachment and release validation | **Pending:** attach build `1` to version `1.0`; resolve reported validation failures |
| App Review submission | **Authorized, pending:** submit after the checks above pass; record submission ID and returned status |

Local metadata is under `metadata/version/1.0/` and `metadata/app-info/`.
`deployment.json` records the intended release values. Local configuration or
an archive success alone does not establish a successful upload or submission.
