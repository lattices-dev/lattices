# Deploy a locally built site

`deploy-prebuilt-site.yml` publishes an existing static archive. It does not
install dependencies or build the site on a hosted runner. The existing
`pages.yml` workflow remains separate and unchanged.

1. On the authorized development Mac, export a clean, pinned source commit.
   Do not build from unrelated dirty website work. Install the site's frozen
   Bun lockfile and run `bun run build` from `apps/site`.
2. Test the exported routes and Action artifacts. Add `site-provenance.json`
   at the root of `apps/site/dist`, with `sourceCommit` set to the full source
   commit SHA. Do not include machine names, local paths, credentials, or logs.
3. Archive the contents of `dist` as a `.tar.gz`, with `index.html`, `CNAME`,
   and `site-provenance.json` at the archive root. Do not include symlinks,
   dependencies, or source files. Calculate its SHA-256 locally.
4. After the source commit is merged into `main`, upload the archive to an
   authorized GitHub release. Dispatch **Deploy locally built site** from
   `main` with the source commit, release tag, exact asset filename, and hash.
5. Verify the deployment and live routes. A successful local build or merged
   source commit does not mean the site has been published.

The workflow checks that the source commit is an ancestor of `main`, verifies
the downloaded archive hash, rejects unsafe archive paths and links, checks
the source commit in the manifest and the `lattices.dev` domain, then uploads
and deploys the Pages artifact. These checks bind the operator-selected artifact
to its declared source; they do not independently reproduce or certify the build.

Action's published `AGENTS.md` and `docs.json` are byte-for-byte copies of the
product-root files. Its `llms.txt` comes from the product root with documentation
index URLs mapped to the published `/action/*.md` paths. The `/action/agents/`
entry point links to these authoritative artifacts and current guides instead
of publishing the legacy standalone setup instructions.
