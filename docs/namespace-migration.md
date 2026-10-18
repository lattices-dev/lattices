---
title: Repository and package migration
description: Canonical Lattices names and compatibility for existing installations
order: 98
---

# Repository and package migration

Lattices uses `lattices-dev/lattices` on GitHub and `@lattices/lattices` on npm. The terminal commands remain `lats` and `lattices`.

## Existing npm installations

Keep using the package name you installed. All three packages ship the same CLI, exports, and app:

```sh
# Use the line that matches your installed package.
npm install -g @arach/lattices@latest
npm install -g @lattices/cli@latest
npm install -g @lattices/lattices@latest
```

Use the equivalent `bun add -g` or `pnpm add -g` command if that package manager owns your installation. You only need one of these packages installed globally.

`lats app upgrade` updates the installed package in place. From version 0.14.1, the helper reads the installed package name so its installation directory and login LaunchAgent remain consistent.

To switch names, uninstall the old global package with its package manager, install `@lattices/lattices`, and run `lats app install` if you use login startup. Uninstalling the npm package does not remove `~/.lattices`, project configuration, or tmux sessions. Avoid installing multiple names globally: they provide the same commands.

JavaScript imports from `@arach/lattices` and `@lattices/cli` remain supported, including the existing subpath exports. New examples use `@lattices/lattices`.

## Existing Git checkouts and downloads

GitHub redirects the previous repository URL. To update a checkout explicitly:

```sh
git remote set-url origin https://github.com/lattices-dev/lattices.git
git fetch origin
```

The transfer preserves repository history, issues, pull requests, tags, and releases. Do not recreate `arach/lattices`: that would remove its redirects.

Existing app updates and release-download links follow the GitHub redirects. Version 0.14.0's companion downloader rejects redirects and checks the old release asset path; update Lattices before installing a companion through that app's installer. New companion installers use the stable repository ID and accept exact asset paths under both repository names.

## Maintainers

Publish `@lattices/lattices`, `@arach/lattices`, and `@lattices/cli` from the same staged payload. Keep the commands, exports, bundle identifiers, preference domains, and configuration paths unchanged. Check all three registry records after publication.

The organization profile source is `docs/github-profile.md`; its public copy lives at `lattices-dev/.github/profile/README.md`. GitHub Pages continues to serve `lattices.dev` from the main repository.
