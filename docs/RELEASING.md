# Releases

Spillcheck uses Changesets to version the macOS app. The private root
`package.json` supplies its version; nothing is published to npm. Node 26, pinned
in `.nvmrc` for local use and CI, runs the repository tooling. `package.json`, both root version fields in
`package-lock.json`, and `Spillcheck/Info.plist` must agree.

## Normal workflow

1. Create a feature branch from `main`, implement the change, and add a changeset
   with its explanation and `spillcheck` bump. Documentation, tests, CI, and
   release-tooling work must add an explained empty changeset; CI rejects a bump
   for it. See [Contributing](../CONTRIBUTING.md) for the exact paths.
2. Open a PR to `main`. CI checks that the branch added a valid changeset,
   runs the core and tooling tests, and compiles the unsigned Debug app. Core test
   cases run serially to avoid competing with each other's process and socket
   timing probes; their assertions and internal concurrency remain enabled.
3. Merge the reviewed PR after `Required checks` succeeds. Successful `main` CI
   creates or updates the App-owned `changeset-release/main` PR.
4. Leave the release PR open while more feature PRs merge. Automation regenerates
   it from `main`, consumes the pending changesets, computes the next version,
   updates the changelog and plist, and increments the app build number once.
   Do not hand-edit this branch: regeneration replaces its contents.
5. Review and merge the release PR when ready. It must be up to date with `main`;
   CI reproduces the generated release to validate its exact contents.
6. After the merged commit passes `main` CI, automation creates `vX.Y.Z` on that
   exact commit. The tag push triggers publication of a GitHub Release containing
   that version's changelog section.

Changesets applies the highest pending bump once. Starting at `0.1.0`, two patch
notes and one minor note produce `0.2.0`, not three successive releases. Rebuilding
an open release PR does not repeatedly increment the build number. Empty
changesets do not create a release PR on their own; they are consumed alongside
the next versioned release. The CI bootstrap PR therefore creates no tag or
release when merged.

The first release pipeline publishes a changelog only. GitHub may show its
automatic source archives, but the workflow uploads no app, DMG, or installer.
Signed app assets remain deferred until the recorded
[release checks](implementation/release-checks.json) pass.

## GitHub configuration before merging the CI bootstrap PR

The automation uses a private GitHub App installed only on this repository. Give
it repository **Contents: Read and write** and **Pull requests: Read and write**.
Webhooks are unnecessary. Set these under repository **Settings → Secrets and
variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `CHANGESETS_APP_CLIENT_ID` | The App's client ID |
| Variable | `CHANGESETS_APP_SLUG` | The App slug, without `[bot]` |
| Secret | `CHANGESETS_APP_PRIVATE_KEY` | The App's PEM private key |

Under **Settings → Actions → General**, enable Actions and permit GitHub-owned
actions plus `changesets/action@*`. Workflows pin actions to reviewed commit SHAs.
Default workflow permissions can remain read-only, and **Allow GitHub Actions to
create and approve pull requests** can remain off: the App token creates release
PRs and tags. PR jobs do not receive the App secret.

After the first bootstrap PR run makes the check available, finish these rules
before merging it:

1. Under **Settings → Rules → Rulesets**, create an active branch ruleset targeting
   `main`. Require a pull request, require status check **`Required checks`** from
   **GitHub Actions**, and require the branch to be up to date before merging.
   Block force pushes and deletion. A solo maintainer can require zero approving
   reviews. The release App does not need a bypass for `main`.
2. Create an active tag ruleset targeting `v*`. Restrict updates and deletion so
   published version tags remain immutable, with no bypass actors.
3. Create a second active tag ruleset targeting `v*` that restricts creations,
   with the release App as its only bypass actor (**Always allow**). Release tags
   are immutable, so a `vX.Y.Z` pushed by hand to the wrong commit would block
   that release. Keeping the bypass in this separate ruleset means the App can
   create tags but cannot update or delete them.

Do not apply a force-push restriction to `changeset-release/main` unless the
release App can bypass that restriction: Changesets regenerates that branch.

## Automation and recovery

`CI` runs on PRs and `main`. Only a successful required gate on a `main` push calls
the reusable release automation. Release-PR refreshes are serialized and skip
stale `main` commits; tagging runs separately so a later feature merge does not
discard a tested release commit. Each writing job mints its own short-lived App
token. GitHub's workflow token reads the Actions checks; the App token writes the
release PR and tag, allowing their events to trigger other workflows.

Tagging and publication verify the exact merged release PR, version metadata,
generated changes, `main` ancestry, and successful checks for the tagged commit.
They accept an existing tag only at the expected commit and never move it.
Publication accepts an existing GitHub Release only when it matches the expected
changelog-only release.

If release-PR creation fails after a successful `main` test run, fix the App
installation, permissions, or repository configuration and rerun the failed jobs.
If tagging fails, rerun the failed release-tag job in the original `main` run.
If publication fails after the tag exists, rerun the tag-triggered `GitHub Release` run.
Do not delete or move a published tag to retry. Inspect the workflow error before
changing any release metadata.

`npm run version:release` can preview versioning in a disposable branch or
worktree. It consumes changesets and edits release files, so do not run it on a
feature branch you intend to merge. The automated release PR owns those edits.
