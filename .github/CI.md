# Hosted CI is opt in

All checked-in GitHub Actions workflows run only through `workflow_dispatch`.
Pushes, pull requests, labels, and release tags do not start hosted jobs.
This applies to build checks, package checks, releases, and site deployment
where present. Run routine validation and release builds locally.

To request a hosted run, open **Actions**, select the workflow, choose
**Run workflow**, and select the branch or tag to check. The selected ref must
contain the manual-only workflow version. Old refs can still contain historical
automatic triggers; merge or rebase the current default branch before pushing
older branches or creating release tags from them.

Publishing or uploading a release requires its explicit input (`publish`,
`publish_release`, or `upload`); leave it false for validation or artifact-only
runs. The Pages deployment workflow, where present, deploys when manually run.
Signing, notarization, and artifact verification remain part of release jobs.

Do not add automatic push, PR, schedule, or tag triggers without explicit
operator approval. A manual run opts in to that run only.

## Action dependencies and token permissions

Pin every external `uses:` reference to its full commit SHA. Keep the upstream
major version in a comment so updates remain understandable. When updating an
action, review its upstream release and resolve the intended tag to a commit
(for example, `gh api repos/actions/checkout/commits/v4 --jq .sha`). Review the
commit before replacing the pin; do not replace pins with floating tags.

Workflows default to `contents: read`. Grant release, Pages, and OIDC write
permissions only to jobs that need them. Checkout credentials stay disabled
except in Action and Blink tag-publishing runs, which use authenticated `git push`.
Adding a new Git operation must not silently broaden credentials for other jobs.

Validate workflow edits locally with `actionlint -shellcheck= -pyflakes=` and
`git diff --check`. This checks workflow syntax and expressions without running
release jobs; it does not validate embedded shell or Python programs. Test changes
to those programs separately. Preserve manual triggers and publish/upload inputs.
