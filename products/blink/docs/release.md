# Shipping Canvas

This document specifies the Canvas 2.3.0 release contract and verification
procedure. Source and locally built artifacts do not establish registry or
download availability. The npm package remains `@arach/blink`.

`packages/npm/package.json` supplies the release version. The CLI's compile-time
version must match; builds check it.

| Artifact | What | Who it's for |
|---|---|---|
| **npm** `@arach/blink` | native `canvas` CLI + `canvas-app` installer; `blink` and `blink-app` aliases | agents / terminal |
| **DMG** on GitHub release | `Canvas.dmg` containing signed + notarized `Canvas.app` | app installation |
| **CLI binary** on GitHub release | `canvas-macos-arm64` | direct download / installer fallback |

All scripts live in `tools/release/`. Version 2.3.0 has these release channels:

| Repository and tag | Assets and app filename |
|---|---|
| `lattices-dev/lattices`, `canvas-v2.3.0` | `Canvas.dmg` and `Canvas-2.3.0.dmg` contain `Canvas.app`; also includes `canvas-macos-arm64`, `Blink.dmg`, and `blink-macos-arm64` |
| `lattices-dev/lattices`, `blink-v2.3.0` | `Blink.dmg` and `Blink-2.3.0.dmg` contain `Blink.app`; includes `blink-macos-arm64` |
| `arach/blink`, `v2.3.0` | Legacy mirror of the Blink DMG and CLI assets, with provenance pointing to the canonical source commit |

The two monorepo tags must resolve to the same source commit. The compatibility
`Blink.app` has the same signed contents as `Canvas.app`, including executable
`Canvas`, visible name Canvas, and bundle ID `dev.arach.blink`; only its outer
directory name differs. The DMGs are distinct images. The two CLI assets are
identical bytes. This lets older installers keep their required filenames
without moving notes or settings.

The current installer chooses the highest compatible stable version across
`canvas-v*` and `blink-v*`, preferring Canvas when versions tie. Each tag must
match its primary asset: `canvas-v*` with `Canvas.dmg`, or `blink-v*` with
`Blink.dmg`. Existing Blink releases still install `Blink.app`.

Update the app and CLI together for 2.3.0's stricter private IPC permissions.

## Compatibility and local builds

The bundle remains `dev.arach.blink`. Notes, attachments, configuration, ledger,
settings, Keychain items, and paired-device identities keep their existing
locations and identifiers. The default store remains
`~/Library/Application Support/Blink`; the local socket remains `blink.sock`.
Do not move data or rewrite `blink.*` frontmatter during the rename.

Explicit `behavior.mobileAccess` choices are preserved. When the setting is
absent, valid existing Keychain approvals retain mobile access; new installs,
missing or malformed approvals, and Keychain read failures default to off.
Custom homes never consult the production trust list or start the peer host.
Loading an existing config does not rewrite it; a later settings save records
the effective choice explicitly. Per-request device authorization stays intact.

SwiftPM builds `CanvasApp` and `canvas`; `BlinkApp` and `blink` remain executable
aliases. `scripts/run-app.sh` bundles `dist/Canvas.app` with executable `Canvas`.
Use `CANVAS_APP_PATH` to override the bundle path; `BLINK_APP_PATH` remains its
fallback. These bundle-path overrides are separate from the first nonempty
`CANVAS_HOME`, then `BLINK_HOME`, which selects the file-backed data directory.
The existing `BLINK_*` signing, dependency, and release environment variables
remain supported.

## One-time setup

1. **Signing identity** — a *Developer ID Application* cert in your login
   keychain. `tools/release/*.sh` auto-detect it (`security find-identity`), or
   set `BLINK_SIGN_IDENTITY`.
2. **Notarization profile** — store App Store Connect creds once:
   ```sh
   xcrun notarytool store-credentials notarytool \
     --key-id <KEY_ID> --issuer <ISSUER_ID> --key /path/AuthKey_<KEY_ID>.p8
   ```
   Then the scripts use `--keychain-profile notarytool` (override with
   `BLINK_NOTARY_PROFILE`). See `Config/signing.env.example`.
