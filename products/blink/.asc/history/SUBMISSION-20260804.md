# Blink Mobile — App Store Connect submission prep

**Last checked:** 2026-08-04 09:24 EDT  
**Bundle ID:** `dev.arach.blink.mobile` (Developer Portal ID `MF8456KF59`)  
**Team / public provider:** `2U83JFPW66`  
**Version / build:** `0.1.0` / `1`  
**ASC API auth profile:** `Talkie` (doctor passed)  
**APP_ID:** **PENDING — no App Store Connect app record exists**  
**BUILD_ID:** **PENDING — upload is blocked on APP_ID**  
**Version status:** local archive/IPA ready; no ASC version exists yet

## Current ship-ready artifacts

| Artifact | Status |
|---|---|
| IPA | `.asc/artifacts/BlinkMobile.ipa` — export passed |
| IPA SHA-256 | `f0b3dc0737b8936e024b95697121d5c355da851c293d9009627dc5ef93f02218` |
| Archive | `.asc/artifacts/BlinkMobile.xcarchive` — archive passed |
| Metadata | `.asc/metadata/` — offline validation passed, 0 errors / 0 warnings |
| iPhone screenshot | `.asc/screenshots/iphone-69/en-US/blink-notes.png` — 1320×2868, local validation passed |
| iPad screenshot | `.asc/screenshots/ipad-13/en-US/blink-workspace.png` — 2064×2752, local validation passed |
| App icon | `apps/ios/BlinkMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` |
| Distribution cert | `M5JL345L93`; exported app authority is `iPhone Distribution: Arach Tchoupani (2U83JFPW66)` |
| Provisioning profile | `Blink Mobile App Store 2` (`938J4X9Z64`) |

The current IPA was rebuilt after adding
`ITSAppUsesNonExemptEncryption=false` to `apps/ios/project.yml`. Blink's mobile
cryptography is provided by Apple's CryptoKit/Security frameworks; the local
Info.plist exemption is ready for ASC-side validation after upload.

## Verified blockers

### 1. Web authentication and app creation

`asc apps list --bundle-id dev.arach.blink.mobile` is empty and
`asc web auth status` returns `{"authenticated":false}`.

The login command reaches the secure password prompt and was interrupted without
entering or logging a credential. Art must run this once in an interactive terminal:

```bash
cd /Users/art/dev/blink
asc web auth login \
  --apple-id "art@tchoupani.com" \
  --public-provider-id "2U83JFPW66"
```

Type the Apple Account password at `Apple Account password:`. If Apple requests
verification, type the current six-digit trusted-device code. Do not paste either
secret into this file or a chat message.

After login, Codex should run (not Art, unless finishing manually):

```bash
asc web apps create \
  --name "Blink" \
  --bundle-id "dev.arach.blink.mobile" \
  --sku "dev.arach.blink.mobile" \
  --platform IOS \
  --primary-locale "en-US" \
  --version "0.1.0" \
  --auto-rename=false \
  --output json \
  --pretty
```

`--auto-rename=false` prevents the CLI from silently creating a customer-facing
name other than Blink. Record the returned app ID here and optionally create a
repo-local `.asc/config.json` with the app ID.

### 2. Privacy-policy URL is still live-404

`https://blink.arach.dev/privacy` returned a real 404 on 2026-08-04. A matching
static privacy route is now prepared at `landing/app/privacy/page.tsx`; `bun run
build` passes and local desktop/mobile browser checks pass. It has **not** been
committed, pushed, or deployed because that is customer-facing. Art must approve
deployment before submission metadata can rely on this URL.

### 3. App Review access path needs an explicit decision

Production Blink has no account or remote demo environment. Full functional
review requires a Mac running Blink on the same LAN and approving the device.
See `.asc/review-notes.md`. Before review submission, Art must choose either a
reviewer-accessible path (and contact phone) or a review/demo mode. The simulator
fixture used only to capture screenshots is not present in the production IPA.

## Completed locally

1. ASC API authentication doctor passed with profile `Talkie`.
2. Bundle ID created in the Apple Developer portal.
3. App Store metadata scaffolded and validated offline.
4. App icon installed.
5. Distribution certificate and App Store profile created and installed.
6. Release archive and manually signed App Store IPA exported.
7. Exempt-encryption Info.plist key added and IPA rebuilt/re-exported.
8. Real app screenshots captured from iOS 26.5 simulators with the repository's
   demo snapshot, visually inspected, and validated by `asc screenshots validate`.
9. Privacy-policy route authored and static production build verified locally.
10. Temporary DerivedData and simulator/browser sessions cleaned up.

## Post-create execution plan (Codex-owned)

Set the app ID returned by `asc web apps create`:

```bash
export ASC_APP_ID="<APP_ID>"
```

