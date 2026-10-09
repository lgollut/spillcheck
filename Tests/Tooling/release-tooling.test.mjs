import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { git, validateMetadata, extractChangelogSection } from "../../scripts/release-metadata.mjs";
import { assertAppSlug, parseChangeset, validateChangesetPolicy, validateGeneratedRelease } from "../../scripts/check-changesets.mjs";
import { versionRelease } from "../../scripts/version-release.mjs";
import { gitRepository, infoPlist, project, writeFile as write } from "./release-fixtures.mjs";

const manifestPaths = ["package.json", "package-lock.json", ".changeset/config.json"];

function writeToolingBaseline(root) {
  for (const path of manifestPaths) {
    const contents = JSON.parse(readFileSync(join(project, path), "utf8"));
    if (path === "package.json" || path === "package-lock.json") contents.version = "0.1.0";
    if (path === "package-lock.json") contents.packages[""].version = "0.1.0";
    write(root, path, `${JSON.stringify(contents, null, 2)}\n`);
  }
}

function commit(root, message = "Fixture change") {
  git(root, ["add", "--all"]);
  git(root, ["commit", "--quiet", "-m", message]);
  return git(root, ["rev-parse", "HEAD"]);
}

function fixture(t, { bootstrap = false } = {}) {
  const root = gitRepository(t, "spillcheck-release-test-");
  write(root, "Spillcheck/Info.plist", infoPlist("0.1.0", 1));
  write(root, "docs/guide.md", "Contributor notes\n");
  if (!bootstrap) {
    writeToolingBaseline(root);
  }
  const base = commit(root, "Initial fixture");
  return { root, base };
}

function note(root, name, bump = "patch", summary = "Fix a scanner edge case.") {
  write(root, `.changeset/${name}.md`, `---\n${bump ? `"spillcheck": ${bump}` : "{}"}\n---\n\n${summary}\n`);
}

function trusted(base, head, extra = {}) {
  return { user: { login: "spillcheck-release[bot]", type: "Bot" }, head: { sha: head, ref: "changeset-release/main", repo: { full_name: "owner/spillcheck" } }, base: { sha: base, repo: { full_name: "owner/spillcheck" } }, ...extra };
}

test("changesets reject unknown packages, invalid bumps, malformed YAML, and missing explanations", () => {
  for (const contents of [
    '---\nother: patch\n---\n\nExplain it.\n',
    '---\nspillcheck: none\n---\n\nExplain it.\n',
    '---\nspillcheck: patch\nspillcheck: minor\n---\n\nExplain it.\n',
    '---\n[spillcheck, patch]\n---\n\nExplain it.\n',
    '---\n{}\n---\n\n<!-- An empty template -->\n',
    'Explain a change without frontmatter.',
  ]) assert.throws(() => parseChangeset(contents));
  assert.equal(parseChangeset('---\n\n---\n\nDocumentation only.\n').empty, true);
  assert.equal(parseChangeset('---\n---\n\nDocumentation only.\n').empty, true);
  assert.equal(parseChangeset('---\r\n"spillcheck": patch\r\n---\r\n\r\nFix scanner detection.\r\n').empty, false);
});

test("pending changesets inherited from main cannot satisfy a new PR", (t) => {
  const { root } = fixture(t);
  note(root, "inherited");
  const base = commit(root);
  write(root, "Sources/Core.swift", "let feature = true\n");
  const head = commit(root);
  assert.throws(() => validateChangesetPolicy({ root, base, head }), /Add a new changeset/);
  note(root, "inherited", "minor");
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /inherited notes/);
});

