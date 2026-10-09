// Describe the release PR, tag its tested merge, and publish the changelog-only GitHub Release.
import semver from "semver";
import {
  extractChangelogSection,
  git,
  parseReleaseVersion,
  readFileAt,
  readFileAtIfPresent,
  runAsScript,
  validateMetadata,
} from "./release-metadata.mjs";
import { assertAppSlug, isTrustedReleasePR, validateGeneratedRelease } from "./check-changesets.mjs";

const MAX_API_PAGES = 20;
const SHA_PATTERN = /^[a-f0-9]{40}$/;

export class GitHubApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function githubClient(token, { fetchImpl = fetch } = {}) {
  if (!token) throw new Error("A GitHub token is required");
  return {
    async request(method, path, { query = {}, body } = {}) {
      const url = new URL(path, "https://api.github.com/");
      for (const [key, value] of Object.entries(query)) url.searchParams.set(key, String(value));
      const response = await fetchImpl(url, {
        method,
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": "2022-11-28",
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(30_000),
      });
      if (!response.ok) {
        // The API can echo request details. Keep errors useful without printing credentials or bodies.
        throw new GitHubApiError(response.status, `GitHub ${method} ${path} failed (${response.status})`);
      }
      if (response.status === 204) return undefined;
      return response.json();
    },
  };
}

function assertRepository(repo) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo ?? "")) {
    throw new Error("GITHUB_REPOSITORY must identify owner/repository");
  }
}

function validateContext({ repo, sha, slug }) {
  assertRepository(repo);
  if (!SHA_PATTERN.test(sha ?? "")) throw new Error("GITHUB_SHA must be a full commit SHA");
  assertAppSlug(slug);
}

async function* pages(api, path, key, query = {}) {
  for (let page = 1; page <= MAX_API_PAGES; page += 1) {
    const response = await api.request("GET", path, { query: { ...query, per_page: 100, page } });
    const values = key ? response[key] : response;
    if (!Array.isArray(values)) throw new Error(`GitHub returned an invalid list for ${path}`);
    yield values;
    if (values.length < 100) return;
  }
  throw new Error(`GitHub pagination limit reached for ${path}; refusing incomplete provenance`);
}

function assertCheckoutAndMain({ root, sha }) {
  if (git(root, ["rev-parse", "HEAD"]) !== sha) {
    throw new Error("Release checkout must be the exact tested commit");
  }
  if (git(root, ["cat-file", "-t", sha]) !== "commit") throw new Error("Release SHA must be a commit");
  try {
    git(root, ["merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"]);
  } catch {
    throw new Error("Release commit must be on origin/main; fetch complete main history");
  }
}

function manifestAt(root, ref) {
  const contents = readFileAtIfPresent({ root, ref, path: "package.json" });
  return contents && JSON.parse(contents);
}

function releaseVersionChange({ root, sha }) {
  const current = manifestAt(root, sha);
  if (!current) throw new Error("Release commit is missing package.json");
  const version = parseReleaseVersion(current.version);
  let parent;
  try {
    parent = git(root, ["rev-parse", `${sha}^`]);
  } catch {
    return { version, reason: "initial release tooling" };
  }
  const previous = manifestAt(root, parent);
  if (!previous) return { version, reason: "initial release tooling" };
  const previousVersion = parseReleaseVersion(previous.version);
  if (version === previousVersion) return { version, reason: "version unchanged" };
  if (!semver.gt(version, previousVersion)) throw new Error("Release version must increase from the first parent");
  return { version, parent };
}

export async function trustedReleasePullRequest({ api, repo, sha, slug }) {
  const matching = [];
  for await (const pullRequests of pages(api, `/repos/${repo}/commits/${sha}/pulls`)) {
    for (const candidate of pullRequests) {
      if (!Number.isSafeInteger(candidate.number) || candidate.number < 1) continue;
      // Read canonical PR details rather than relying on a partial association response.
      const pr = await api.request("GET", `/repos/${repo}/pulls/${candidate.number}`);
      if (
        isTrustedReleasePR(pr, slug) && pr.base?.ref === "main" && pr.base.repo?.full_name === repo &&
        pr.state === "closed" && pr.merged === true && pr.merged_at && pr.merge_commit_sha === sha
      ) matching.push(pr);
    }
  }
  if (matching.length !== 1) throw new Error("Commit must be the exact merge of one trusted Changesets release PR");
  return matching[0];
}