3. **npm** — `npm login` as `arach` (publishes `@arach/blink` with provenance).
4. **Hudson** — the app build resolves the pinned private Hudson revision over
   git by default, so CI needs `HUDSON_READ_TOKEN`. Local Hudson development can
   opt into `BLINK_HUDSON_SOURCE=path` with `BLINK_HUDSON_PATH`. The CLI does
   not link Hudson but still needs the manifest to resolve.

## Cutting a release

Run these commands from `products/blink` after choosing a new version.

```sh
# 0. bump the version
#    edit packages/npm/package.json and Sources/BlinkCLI/BlinkCLI.swift
#    -> the same new version in both files

# 1. preview the build commands and GitHub release assets
./tools/release/ship.sh --dry-run

# 2. from a clean, pushed commit: build + sign + notarize + staple the DMG and
#    CLI, then publish the GH release
./tools/release/ship.sh
#    -> publishes canvas-v<version> and blink-v<version> on lattices-dev/lattices
#       at the same source commit, with the matching Canvas and Blink assets

# 3. publish npm from the signed GitHub CLI asset (one Actions run; the
#    workflow is dispatch-only, so pushing the tag alone does nothing)
version="$(node -p "require('./packages/npm/package.json').version")"
git tag -a "canvas-npm-v$version" -m "@arach/blink $version"
git push origin "canvas-npm-v$version"
gh workflow run release-blink-npm.yml --ref "canvas-npm-v$version" -f publish=true
```

`ship.sh` publishes both monorepo channels. The `arach/blink` mirror is a
separate release step: upload the verified legacy assets without rebuilding,
and link its release notes to the exact canonical source commit. Verify the
downloaded assets and installed bundle from every channel before reporting the
release complete. `BLINK_RELEASE_REPO` changes the monorepo destination; it does
not add the legacy mirror automatically.

### Individual steps

```sh
./tools/release/build-dmg.sh <version>   # signed+notarized DMG -> dist/Canvas.dmg + Blink.dmg
./tools/release/build-cli.sh             # signed CLI -> packages/npm/dist/canvas + dist/blink
BLINK_SKIP_NOTARIZE=1 ./tools/release/build-dmg.sh   # sign but skip notarization (faster)
BLINK_SKIP_SIGN=1 ./tools/release/build-dmg.sh       # unsigned local smoke build
BLINK_SKIP_SIGN=1 ./tools/release/build-cli.sh       # unsigned local CLI smoke build
```

`ship.sh` never publishes unsigned assets. It also verifies that tracked files
and release inputs are clean, local `HEAD` matches the configured remote target,
and an existing release tag still points at that exact commit before replacing
assets.

## npm CI

The repository-root workflows keep Canvas releases namespaced inside the
Lattices repository:

- `.github/workflows/release-blink-macos.yml` builds and publishes the
  `canvas-v*` and `blink-v*` GitHub releases from one source commit.
- `.github/workflows/release-blink-npm.yml` runs on manual dispatch only
  (CI is manual to protect the Actions budget). Dispatch it on the
  `canvas-npm-v*` tag with `publish=true`; without it, it is a dry run. The old
  `blink-npm-v*` tag spelling remains accepted. It downloads the signed
  `canvas-macos-arm64` from the matching `canvas-v*` release. It requires that
  release to match the package source commit; it does not substitute a legacy
  binary if the canonical asset is missing. It verifies version and code
  signature, then publishes with provenance
  without rebuilding. Both CLI names are included in the npm package.

Configure npm trusted publishing for `@arach/blink` and
`release-blink-npm.yml` in `lattices-dev/lattices`, or add an `NPM_TOKEN` secret to the
GitHub `release` environment. The token path is a fallback; browser login is
not part of the release procedure. A publish that fails with
`404 Not Found - PUT …@arach%2fblink` means neither is in place: the
registry answers unauthorized publishes with 404.

## Known limitations

- **Apple Silicon only.** The CLI + app are `arm64`. Universal (`lipo`
  arm64 + x86_64) is a follow-up; the npm shim errors clearly on Intel.
- No auto-update inside the app yet; `canvas-app update` downloads the selected release DMG.
  `blink-app update` remains compatible.