### A. Configure app-level information

```bash
asc app-setup categories set --app "$ASC_APP_ID" --primary PRODUCTIVITY
asc app-setup pricing set --app "$ASC_APP_ID" --free
asc app-setup availability edit \
  --app "$ASC_APP_ID" \
  --all-territories \
  --available true \
  --available-in-new-territories true
asc apps content-rights edit \
  --app "$ASC_APP_ID" \
  --uses-third-party-content=false
asc age-rating edit --app "$ASC_APP_ID" --all-none
```

`PRODUCTIVITY` fits the product docs: Blink is a read-only spatial-notes and
workspace companion. All-territory availability remains the requested default.
If `availability edit` reports that no availability record exists, first let the
free-pricing command initialize it, then retry.

### B. Create/apply metadata

```bash
asc metadata push \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --platform IOS \
  --dir ./.asc/metadata \
  --dry-run
asc metadata push \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --platform IOS \
  --dir ./.asc/metadata
```

Because app privacy is a web-only ASC surface, use the cached web session to
pull/plan/apply and explicitly publish the declaration that Blink collects no
app data. Do not guess the canonical file shape; pull the new app state first:

```bash
asc web privacy pull \
  --app "$ASC_APP_ID" \
  --apple-id "art@tchoupani.com" \
  --public-provider-id "2U83JFPW66" \
  --out .asc/privacy.json
# Inspect/edit .asc/privacy.json to declare no app data collection, then:
asc web privacy plan --app "$ASC_APP_ID" --file .asc/privacy.json
asc web privacy apply --app "$ASC_APP_ID" --file .asc/privacy.json
asc web privacy publish --app "$ASC_APP_ID" --confirm
```

### C. Upload and wait — never submit

```bash
asc publish appstore \
  --app "$ASC_APP_ID" \
  --ipa .asc/artifacts/BlinkMobile.ipa \
  --version "0.1.0" \
  --wait \
  --timeout 45m \
  --output json \
  --pretty
```

There is deliberately no `--submit`. Record the processed `BUILD_ID` here.
If the publish helper does not return it, use:

```bash
asc builds list --app "$ASC_APP_ID" --output table
```

### D. Upload the minimum screenshot sets

Use app-scoped fan-out; each path has an `en-US` locale child:

```bash
asc screenshots upload \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --path .asc/screenshots/iphone-69 \
  --device-type IPHONE_69 \
  --dry-run
asc screenshots upload \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --path .asc/screenshots/iphone-69 \
  --device-type IPHONE_69

asc screenshots upload \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --path .asc/screenshots/ipad-13 \
  --device-type IPAD_PRO_3GEN_129 \
  --dry-run
asc screenshots upload \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --path .asc/screenshots/ipad-13 \
  --device-type IPAD_PRO_3GEN_129
```

The CLI's local validator maps the 6.9-inch image to Apple's
`APP_IPHONE_67` API set and accepts it with no warnings.

### E. Accessibility declarations

After app creation, query existing declarations and add only claims verified by
the native UI. The code and screenshots support VoiceOver labels, Dynamic Type,
dark appearance, and non-color-only state. Initial commands:

```bash
asc accessibility list --app "$ASC_APP_ID"
asc accessibility create \
  --app "$ASC_APP_ID" \
  --device-family IPHONE \
  --supports-voiceover true \
  --supports-larger-text true \
  --supports-dark-interface true \
  --supports-differentiate-without-color-alone true
asc accessibility create \
  --app "$ASC_APP_ID" \
  --device-family IPAD \
  --supports-voiceover true \
  --supports-larger-text true \
  --supports-dark-interface true \
  --supports-differentiate-without-color-alone true
```

Do not publish accessibility declarations until the returned declarations and
claims have been reviewed.

### F. Stage and validate — stop before review submission

```bash
asc release stage \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --platform IOS \
  --build "$BUILD_ID" \
  --metadata-dir ./.asc/metadata/version/0.1.0 \
  --dry-run

asc release stage \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --platform IOS \
  --build "$BUILD_ID" \
  --metadata-dir ./.asc/metadata/version/0.1.0 \
  --confirm

asc validate \
  --app "$ASC_APP_ID" \
  --version "0.1.0" \
  --platform IOS \
  --output table
```

`asc validate` has not run against ASC because there is no app/version record.
Its expected remediation areas after creation are review contact/notes, privacy
publication, screenshots, app content rights, age rating, pricing/availability,
and processed-build encryption state.

## Submission boundary

Do **not** run any of the following without Art's explicit confirmation:

- `asc publish appstore ... --submit`
- `asc review submit`
- `asc review submissions-submit`

The intended stopping point is: metadata and privacy published, processed build
attached, screenshots uploaded, review details staged, and `asc validate` green
(or a documented minimal blocker list).