export async function assertRequiredChecks({ api, repo, sha, runId }) {
  if (runId !== undefined && !/^[1-9]\d*$/.test(String(runId))) throw new Error("CI run ID must be a positive integer");
  for await (const runs of pages(api, `/repos/${repo}/actions/workflows/ci.yml/runs`, "workflow_runs", {
    event: "push", branch: "main", head_sha: sha,
  })) {
    for (const run of runs) {
      if (
        run.head_sha !== sha || run.event !== "push" || run.head_branch !== "main" ||
        run.head_repository?.full_name !== repo ||
        (runId !== undefined && String(run.id) !== String(runId))
      ) continue;
      for await (const jobs of pages(api, `/repos/${repo}/actions/runs/${run.id}/jobs`, "jobs", { filter: "latest" })) {
        if (jobs.some((job) => job.name === "Required checks" && job.status === "completed" && job.conclusion === "success")) {
          return run.id;
        }
      }
    }
  }
  throw new Error("No eligible main push CI run has successful Required checks for this exact commit");
}

export async function tagCommit({ api, repo, tag }) {
  let object;
  try {
    const ref = await api.request("GET", `/repos/${repo}/git/ref/tags/${tag}`);
    object = ref.object;
  } catch (error) {
    if (error.status === 404) return undefined;
    throw error;
  }
  for (let depth = 0; depth < 10; depth += 1) {
    if (!SHA_PATTERN.test(object?.sha ?? "")) throw new Error("GitHub returned an invalid tag target");
    if (object.type === "commit") return object.sha;
    if (object.type !== "tag") throw new Error("Release tag must resolve to a commit");
    const annotated = await api.request("GET", `/repos/${repo}/git/tags/${object.sha}`);
    object = annotated.object;
  }
  throw new Error("Release tag has too many nested annotated tags");
}

async function verifyRelease({ root, repo, sha, slug, api, ciApi, runId, validateRelease }) {
  validateContext({ repo, sha, slug });
  assertCheckoutAndMain({ root, sha });
  const change = releaseVersionChange({ root, sha });
  if (change.reason) return change;
  const metadata = validateMetadata({ root, ref: sha, requireChangelog: true });
  await validateRelease({ root, base: change.parent, head: sha });
  const pr = await trustedReleasePullRequest({ api, repo, sha, slug });
  await assertRequiredChecks({ api: ciApi, repo, sha, runId });
  return { ...change, ...metadata, pr };
}

export async function tagRelease({
  root = process.cwd(), repo, sha, slug, api, ciApi = api, runId,
  validateRelease = validateGeneratedRelease,
  push = (tag) => git(root, ["push", "origin", `${sha}:refs/tags/${tag}`]),
}) {
  const release = await verifyRelease({ root, repo, sha, slug, api, ciApi, runId, validateRelease });
  if (release.reason) return { skipped: true, reason: release.reason };
  const tag = `v${release.version}`;
  const existing = await tagCommit({ api, repo, tag });
  if (existing && existing !== sha) throw new Error(`${tag} already points to another commit; release tags are immutable`);
  if (existing) return { tag, sha, existing: true };
  try {
    await push(tag);
  } catch (error) {
    // Another attempt can win the race. A failed push is successful only if its tag is now identical.
    if (await tagCommit({ api, repo, tag }) !== sha) throw error;
    return { tag, sha, existing: true };
  }
  return { tag, sha, existing: false };
}

const RELEASE_PR_INTRODUCTION = "Merge this PR when its version and changelog are ready. Successful main CI will tag that commit and publish a GitHub Release with the changelog. Releases currently contain notes only, with no app assets.\n\nNew merges into main refresh this PR. The version and app build number are generated; submit corrections on a feature branch.\n\n";

// Replaces Changesets' npm publishing introduction while keeping its generated release notes.
export function releasePullRequestBody(body) {
  const heading = body.indexOf("# Releases\n");
  if (heading < 0) throw new Error("Changesets PR body is missing its release notes heading");
  return RELEASE_PR_INTRODUCTION + body.slice(heading);
}

