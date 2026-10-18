---
title: Release
description: Maintainer workflow for macOS DMG and npm releases
order: 99
---

## macOS DMG releases

The public macOS app release is a signed, notarized DMG attached to the
GitHub release `v<version>`.

There are two valid DMG paths:

1. CI release: push an `app-macos-v<version>` tag or run the
   **Release App macOS** workflow with `publish=true`.
2. Local maintainer release: build and ship from a Mac that has the
   Developer ID certificate and notary profile installed.

Unsigned DMGs are smoke-test artifacts only. They should not create or update
a public GitHub release.

### CI release

The workflow reads credentials from the GitHub `release` environment.

Required environment secrets:

```text
DEVELOPER_ID_APPLICATION_CERT_BASE64
DEVELOPER_ID_APPLICATION_CERT_PASSWORD
KEYCHAIN_PASSWORD
APP_STORE_CONNECT_API_KEY_P8
```

Required environment variable or secret:

```text
APP_STORE_CONNECT_KEY_ID
```

Optional environment variable or secret:

```text
APP_STORE_CONNECT_ISSUER_ID
```

Set `APP_STORE_CONNECT_ISSUER_ID` for Team API keys. Leave it unset for
Individual API keys.

Setup shape:

```sh
# Export the Developer ID Application certificate as a .p12, then:
base64 < DeveloperIDApplication.p12 | tr -d '\n' \
  | gh secret set DEVELOPER_ID_APPLICATION_CERT_BASE64 --repo lattices-dev/lattices --env release

gh secret set DEVELOPER_ID_APPLICATION_CERT_PASSWORD --repo lattices-dev/lattices --env release
gh secret set KEYCHAIN_PASSWORD --repo lattices-dev/lattices --env release
gh secret set APP_STORE_CONNECT_API_KEY_P8 --repo lattices-dev/lattices --env release < AuthKey_KEYID.p8

gh variable set APP_STORE_CONNECT_KEY_ID --repo lattices-dev/lattices --env release --body KEYID
gh variable set APP_STORE_CONNECT_ISSUER_ID --repo lattices-dev/lattices --env release --body ISSUER_UUID
```

Release:

```sh
git tag -a app-macos-v0.5.0 -m "Lattices macOS 0.5.0"
git push origin app-macos-v0.5.0
```

The workflow builds `dist/Lattices.dmg`, signs, notarizes, staples, verifies,
then creates or updates GitHub release `v0.5.0` with both:

```text
Lattices.dmg
Lattices-0.5.0.dmg
```

If publish is requested and signing/notary configuration is missing, the
workflow must fail. A successful unsigned workflow run is only an artifact
build, not a release.

### Local maintainer release

Use this when GitHub Actions is not provisioned with Apple credentials yet,
or when intentionally shipping from a local release machine.

Preflight:

```sh
gh auth status
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile notarytool-art | head
```

Build a signed, notarized DMG:

```sh
./tools/release/build-dmg.sh
```

Build and upload to GitHub Releases:

```sh
LATTICES_VERSION=0.5.0 ./tools/release/ship.sh dmg
```

The local ship script now mirrors CI: it creates or updates release `v0.5.0`,
sets the title to `Lattices 0.5.0`, and uploads both the unversioned and
versioned DMG assets.

### Unsigned checks

For a local smoke DMG:

```sh
LATTICES_SKIP_SIGN=1 LATTICES_SKIP_NOTARIZE=1 ./tools/release/build-dmg.sh
```

For CI smoke checks, run **Release App macOS** manually with `publish=false`.
That path uploads an unsigned workflow artifact and intentionally skips the
GitHub release step.

## npm releases

Publish `@lattices/lattices` as the canonical package. Continue publishing
`@arach/lattices` and `@lattices/cli` with identical payloads for existing
installations and imports. The package names differ; commands and exports do not.

The **Release Package npm** workflow is manually dispatched. It reads
`NPM_TOKEN` from the GitHub `release` environment. The token must be able to
publish all three package names and should authenticate as `arach`; set
`NPM_EXPECTED_USER` if another maintainer publishes.

After publishing the signed, notarized app release matching `package.json`,
reuse its verified app bundle for npm:

```sh
gh workflow run release-package-npm.yml --repo lattices-dev/lattices --ref main \
  -f publish=true -f build_app=false
```

The workflow verifies the DMG hash, notarization status, signing identity,
app version, and source revision before packaging. It then publishes the
canonical package and both compatibility names. Verify all three registry
records before announcing completion.

Use `publish=false` for a dry run. Use `build_app=true` only when intentionally
rebuilding the app instead of reusing the signed release.

See [Repository and package migration](/docs/namespace-migration) for existing
installs, startup paths, and repository redirects.
