// Enforce the PR changeset policy and validate the generated release PR's exact contents.
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseDocument } from "yaml";
import { git, readAppMetadata, readFileAt, readFileAtIfPresent, runAsScript, validateMetadata } from "./release-metadata.mjs";
import { versionRelease } from "./version-release.mjs";

const isNotePath = (path) => /^\.changeset\/[^/]+\.md$/.test(path) && path !== ".changeset/README.md";
// Node only runs repository automation, so scripts/*.mjs cannot change the shipped app.
const toolingPaths = new Set([".gitignore", ".nvmrc", ".changeset/config.json", ".changeset/README.md"]);
const isToolingPath = (path) => toolingPaths.has(path) || /^scripts\/[^/]+\.mjs$/.test(path);
const isDocumentationPath = (path) => /^docs\//.test(path) || /^[^/]+\.md$/.test(path) || /(^|\/)README\.md$/.test(path);

export function assertAppSlug(slug) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug ?? "")) {
    throw new Error("Set CHANGESETS_APP_SLUG to the installed GitHub App slug, without [bot]");
  }
  return slug;
}

export function parseChangeset(contents, path = "changeset") {
  const match = /^---\r?\n((?:[^\n]*\n)*?)---\r?\n([\s\S]*)$/.exec(contents);
  if (!match) throw new Error(`${path}: expected YAML frontmatter followed by an explanation`);
  const document = parseDocument(match[1], { uniqueKeys: true });
  if (document.errors.length) throw new Error(`${path}: ${document.errors[0].message}`);
  const releases = document.toJS({ maxAliasCount: 0 }) ?? {};
  if (typeof releases !== "object" || Array.isArray(releases)) throw new Error(`${path}: frontmatter must be a package-to-bump mapping`);
  for (const [name, bump] of Object.entries(releases)) {
    if (name !== "spillcheck") throw new Error(`${path}: unknown package ${name}`);
    if (!["major", "minor", "patch"].includes(bump)) throw new Error(`${path}: invalid semver bump ${bump}`);
  }
  const summary = match[2].replace(/<!--[\s\S]*?-->/g, "").trim();
  if (!summary) throw new Error(`${path}: explain the feature or why no version bump is needed`);
  return { releases, summary, empty: Object.keys(releases).length === 0 };
}

function changedFiles(root, base, head) {
  const output = execFileSync("git", ["diff", "--name-status", "--no-renames", "-z", base, head], { cwd: root, encoding: "utf8" });
  const values = output.split("\0").filter(Boolean);
  const files = [];
  for (let index = 0; index < values.length; index += 2) files.push({ status: values[index], path: values[index + 1] });
  return files;
}

function toolingManifestOnly(root, base, head) {
  const beforeContents = readFileAtIfPresent({ root, ref: base, path: "package.json" });
  const afterContents = readFileAtIfPresent({ root, ref: head, path: "package.json" });
  if (!afterContents) return false;
  const before = beforeContents ? JSON.parse(beforeContents) : {};
  const after = JSON.parse(afterContents);
  if (after.name !== "spillcheck" || after.private !== true || after.dependencies || after.optionalDependencies || after.peerDependencies) return false;
  if (Object.keys(after.devDependencies ?? {}).some((name) => !["@changesets/cli", "semver", "yaml"].includes(name))) return false;
  const editable = new Set(["description", "engines", "scripts", "devDependencies", "packageManager"]);
  if (!beforeContents) editable.add("name").add("private").add("version");
  for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (!editable.has(key) && !isDeepStrictEqual(before[key], after[key])) return false;
  }
  return true;
}

function toolingLockOnly(root, head) {
  const contents = readFileAtIfPresent({ root, ref: head, path: "package-lock.json" });
  if (!contents) return false;
  const lock = JSON.parse(contents);
  const rootPackage = lock.packages?.[""];
  return !!rootPackage && !rootPackage.dependencies && !rootPackage.optionalDependencies && !rootPackage.peerDependencies &&
    Object.entries(lock.packages).every(([path, entry]) => path === "" || entry.dev === true);
}