export async function describeReleasePullRequest({ api, repo, number }) {
  assertRepository(repo);
  if (!/^[1-9]\d*$/.test(String(number ?? ""))) throw new Error("Release PR number must be a positive integer");
  const pr = await api.request("GET", `/repos/${repo}/pulls/${number}`);
  const body = releasePullRequestBody(pr.body ?? "");
  if (body !== pr.body) await api.request("PATCH", `/repos/${repo}/pulls/${number}`, { body: { body } });
  return { number: Number(number), updated: body !== pr.body };
}

export function githubReleaseBody(section) {
  return `${section}\n\n---\n\nThis release contains the changelog only. Signed macOS app distribution remains deferred until the recorded release checks pass.\n`;
}

export async function publishRelease({
  root = process.cwd(), repo, sha, slug, tag, api, ciApi = api,
  validateRelease = validateGeneratedRelease,
}) {
  if (typeof tag !== "string" || !tag.startsWith("v")) throw new Error("Release tag must be vX.Y.Z");
  const version = parseReleaseVersion(tag.slice(1));
  if (tag !== `v${version}`) throw new Error("Release tag must be a canonical vX.Y.Z");
  const release = await verifyRelease({ root, repo, sha, slug, api, ciApi, validateRelease });
  if (release.reason) throw new Error(`Tag does not identify a versioned release merge: ${release.reason}`);
  if (release.version !== version) throw new Error("Release tag and checked-out package version must agree");
  if (await tagCommit({ api, repo, tag }) !== sha) throw new Error("Release tag must already point to the checked-out release commit");
  const body = githubReleaseBody(extractChangelogSection(readFileAt({ root, ref: sha, path: "CHANGELOG.md" }), version));
  const name = `Spillcheck ${tag}`;
  let existing;
  try {
    existing = await api.request("GET", `/repos/${repo}/releases/tags/${tag}`);
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  if (existing) {
    if (
      existing.tag_name !== tag || existing.target_commitish !== sha || existing.name !== name ||
      existing.body !== body || existing.draft !== false || existing.prerelease !== false ||
      !Array.isArray(existing.assets) || existing.assets.length !== 0
    ) throw new Error("Existing GitHub Release differs from the expected changelog-only release; refusing to overwrite it");
    return { tag, sha, existing: true, url: existing.html_url };
  }
  // Check again immediately before mutation. Never let the releases API create an implicit tag.
  if (await tagCommit({ api, repo, tag }) !== sha) throw new Error("Release tag changed before publication");
  const created = await api.request("POST", `/repos/${repo}/releases`, {
    body: { tag_name: tag, target_commitish: sha, name, body, draft: false, prerelease: false, generate_release_notes: false },
  });
  return { tag, sha, existing: false, url: created.html_url };
}

runAsScript(import.meta.url, async () => {
  const command = process.argv[2];
  if (!["describe-release-pr", "tag", "publish"].includes(command)) {
    throw new Error("Usage: node scripts/github-release.mjs describe-release-pr|tag|publish");
  }
  const api = githubClient(process.env.GH_TOKEN);
  if (command === "describe-release-pr") {
    const result = await describeReleasePullRequest({ api, repo: process.env.GITHUB_REPOSITORY, number: process.env.RELEASE_PR_NUMBER });
    console.log(`${result.updated ? "Described" : "Already described"} release PR #${result.number}`);
    return;
  }
  const ciApi = process.env.CI_READ_TOKEN ? githubClient(process.env.CI_READ_TOKEN) : api;
  const context = {
    repo: process.env.GITHUB_REPOSITORY,
    sha: process.env.GITHUB_SHA,
    slug: process.env.CHANGESETS_APP_SLUG,
    api, ciApi,
  };
  const result = command === "tag"
    ? await tagRelease({ ...context, runId: process.env.GITHUB_RUN_ID })
    : await publishRelease({ ...context, tag: process.env.GITHUB_REF_NAME });
  console.log(result.skipped ? `No release tag needed: ${result.reason}` : `${result.existing ? "Verified existing" : "Created"} ${result.tag}${result.url ? `: ${result.url}` : ""}`);
});
