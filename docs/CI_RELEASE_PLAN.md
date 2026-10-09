# CI, Changesets, and GitHub releases

Status: proposed implementation. This document adds no workflows or release automation.

## Intended behavior

Every feature branch adds a changeset naming `spillcheck`, a semver bump, and a user-facing explanation. Its pull request must pass tests and changeset validation. After merge, successful `main` CI creates or updates one release PR on `changeset-release/main`.

That release PR contains the next version, generated changelog, synchronized app metadata, and deletion of the consumed changesets. It stays open and accumulates later merges until a maintainer merges it. The merged release commit must pass `main` CI before automation pushes `vX.Y.Z` pointing to that exact commit. The tag starts a separate workflow that publishes a GitHub Release using the matching changelog section.

Confirmed scope:

- The first release pipeline publishes a GitHub Release and changelog, with no app assets. Signed app assets come later, after the existing release checks pass.
- Docs, tests, and CI-only PRs still add an explicit empty changeset explaining why there is no version bump.
- Release PRs remain a manual merge decision.

## Repository findings

- This is a Swift/macOS app, with Swift 6 and a macOS 14 deployment baseline in `Package.swift`. There is no existing Node manifest, Changesets configuration, or GitHub Actions workflow.
- `make scanner-dependencies` installs and verifies the pinned scanner. `make test` prepares it and runs `swift test`. The installer rejects hosts other than macOS arm64.
- `README.md` specifies Xcode 27. GitHub currently advertises the arm64 `xcode-27` image as a preview. Use that explicit runner and select Xcode 27.0 rather than a changing default. Verify availability during the first hosted run. [Runner catalog](https://github.com/actions/runner-images), [Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
- `Spillcheck/Info.plist` currently contains app version `0.1.0` and build `1`. Use these as the starting metadata; setup alone should not manufacture a release or tag for `0.1.0`.
- GitHub reports `main` as the default branch, no existing Actions workflows or releases, no rulesets, and no branch protection. Workflow permissions default to read-only.
- `docs/implementation/release-checks.json` records `releaseReady: false`. Outstanding checks include macOS 14, hardware without Touch ID, Developer ID/notarization, installation and update key persistence, and login launch. The current packager does not enforce this JSON record. Changelog publication can proceed within the confirmed scope; app distribution requires a separate implementation and its existing acceptance checks.

## Version and changelog ownership

Add a private root `package.json` named `spillcheck`, initially version `0.1.0`. It exists for release tooling; Swift remains the app build system. Add a committed npm lockfile, Node 24 tooling, and a pinned Changesets CLI dependency. CI installs with `npm ci`.

Configure `.changeset/config.json` with `baseBranch: "main"`, changelog generation enabled, no automatic local commits, and `privatePackages: { "version": true, "tag": false }`. Changesets supports non-npm/private packages. We will own tagging separately. The released root action reads this configuration; it has no separate private-version/private-tag inputs. Use the researched CLI v3/action v2 APIs rather than older examples. [Changesets configuration](https://github.com/changesets/changesets/blob/main/docs/config-file-options.md), [Released action inputs](https://github.com/changesets/action/blob/v2.1.2/action.yml).

Developer commands will be:

```sh
npm ci
npm run changeset
# For changes that do not need a release:
npm run changeset -- --empty
```

An empty changeset still needs a written explanation. The action does not open a release PR for an empty-only set. Those files remain on `main` until a later nonempty release consumes them. [Adding changesets](https://github.com/changesets/changesets/blob/main/docs/adding-a-changeset.md), [Action behavior](https://github.com/changesets/action/blob/main/src/index.ts).

A version wrapper will run Changesets, synchronize the npm lockfile's root version, set `CFBundleShortVersionString` to the new version, and increment `CFBundleVersion` once per release. Rebuilding the release PR from the same `main` state must produce the same version and build number. It must not increment the build on every feature merge or bot refresh.

Changesets takes the highest requested bump for the pending release. Two patch changesets and one minor changeset from `0.1.0` produce `0.2.0`, with all their explanations in the changelog. Two minor changesets do not produce `0.3.0`. Treat `major` as an intentional move toward the next major version and document the pre-1.0 compatibility policy. [Release-plan calculation](https://github.com/changesets/changesets/tree/main/packages/assemble-release-plan).

## Workflow layout

### `.github/workflows/ci.yml`

Run on `pull_request` targeting `main` and `push` to `main`. Use read-only repository permissions for validation and no release secrets on PR jobs. Do not use `pull_request_target` to execute contributed code.

Required checks:

1. **Changeset policy.** On normal PRs, compare the PR head with its merge base against the target branch. Require a newly added `.changeset/*.md` file, excluding the README. Pending files inherited from `main`, editing an existing pending changeset, or a directory-existence check must not satisfy this requirement. Parse the file, validate its summary, package name, and bump type. Reject malformed changesets. Accept empty changesets only when every other changed file falls in an explicit docs/tests/CI allowlist. Start with documentation, `Tests/**`, workflow files, and the named release-tooling files introduced here. Unknown paths, app/core/hook source changes, production dependency changes, and mixed PRs require an actual `spillcheck` bump. Handle tooling-manifest changes by checking the changed fields, rather than allowing any edit to a package/dependency manifest. A reviewer still checks the explanation and appropriateness of the requested semver bump.
2. **Core tests.** On macOS arm64, select Xcode 27.0, set up Python, run `make scanner-dependencies`, then `make test`. Set `SPILLCHECK_TEST_PYTHON` to the selected Python executable because detector fixtures otherwise assume a particular Xcode Python path. Report optional signed/live checks as outside this CI scope.
3. **Tooling tests.** Run `python3 Tests/Tooling/check-scanner-bundling.py` and `python3 Tests/Tooling/check-release-policy.py`. Build `spillcheck-hook` with SwiftPM, resolve its actual bin path, and run `Tests/HookHelper/test_delivery.py` with `SPILLCHECK_HOOK_TEST_EXECUTABLE` set. Include provider-free Python evidence/boundary unit tests that exist in the implementation commit. Some current local tests are untracked, so workflow paths must be checked against the committed tree. These use fixtures and fake tools, not Apple signing credentials. Pilot the existing narrow timing assertions on a hosted runner before making them required.
4. **App compilation.** Install XcodeGen and run `xcodegen generate --spec project.yml` explicitly rather than depending on checkout file timestamps. Build Debug on the same arm64 toolchain using `scripts/build-app.sh --configuration Debug --derived-data .build/ci-app CODE_SIGNING_ALLOWED=NO`, with pinned scanner resources prepared. This catches app-only Swift errors outside the package tests. It verifies compilation only.
5. **Release metadata.** Check that the manifest, lockfile, and app version agree. Ordinary PRs request version changes through changesets. For the trusted release PR, recompute the generated release from its base and verify its proposed version/changelog/metadata and consumed files.

The release PR cannot add a new changeset because it consumes them. Its policy exception must check the same repository, exact release branch, expected GitHub App author, and generated release contents. A matching branch name or PR title alone is insufficient. It still passes every other required check.

Cancel obsolete runs for the same PR. Keep each `main` push run independent so a later feature merge cannot cancel the run responsible for tagging a release commit. Initially cache verified scanner downloads and npm downloads; only introduce Swift build caches after validating a clean hosted run. Preserve checksum verification on cache hits.

The app setup and native workflow contract probes are also provider-free, but their launchers currently depend on a specific static-library product layout. Confirm or adapt that layout before treating them as required hosted checks. Real provider sessions, real authentication, GUI acceptance, and resource measurements remain separate checks; they are not prerequisites for publishing changelog-only metadata.

### `.github/workflows/release-pr.yml`

Use a reusable `workflow_call` workflow invoked only by successful `main` CI, with the tested commit passed explicitly. This avoids duplicate test runs and a privileged `workflow_run` bridge.

It has two separate jobs:

- **Maintain the release PR.** Use the Changesets root action in version-only mode with `version-script` pointing to our wrapper and `github-token` pointing to the App token. Omit `publish-script` and disable `create-github-releases` and `push-git-tags` so the separate tag/publication jobs own those actions. It resets and regenerates the dedicated release branch from `main`, creates a PR if needed, and updates the existing PR otherwise. Run only for a still-current tested `main` snapshot. Serialize updates to the release branch, and let a later successful `main` run refresh it if the branch advances while a job runs. Do not manually edit this generated branch. Pin a released action commit after reviewing its inputs. [Released action](https://github.com/changesets/action/tree/v2.1.2).
- **Tag a released version.** Inspect the exact tested commit and its parent, confirm a version increase came from the trusted merged release PR, validate matching manifest/plist/changelog metadata, and push `vX.Y.Z` at that commit. Do not gate tagging on there being no pending changesets on the latest `main`. A newer feature may already have landed. Do not put tag creation in the coalescing release-PR concurrency group.

Tag creation is idempotent. An existing matching tag is success; a tag pointing elsewhere is an error and is never moved. Normal feature merges and empty-only changes never create tags. An initial tooling-manifest addition is not a release merge. Rerunning the original successful release-merge workflow is the recovery path for a failed tag push.

Version-only Changesets does not create tags after merge by itself. The explicit tag job is necessary for this flow. [Action version/publish selection](https://github.com/changesets/action/blob/main/src/index.ts).

### `.github/workflows/release.yml`

Run on `push` for `v*` tags. Filter and validate actual supported semver tags inside the job; the glob alone is not enough.

Check out the tag commit, validate it is a tested release merge on `main`, and require tag version = manifest version = app version = matching changelog heading. Verify the individual required test/validation jobs succeeded for that exact SHA in an eligible main CI run, using `actions: read`; use `pull-requests: read` to verify the merged release PR. The originating workflow may still be finishing its other release-automation job when the tag event arrives, so do not require the aggregate workflow conclusion to have finished already. Extract only that version's changelog section and publish a GitHub Release named `Spillcheck vX.Y.Z` with no binary assets. Do not substitute GitHub-generated commit notes for the Changesets changelog. No npm publication, signing credentials, or notarization upload is part of this phase.

Serialize publication per tag and make retries safe. Reuse a matching existing GitHub Release rather than creating a second one or moving its tag. If tag creation succeeded but publication failed, rerun the tag workflow. Describe the release as changelog-only so it does not imply a downloadable app is available.

## GitHub setup

Create a dedicated GitHub App installed only on this repository, with Contents and Pull requests write access. Store its app/client ID and private key as Actions configuration/secrets and mint a short-lived installation token in each trusted main release job that writes. Tokens are revoked when their job finishes; do not pass one job's token to another job. Use App authentication both for the generated PR updates and tag pushes. Configure checkout/git writes with that token too, rather than only passing it to the Changesets API input.

This is required for the requested automatic event chain. Tags pushed with `GITHUB_TOKEN` do not start push-triggered release workflows. Current GitHub behavior allows PR events created with that token only in an approval-required state. An App token allows those PR checks and tag workflows to run automatically. The tag-triggered workflow itself can use a narrowly scoped `GITHUB_TOKEN` with `contents: write` to publish release metadata. [GitHub workflow triggers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow), [App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow).

Add branch protection or a ruleset for `main` after the check names exist. Require the CI checks, PR-based merges, and an up-to-date branch before merging. This also prevents a stale release PR from leaving out a feature that has already landed. Protect the generated release branch from human edits while explicitly permitting this App to reset/force-update that branch. Protect version tags from replacement. The automation does not need to bypass `main` protection or merge its own PR.

Pin third-party Actions to reviewed release commit SHAs. Give write permissions only to the jobs that mutate PRs/tags/releases. Explicitly grant `actions: read` and `pull-requests: read` to provenance checks and their reusable-workflow caller, since declaring a permissions map zeros unspecified permissions and a called workflow cannot elevate them. Existing repository-wide read-only defaults can remain.

## Implementation sequence

1. Add the private tooling manifest, lockfile, Node version, Changesets configuration, and contributor instructions. Preserve `0.1.0` / build `1` as the baseline. Add a changeset for this infrastructure work under the agreed no-bump policy.
2. Add the changeset validator and version synchronization wrapper. Verify them in temporary repositories against the cases below.
3. Add PR/main CI and app compilation. Run on a clean arm64 hosted runner, confirm scanner preparation and toolchain availability, and resolve any fixture/product-layout assumptions before requiring the checks.
4. Add version-only release PR automation and the separately gated tag job. Configure the GitHub App and repository rules. Test accumulation and regeneration with throwaway fixtures before enabling writes.
5. Add tag-triggered changelog-only GitHub Releases, including version/provenance guards and retry handling.
6. Exercise the complete path with two feature PRs and one release PR. Then add signed app distribution as a separate project once the recorded checks and credentials are ready.

Expected files include `package.json`, `package-lock.json`, `.changeset/config.json`, `.changeset/README.md`, a Node version file, the three workflow files, `scripts/check-changesets.mjs`, `scripts/version-release.mjs`, tagging/changelog helpers, and focused release-tooling tests. Update `.gitignore` for `node_modules/`, contributor docs, and the Makefile only where a shared CI command reduces duplication. No existing app behavior needs to change for changelog-only publication.

## Acceptance cases

- A feature PR with no new changeset fails, even if `main` already contains pending changesets.
- An invalid package, bump type, malformed frontmatter, blank summary, or changed inherited changeset cannot satisfy validation.
- A documented empty changeset passes for nonrelease work. An empty-only merge creates no release PR, version bump, or tag.
- An empty changeset cannot bypass a bump for production source/dependency changes or a mixed feature-and-docs PR.
- Two patches and a minor accumulate in one release PR and compute `0.2.0` from `0.1.0`. A later refresh leaves the build increment at one.
- The trusted release PR passes its generated-content validation without adding another changeset. A spoofed branch/title does not get that exception.
- Failed main tests prevent release-PR writes and tagging for that commit.
- A release PR merged while newer feature work is arriving still tags its exact tested merge commit. Later feature merges open the next release PR.
- A rerun cannot create duplicate releases or change an existing tag target.
- A real App-authenticated release PR update runs PR CI, and a real App-authenticated tag push starts `release.yml`.
- Publication accepts the successful required test jobs even if the parent main workflow is still finishing release-PR maintenance, while rejecting a tag with no eligible tested release commit.
- The GitHub Release body matches its changelog section and has no app assets. Existing distribution checks are retained.

The first implementation should validate these release rules and pilot the existing suites. No tests, builds, workflows, credentials, branch protections, tags, or GitHub Releases were changed or executed as part of this analysis.