test("explained empty notes pass docs, CI, and release tooling but fail production, unknown, and mixed changes", (t) => {
  const { root, base } = fixture(t);
  note(root, "docs", null, "Document release setup; app behavior is unchanged.");
  write(root, "docs/guide.md", "New contributor instructions\n");
  write(root, ".github/workflows/ci.yml", "name: CI\n");
  write(root, "scripts/release-helper.mjs", "export {};\n");
  write(root, "scripts/README.md", "Release helper notes\n");
  const toolingHead = commit(root);
  assert.equal(validateChangesetPolicy({ root, base, head: toolingHead }).releaseRequired, false);
  for (const path of ["Sources/Core.swift", "Package.swift", "Dependencies/Scanner/dependencies.json", "scripts/build-app.sh", "Makefile", "Unclassified/config.json"]) {
    git(root, ["reset", "--quiet", "--hard", toolingHead]);
    write(root, path, "production change\n");
    assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /require a spillcheck version bump/, path);
  }
  note(root, "feature", "minor", "Add the production feature.");
  assert.equal(validateChangesetPolicy({ root, base, head: commit(root) }).releaseRequired, true);
});

test("docs, tests, CI, and release-tooling changes cannot request an app release", (t) => {
  const { root, base } = fixture(t);
  write(root, "docs/guide.md", "New contributor instructions\n");
  write(root, "Tests/Tooling/release.test.mjs", "export {};\n");
  write(root, "scripts/release-helper.mjs", "export {};\n");
  note(root, "docs", "patch", "Document the release flow.");
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /must use an empty changeset/);
  rmSync(join(root, ".changeset/docs.md"));
  note(root, "docs-explained", null, "Document the release flow; app behavior is unchanged.");
  note(root, "docs-bump", "minor", "Release the documentation.");
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /must use an empty changeset/);
});

test("the App slug must be a GitHub App slug without its bot suffix", () => {
  assert.equal(assertAppSlug("spillcheck-release"), "spillcheck-release");
  for (const slug of [undefined, "", "spillcheck-release[bot]", "Spillcheck", "a--b", "-release", "release-"]) {
    assert.throws(() => assertAppSlug(slug), /without \[bot\]/, String(slug));
  }
});

test("tooling bootstrap preserves the baseline and accepts an explicit empty note", (t) => {
  const { root, base } = fixture(t, { bootstrap: true });
  writeToolingBaseline(root);
  note(root, "infrastructure", null, "Set up CI and release tooling without changing the app.");
  const head = commit(root);
  assert.equal(validateChangesetPolicy({ root, base, head }).releaseRequired, false);
  const result = versionRelease({ root });
  assert.equal(result.changed, false);
  assert.equal(result.version, "0.1.0");
  assert.equal(result.build, 1);
});

test("manifest dependency and non-tooling fields do not bypass release policy", (t) => {
  const { root, base } = fixture(t);
  note(root, "tooling", null, "Adjust release tooling only.");
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  manifest.description = "Updated release tooling description";
  write(root, "package.json", `${JSON.stringify(manifest, null, 2)}\n`);
  assert.equal(validateChangesetPolicy({ root, base, head: commit(root) }).releaseRequired, false);
  manifest.dependencies = { "production-library": "1.0.0" };
  write(root, "package.json", `${JSON.stringify(manifest, null, 2)}\n`);
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /require a spillcheck version bump/);
});

test("ordinary PRs cannot edit versions or generated changelog", (t) => {
  const { root, base } = fixture(t);
  note(root, "docs", null, "No app change.");
  const plistPath = join(root, "Spillcheck/Info.plist");
  writeFileSync(plistPath, readFileSync(plistPath, "utf8").replace("<string>1</string>", "<string>2</string>"));
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /version\/build changes/);
  git(root, ["checkout", base, "--", "Spillcheck/Info.plist"]);
  write(root, "CHANGELOG.md", "## 0.1.0\n\nManual notes\n");
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root) }), /CHANGELOG.md is generated/);
});

