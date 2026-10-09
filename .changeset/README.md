# Release notes

Run `npm ci`, then `npm run changeset` on each feature branch. Select `spillcheck`,
choose `patch`, `minor`, or `major`, and describe the user-visible change. Changesets
takes the highest requested bump across all pending notes for the next release.
Before 1.0, use patch for fixes, minor for new functionality or incompatible changes,
and major only for an intentional 1.0 release.

For documentation, tests, or CI work, run `npm run changeset -- --empty` and edit
the generated Markdown file to explain why no app version bump is needed. An
empty file or a note inherited from `main` does not pass validation. Changes to app
code or production dependencies require a version bump.

Do not edit app version fields, the manifest version, or generated release files
by hand. After successful `main` CI, automation updates one release PR. Merging
that PR and passing `main` CI creates the version tag and a GitHub Release with
the changelog. App distribution is tracked separately.
