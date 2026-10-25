# Lattices Studio

This local development app uses the shared Studio package at an immutable Git
revision. Its lockfile includes the complete live-view implementation, including
the `studio/live/server` route. A sibling Studio checkout is not required.

Hudson remains a source workspace at `../../../hudson/packages/web/hudsonkit`
relative to this directory. Keep the Hudson repository beside the Lattices
checkout, then install and validate from this directory:

```sh
bun install --frozen-lockfile
bun run typecheck
bun run build
```

Run `bun run dev` for the local Studio host. The live route watches this app's
study sources and registered repository content; it is intended for local
development. Installing dependencies does not build or relaunch the native
Lattices app.

To update shared Studio, change its full Git revision in `package.json`, run
`bun install` to refresh `bun.lock`, and repeat the checks above. Do not replace
the installed package with a manual cache symlink; that bypasses the declared
revision and can omit exported source modules.