test("patches and a minor accumulate once with synchronized lock and deterministic app build", (t) => {
  const { root } = fixture(t);
  note(root, "patch-one", "patch", "Fix the first edge case.");
  note(root, "patch-two", "patch", "Fix the second edge case.");
  note(root, "minor", "minor", "Add a scanner feature.");
  note(root, "docs", null, "Update contributor docs without changing app behavior.");
  const base = commit(root);
  const first = versionRelease({ root });
  assert.equal(first.version, "0.2.0");
  assert.equal(first.build, 2);
  assert.equal(first.changed, true);
  const generated = readFileSync(join(root, "CHANGELOG.md"), "utf8");
  for (const summary of ["first edge case", "second edge case", "scanner feature"]) assert.match(generated, new RegExp(summary));
  assert.equal(validateMetadata({ root, requireChangelog: true }).version, "0.2.0");
  assert.equal(JSON.parse(readFileSync(join(root, "package-lock.json"), "utf8")).packages[""].version, "0.2.0");
  const head = commit(root);
  assert.equal(validateGeneratedRelease({ root, base, head }).build, 2);
  const second = versionRelease({ root });
  assert.equal(second.changed, false);
  assert.equal(second.build, 2);
  git(root, ["reset", "--hard", base]);
  assert.equal(versionRelease({ root }).build, 2);
  assert.equal(readFileSync(join(root, "CHANGELOG.md"), "utf8"), generated);
  git(root, ["reset", "--hard", base]);
  rmSync(join(root, "CHANGELOG.md"), { force: true });
  note(root, "later-merge", "minor", "Add another scanner feature after the release PR opens.");
  commit(root);
  const refreshed = versionRelease({ root });
  assert.equal(refreshed.version, "0.2.0");
  assert.equal(refreshed.build, 2);
  assert.match(readFileSync(join(root, "CHANGELOG.md"), "utf8"), /another scanner feature/);
});

test("only the trusted app release PR is exempt, with exact generated content", (t) => {
  const { root } = fixture(t);
  note(root, "feature", "minor", "Add a scanner feature.");
  const base = commit(root);
  versionRelease({ root });
  const head = commit(root);
  const pullRequest = trusted(base, head);
  assert.equal(validateChangesetPolicy({ root, base, head, pullRequest, appSlug: "spillcheck-release" }).version, "0.2.0");
  const spoof = trusted(base, head, { user: { login: "a-human", type: "User" } });
  assert.throws(() => validateChangesetPolicy({ root, base, head, pullRequest: spoof, appSlug: "spillcheck-release" }));
  const fork = trusted(base, head, { head: { ...pullRequest.head, repo: { full_name: "fork/spillcheck" } } });
  assert.throws(() => validateChangesetPolicy({ root, base, head, pullRequest: fork, appSlug: "spillcheck-release" }));
  write(root, "CHANGELOG.md", readFileSync(join(root, "CHANGELOG.md"), "utf8").replace("scanner feature", "invented release content"));
  assert.throws(() => validateChangesetPolicy({ root, base, head: commit(root), pullRequest, appSlug: "spillcheck-release" }), /generated content/);
});

test("release PR cannot carry app edits or stale base contents", (t) => {
  const { root } = fixture(t);
  note(root, "feature", "patch");
  const base = commit(root);
  git(root, ["checkout", "--quiet", "-b", "changeset-release/main"]);
  versionRelease({ root });
  const head = commit(root);
  write(root, "Sources/Core.swift", "let hiddenEdit = true\n");
  assert.throws(() => validateGeneratedRelease({ root, base, head: commit(root) }), /unexpected file/);
  git(root, ["checkout", "--quiet", "main"]);
  write(root, "docs/guide.md", "A new merge landed\n");
  const newerBase = commit(root);
  assert.throws(() => validateChangesetPolicy({ root, base: newerBase, head, pullRequest: trusted(newerBase, head), appSlug: "spillcheck-release" }), /up to date/);
});

test("metadata and changelog reject mismatched versions and ambiguous sections", (t) => {
  const { root } = fixture(t);
  const lockPath = join(root, "package-lock.json");
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  lock.packages[""].version = "0.2.0";
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  assert.throws(() => validateMetadata({ root }), /versions must agree/);
  assert.equal(extractChangelogSection("# spillcheck\n\n## 0.2.0\n\nNew behavior\n\n## 0.1.0\n\nOld behavior\n", "0.2.0"), "New behavior");
  assert.throws(() => extractChangelogSection("## 0.2.0\n\nOne\n\n## 0.2.0\n\nTwo\n", "0.2.0"), /exactly one/);
  assert.throws(() => extractChangelogSection("## 0.2.0\n", "0.2.0"), /empty/);
});