function needsAppBump(root, base, head, path) {
  if (isNotePath(path) || isToolingPath(path) || isDocumentationPath(path) || /^(Tests|\.github)\//.test(path)) return false;
  if (path === "package.json") return !toolingManifestOnly(root, base, head);
  if (path === "package-lock.json") return !toolingManifestOnly(root, base, head) || !toolingLockOnly(root, head);
  return true;
}

function assertOrdinaryMetadata(root, base, head) {
  const before = readAppMetadata({ root, ref: base });
  const after = validateMetadata({ root, ref: head });
  if (!isDeepStrictEqual(before, after)) throw new Error("Ordinary PRs must request version/build changes through a changeset");
  const baseManifest = readFileAtIfPresent({ root, ref: base, path: "package.json" });
  if (baseManifest && JSON.parse(baseManifest).version !== after.version) throw new Error("Only the generated release PR may change the manifest version");
  if (git(root, ["diff", "--name-only", base, head, "--", "CHANGELOG.md"])) throw new Error("CHANGELOG.md is generated by the release PR");
}

export function validateGeneratedRelease({ root = process.cwd(), base, head }) {
  const files = changedFiles(root, base, head);
  const allowed = new Set(["package.json", "package-lock.json", "Spillcheck/Info.plist", "CHANGELOG.md"]);
  for (const file of files) {
    if (!allowed.has(file.path) && !(file.status === "D" && isNotePath(file.path))) {
      throw new Error(`Release PR changed an unexpected file: ${file.path}`);
    }
  }
  const directory = mkdtempSync(join(tmpdir(), "spillcheck-release-check-"));
  const clone = join(directory, "repository");
  try {
    execFileSync("git", ["clone", "--quiet", "--shared", "--no-checkout", root, clone], { stdio: ["ignore", "pipe", "pipe"] });
    execFileSync("git", ["checkout", "--quiet", "--detach", base], { cwd: clone, stdio: ["ignore", "pipe", "pipe"] });
    const expected = versionRelease({ root: clone });
    if (!expected.changed) throw new Error("The release PR must consume an app version bump");
    validateMetadata({ root, ref: head, requireChangelog: true });
    const expectedFiles = new Set(git(clone, ["diff", "--name-only"]).split("\n").filter(Boolean));
    if (existsSync(join(clone, "CHANGELOG.md")) && !readFileAtIfPresent({ root, ref: base, path: "CHANGELOG.md" })) expectedFiles.add("CHANGELOG.md");
    if (!isDeepStrictEqual([...expectedFiles].sort(), files.map((file) => file.path).sort())) throw new Error("Release PR files do not match the generated release");
    for (const path of expectedFiles) {
      const expectedContents = existsSync(join(clone, path)) ? readFileSync(join(clone, path), "utf8") : null;
      const actualContents = readFileAtIfPresent({ root, ref: head, path });
      if (expectedContents !== actualContents) throw new Error(`Release PR does not match generated content: ${path}`);
    }
    return { ...expected, files: [...expectedFiles] };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// Identifies the App-owned Changesets PR from the same repository. Merge checks are the caller's job.
export function isTrustedReleasePR(pullRequest, appSlug) {
  return !!appSlug && pullRequest?.head?.ref === "changeset-release/main" &&
    !!pullRequest.head.repo?.full_name && pullRequest.head.repo.full_name === pullRequest.base?.repo?.full_name &&
    pullRequest.user?.login === `${appSlug}[bot]` && pullRequest.user?.type === "Bot";
}

export function validateChangesetPolicy({ root = process.cwd(), base, head, pullRequest, appSlug }) {
  const mergeBase = git(root, ["merge-base", base, head]);
  if (isTrustedReleasePR(pullRequest, appSlug)) {
    if (mergeBase !== git(root, ["rev-parse", base])) throw new Error("The generated release PR must be up to date with main");
    return validateGeneratedRelease({ root, base: mergeBase, head });
  }
  assertOrdinaryMetadata(root, mergeBase, head);
  const files = changedFiles(root, mergeBase, head);
  const notes = files.filter((file) => isNotePath(file.path));
  if (notes.some((file) => file.status !== "A")) throw new Error("Ordinary PRs may only add new changesets, not edit or remove inherited notes");
  if (!notes.length) throw new Error("Add a new changeset on this branch, including for work with no version bump");
  const parsed = notes.map((file) => parseChangeset(readFileAt({ root, ref: head, path: file.path }), file.path));
  const releaseRequired = files.some((file) => needsAppBump(root, mergeBase, head, file.path));
  if (releaseRequired && parsed.every((note) => note.empty)) throw new Error("App code, production dependencies, or unknown paths require a spillcheck version bump");
  if (!releaseRequired && parsed.some((note) => !note.empty)) {
    throw new Error("Documentation, tests, CI, and release-tooling changes must use an empty changeset; they do not change the app");
  }
  return { notes: notes.map((file) => file.path), releaseRequired };
}

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  if (!process.argv[index + 1] || process.argv[index + 1].startsWith("--")) throw new Error(`${name} requires a value`);
  return process.argv[index + 1];
}

runAsScript(import.meta.url, () => {
  const event = process.env.GITHUB_EVENT_PATH ? JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")) : {};
  const pullRequest = event.pull_request;
  const base = argumentValue("--base") ?? pullRequest?.base?.sha;
  const head = argumentValue("--head") ?? pullRequest?.head?.sha;
  if (!base || !head) {
    if (pullRequest || argumentValue("--base") || argumentValue("--head")) throw new Error("Changeset validation requires both base and head commit SHAs");
    validateMetadata();
    console.log("Release metadata agrees; PR changeset policy applies on pull requests");
    return;
  }
  // Without the App slug, a PR event would judge the generated release PR as an ordinary PR.
  const appSlug = pullRequest ? assertAppSlug(process.env.CHANGESETS_APP_SLUG) : process.env.CHANGESETS_APP_SLUG;
  const result = validateChangesetPolicy({ base, head, pullRequest, appSlug });
  console.log(`Changeset policy passed: ${result.notes?.join(", ") ?? `generated ${result.version} release`}`);
});
