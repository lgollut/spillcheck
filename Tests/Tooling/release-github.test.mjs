import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { versionRelease } from "../../scripts/version-release.mjs";
import {
  GitHubApiError,
  assertRequiredChecks,
  githubClient,
  githubReleaseBody,
  publishRelease,
  tagCommit,
  tagRelease,
} from "../../scripts/github-release.mjs";

const repo = "owner/spillcheck";
const slug = "spillcheck-release";
const otherSha = "a".repeat(40);
const project = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function runGit(root, ...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function repository(t, { bootstrap = false, version = "0.2.0" } = {}) {
  const root = mkdtempSync(join(tmpdir(), "spillcheck-github-release-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  runGit(root, "init", "-q", "--initial-branch=main");
  runGit(root, "config", "user.name", "Release fixture");
  runGit(root, "config", "user.email", "release@example.invalid");
  mkdirSync(join(root, "Spillcheck"));
  const writeMetadata = (value, build) => {
    writeFileSync(join(root, "package.json"), JSON.stringify({ name: "spillcheck", version: value, private: true }));
    writeFileSync(join(root, "package-lock.json"), JSON.stringify({
      name: "spillcheck", version: value, lockfileVersion: 3,
      packages: { "": { name: "spillcheck", version: value } },
    }));
    writeFileSync(join(root, "Spillcheck/Info.plist"), `<plist><dict><key>CFBundleShortVersionString</key><string>${value}</string><key>CFBundleVersion</key><string>${build}</string></dict></plist>`);
  };
  const commit = (message) => {
    runGit(root, "add", ".");
    runGit(root, "commit", "-qm", message);
    const sha = runGit(root, "rev-parse", "HEAD");
    runGit(root, "update-ref", "refs/remotes/origin/main", sha);
    return sha;
  };
  if (bootstrap) {
    writeFileSync(join(root, "README.md"), "Before Changesets\n");
    commit("Initial app");
    writeMetadata("0.1.0", 1);
  } else {
    writeMetadata("0.1.0", 1);
    commit("Release baseline");
    writeMetadata(version, version === "0.1.0" ? 1 : 2);
  }
  writeFileSync(join(root, "CHANGELOG.md"), `# spillcheck\n\n## ${bootstrap ? "0.1.0" : version}\n\n### Minor Changes\n\n- Add a release fixture feature.\n\n## 0.0.1\n\n- Older release.\n`);
  const sha = commit(bootstrap ? "Install release tooling" : "Merge generated release PR");
  return { root, sha, commit, writeMetadata };
}

function github(sha, options = {}) {
  const state = {
    calls: [], pushes: [], posts: [], tag: options.tag,
    release: options.release,
    pr: {
      number: 12, state: "closed", merged: true, merged_at: "2026-10-09T12:00:00Z", merge_commit_sha: sha,
      user: { login: `${slug}[bot]`, type: "Bot" },
      head: { ref: "changeset-release/main", repo: { full_name: repo } },
      base: { ref: "main", repo: { full_name: repo } },
      ...options.pr,
    },
    run: {
      id: 42, head_sha: sha, event: "push", head_branch: "main", status: "in_progress", conclusion: null,
      head_repository: { full_name: repo }, ...options.run,
    },
    jobs: options.jobs ?? [{ name: "Required checks", status: "completed", conclusion: "success" }],
  };
  const api = {
    async request(method, path, { query = {}, body } = {}) {
      state.calls.push({ method, path, query, body });
      if (method === "GET" && path === `/repos/${repo}/commits/${sha}/pulls`) return [{ number: 12 }];
      if (method === "GET" && path === `/repos/${repo}/pulls/12`) return state.pr;
      if (method === "GET" && path === `/repos/${repo}/actions/workflows/ci.yml/runs`) return { workflow_runs: [state.run] };
      if (method === "GET" && path === `/repos/${repo}/actions/runs/${state.run.id}/jobs`) return { jobs: state.jobs };
      if (method === "GET" && path.startsWith(`/repos/${repo}/git/ref/tags/`)) {
        if (!state.tag) throw new GitHubApiError(404, "Tag missing");
        return { object: { type: "commit", sha: state.tag } };
      }
      if (method === "GET" && path.startsWith(`/repos/${repo}/releases/tags/`)) {
        if (!state.release) throw new GitHubApiError(404, "Release missing");
        return state.release;
      }
      if (method === "POST" && path === `/repos/${repo}/releases`) {
        state.posts.push(body);
        state.release = { ...body, assets: [], html_url: "https://github.com/owner/spillcheck/releases/tag/v0.2.0" };
        return state.release;
      }
      throw new Error(`Unexpected GitHub request: ${method} ${path}`);
    },
  };
  return { state, api, async push(tag) { state.pushes.push(tag); state.tag = sha; } };
}

function context(fixture, mock, overrides = {}) {
  // Generated-content recomputation has its own integration suite. Keep the GitHub tests focused
  // on provenance and writes while still reading actual commit metadata from scratch repositories.
  return { ...fixture, repo, slug, api: mock.api, push: mock.push, validateRelease: async () => {}, ...overrides };
}

test("ordinary main merges with no version change never create a tag", async (t) => {
  const fixture = repository(t, { version: "0.1.0" });
  const mock = github(fixture.sha);
  assert.deepEqual(await tagRelease(context(fixture, mock)), { skipped: true, reason: "version unchanged" });
  assert.deepEqual(mock.state.calls, []);
  assert.deepEqual(mock.state.pushes, []);
});

test("adding the initial tooling manifest does not release 0.1.0", async (t) => {
  const fixture = repository(t, { bootstrap: true });
  const mock = github(fixture.sha);
  assert.deepEqual(await tagRelease(context(fixture, mock)), { skipped: true, reason: "initial release tooling" });
  assert.deepEqual(mock.state.calls, []);
  assert.deepEqual(mock.state.pushes, []);
});

test("a trusted release merge tags its exact SHA after its gate succeeds while its workflow runs", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  const result = await tagRelease(context(fixture, mock, { runId: "42" }));
  assert.deepEqual(result, { tag: "v0.2.0", sha: fixture.sha, existing: false });
  assert.deepEqual(mock.state.pushes, ["v0.2.0"]);
  assert.equal(mock.state.run.status, "in_progress");
  assert.equal(mock.state.calls.find((call) => call.path.endsWith("/ci.yml/runs")).query.head_sha, fixture.sha);
});

test("a real Changesets-generated merge passes default recomputation, tagging, and publication", async (t) => {
  const fixture = repository(t, { version: "0.1.0" });
  mkdirSync(join(fixture.root, ".changeset"));
  for (const path of ["package.json", "package-lock.json"]) {
    const metadata = JSON.parse(readFileSync(join(project, path), "utf8"));
    metadata.version = "0.1.0";
    if (path === "package-lock.json") metadata.packages[""].version = "0.1.0";
    writeFileSync(join(fixture.root, path), `${JSON.stringify(metadata, null, 2)}\n`);
  }
  writeFileSync(join(fixture.root, ".changeset/config.json"), readFileSync(join(project, ".changeset/config.json"), "utf8"));
  writeFileSync(join(fixture.root, "CHANGELOG.md"), "# spillcheck\n");
  writeFileSync(join(fixture.root, ".changeset/feature.md"), '---\n"spillcheck": minor\n---\n\nAdd a real Changesets release feature.\n');
  writeFileSync(join(fixture.root, ".changeset/docs.md"), "---\n{}\n---\n\nDocument the release flow; no app version bump is needed.\n");
  fixture.commit("Accumulate release notes on main");
  runGit(fixture.root, "checkout", "-qb", "changeset-release/main");
  assert.equal(versionRelease({ root: fixture.root }).version, "0.2.0");
  fixture.commit("Version Packages");
  runGit(fixture.root, "checkout", "-q", "main");
  runGit(fixture.root, "merge", "--no-ff", "-qm", "Merge generated release PR", "changeset-release/main");
  const sha = runGit(fixture.root, "rev-parse", "HEAD");
  runGit(fixture.root, "update-ref", "refs/remotes/origin/main", sha);
  const mock = github(sha);
  const releaseContext = context({ ...fixture, sha }, mock, { validateRelease: undefined });
  assert.equal((await tagRelease(releaseContext)).tag, "v0.2.0");
  assert.equal((await publishRelease({ ...releaseContext, tag: "v0.2.0" })).existing, false);
  assert.match(mock.state.posts[0].body, /real Changesets release feature/);
  assert.equal(mock.state.posts.length, 1);
});

test("a newer feature on main does not prevent tagging the tested release commit", async (t) => {
  const fixture = repository(t);
  mkdirSync(join(fixture.root, ".changeset"));
  writeFileSync(join(fixture.root, ".changeset/new-feature.md"), '---\n"spillcheck": patch\n---\n\nAnother new feature.\n');
  fixture.commit("Feature lands before release tagging");
  runGit(fixture.root, "checkout", "-q", fixture.sha);
  const mock = github(fixture.sha);
  const result = await tagRelease(context(fixture, mock));
  assert.equal(result.sha, fixture.sha);
  assert.deepEqual(mock.state.pushes, ["v0.2.0"]);
});

test("tagging uses a non-forcing push of the exact commit to the release ref", async (t) => {
  const fixture = repository(t);
  const remote = join(fixture.root, "remote.git");
  runGit(fixture.root, "init", "-q", "--bare", remote);
  runGit(fixture.root, "remote", "add", "origin", remote);
  const mock = github(fixture.sha);
  await tagRelease(context(fixture, mock, { push: undefined }));
  assert.equal(runGit(fixture.root, "ls-remote", "origin", "refs/tags/v0.2.0").split(/\s/)[0], fixture.sha);
});

test("a tag retry accepts an identical tag and refuses an existing different commit", async (t) => {
  const fixture = repository(t);
  const same = github(fixture.sha, { tag: fixture.sha });
  assert.equal((await tagRelease(context(fixture, same))).existing, true);
  assert.deepEqual(same.state.pushes, []);
  const wrong = github(fixture.sha, { tag: otherSha });
  await assert.rejects(tagRelease(context(fixture, wrong)), /immutable/);
  assert.deepEqual(wrong.state.pushes, []);
});

test("a concurrent tag creation can win without failing a retry or moving the tag", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  const result = await tagRelease(context(fixture, mock, { push: async () => {
    mock.state.tag = fixture.sha;
    throw new Error("Remote tag was already created");
  } }));
  assert.equal(result.existing, true);
});

test("a failed push is not hidden when no matching tag exists", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  await assert.rejects(tagRelease(context(fixture, mock, { push: async () => {
    throw new Error("Network push failure");
  } })), /Network push failure/);
});

for (const [name, pr] of [
  ["human author", { user: { login: "maintainer", type: "User" } }],
  ["spoofed branch", { head: { ref: "feature/release", repo: { full_name: repo } } }],
  ["fork source", { head: { ref: "changeset-release/main", repo: { full_name: "attacker/spillcheck" } } }],
  ["wrong base", { base: { ref: "develop", repo: { full_name: repo } } }],
  ["unmerged PR", { merged: false, merged_at: null }],
  ["different merge SHA", { merge_commit_sha: otherSha }],
]) {
  test(`release provenance rejects ${name} before a write`, async (t) => {
    const fixture = repository(t);
    const mock = github(fixture.sha, { pr });
    await assert.rejects(tagRelease(context(fixture, mock)), /trusted Changesets release PR/);
    assert.deepEqual(mock.state.pushes, []);
    assert.deepEqual(mock.state.posts, []);
  });
}

for (const [name, options] of [
  ["failed gate", { jobs: [{ name: "Required checks", status: "completed", conclusion: "failure" }] }],
  ["unfinished gate", { jobs: [{ name: "Required checks", status: "in_progress", conclusion: null }] }],
  ["wrong gate name", { jobs: [{ name: "Core tests", status: "completed", conclusion: "success" }] }],
  ["PR workflow run", { run: { event: "pull_request" } }],
  ["wrong branch", { run: { head_branch: "feature" } }],
  ["wrong tested commit", { run: { head_sha: otherSha } }],
  ["foreign repository", { run: { head_repository: { full_name: "attacker/spillcheck" } } }],
]) {
  test(`CI provenance rejects ${name} before a write`, async (t) => {
    const fixture = repository(t);
    const mock = github(fixture.sha, options);
    await assert.rejects(tagRelease(context(fixture, mock)), /successful Required checks/);
    assert.deepEqual(mock.state.pushes, []);
  });
}

test("tagging requires the current originating CI run when its run ID is supplied", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  await assert.rejects(tagRelease(context(fixture, mock, { runId: "43" })), /successful Required checks/);
  assert.deepEqual(mock.state.pushes, []);
});

test("tag provenance can use a separate read token from the App write token", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  const ciMock = github(fixture.sha);
  await tagRelease(context(fixture, mock, { ciApi: ciMock.api }));
  assert.equal(mock.state.calls.some((call) => call.path.includes("/actions/")), false);
  assert.equal(ciMock.state.calls.every((call) => call.path.includes("/actions/")), true);
});

test("CI provenance reads a later page rather than assuming the first 100 runs suffice", async () => {
  const sha = "b".repeat(40);
  const pages = [];
  const api = { async request(method, path, { query }) {
    if (path.endsWith("/runs")) {
      pages.push(query.page);
      return { workflow_runs: query.page === 1
        ? Array.from({ length: 100 }, (_, id) => ({ id, head_sha: otherSha }))
        : [{ id: 105, head_sha: sha, event: "push", head_branch: "main", head_repository: { full_name: repo } }] };
    }
    return { jobs: [{ name: "Required checks", status: "completed", conclusion: "success" }] };
  } };
  assert.equal(await assertRequiredChecks({ api, repo, sha }), 105);
  assert.deepEqual(pages, [1, 2]);
});

test("publication produces only the requested version's changelog and an explicit distribution status", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha, { tag: fixture.sha });
  const result = await publishRelease(context(fixture, mock, { tag: "v0.2.0" }));
  assert.equal(result.existing, false);
  assert.equal(mock.state.posts.length, 1);
  const payload = mock.state.posts[0];
  assert.equal(payload.tag_name, "v0.2.0");
  assert.equal(payload.target_commitish, fixture.sha);
  assert.equal(payload.name, "Spillcheck v0.2.0");
  assert.equal(payload.generate_release_notes, false);
  assert.match(payload.body, /Add a release fixture feature/);
  assert.match(payload.body, /changelog only/);
  assert.doesNotMatch(payload.body, /Older release/);
  assert.deepEqual(mock.state.release.assets, []);
});

test("publication retries reuse a consistent GitHub Release without duplicating it", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha, { tag: fixture.sha });
  const first = await publishRelease(context(fixture, mock, { tag: "v0.2.0" }));
  const second = await publishRelease(context(fixture, mock, { tag: "v0.2.0" }));
  assert.equal(first.existing, false);
  assert.equal(second.existing, true);
  assert.equal(first.url, second.url);
  assert.equal(mock.state.posts.length, 1);
});

test("an existing GitHub Release with altered notes or assets is not overwritten", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha, { tag: fixture.sha });
  await publishRelease(context(fixture, mock, { tag: "v0.2.0" }));
  mock.state.release.body = "Wrong release notes";
  await assert.rejects(publishRelease(context(fixture, mock, { tag: "v0.2.0" })), /refusing to overwrite/);
  mock.state.release.body = mock.state.posts[0].body;
  mock.state.release.assets = [{ name: "unverified-app.zip" }];
  await assert.rejects(publishRelease(context(fixture, mock, { tag: "v0.2.0" })), /refusing to overwrite/);
  assert.equal(mock.state.posts.length, 1);
});

for (const tag of ["0.2.0", "v0.2.0-beta.1", "v0.2.0+build", "v00.2.0", "v0.2", "vnext", "v0.2.1"]) {
  test(`publication rejects unsupported or mismatching tag ${tag}`, async (t) => {
    const fixture = repository(t);
    const mock = github(fixture.sha, { tag: fixture.sha });
    await assert.rejects(publishRelease(context(fixture, mock, { tag })));
    assert.deepEqual(mock.state.posts, []);
  });
}

test("publication requires the existing tag to target the tested release commit", async (t) => {
  const fixture = repository(t);
  for (const tag of [undefined, otherSha]) {
    const mock = github(fixture.sha, { tag });
    await assert.rejects(publishRelease(context(fixture, mock, { tag: "v0.2.0" })), /already point/);
    assert.deepEqual(mock.state.posts, []);
  }
});

test("publication never creates an implicit tag after a tag changes during validation", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha, { tag: fixture.sha });
  const request = mock.api.request;
  mock.api.request = async (method, path, args) => {
    const result = await request(method, path, args);
    if (path.includes("/git/ref/tags/")) mock.state.tag = otherSha;
    return result;
  };
  await assert.rejects(publishRelease(context(fixture, mock, { tag: "v0.2.0" })), /changed before publication/);
  assert.deepEqual(mock.state.posts, []);
});

test("a versioned commit outside main or a different checkout is not eligible", async (t) => {
  const fixture = repository(t);
  const mock = github(fixture.sha);
  const previous = runGit(fixture.root, "rev-parse", "HEAD^");
  runGit(fixture.root, "update-ref", "refs/remotes/origin/main", previous);
  await assert.rejects(tagRelease(context(fixture, mock)), /must be on origin\/main/);
  runGit(fixture.root, "checkout", "-q", previous);
  await assert.rejects(tagRelease(context(fixture, mock)), /exact tested commit/);
  assert.deepEqual(mock.state.pushes, []);
});

test("metadata inconsistency and generated-content failures block writes", async (t) => {
  const fixture = repository(t);
  fixture.writeMetadata("0.2.1", 2);
  const plist = readFileSync(join(fixture.root, "Spillcheck/Info.plist"), "utf8").replace("0.2.1", "0.2.0");
  writeFileSync(join(fixture.root, "Spillcheck/Info.plist"), plist);
  const sha = fixture.commit("Inconsistent release metadata");
  const mock = github(sha);
  await assert.rejects(tagRelease(context({ ...fixture, sha }, mock)), /must agree/);
  const valid = repository(t);
  const validMock = github(valid.sha);
  await assert.rejects(tagRelease(context(valid, validMock, { validateRelease: async () => {
    throw new Error("Generated release differs from Changesets");
  } })), /differs from Changesets/);
  assert.deepEqual(mock.state.pushes, []);
  assert.deepEqual(validMock.state.pushes, []);
});

test("annotated tags are resolved to their commit rather than compared as tag object SHAs", async () => {
  const sha = "b".repeat(40);
  const api = { async request(method, path) {
    return path.includes("/git/ref/") ? { object: { type: "tag", sha: otherSha } } : { object: { type: "commit", sha } };
  } };
  assert.equal(await tagCommit({ api, repo, tag: "v0.2.0" }), sha);
});

test("the HTTP client sends structured payloads and does not expose tokens in errors", async () => {
  let request;
  const token = "private-token-fixture";
  const api = githubClient(token, { fetchImpl: async (url, options) => {
    request = { url, options };
    return { ok: true, status: 201, json: async () => ({ id: 1 }) };
  } });
  await api.request("POST", "/repos/owner/spillcheck/releases", { body: { body: "A line\nA second line" } });
  assert.equal(request.options.headers.Authorization, `Bearer ${token}`);
  assert.deepEqual(JSON.parse(request.options.body), { body: "A line\nA second line" });
  const failed = githubClient(token, { fetchImpl: async () => ({ ok: false, status: 403 }) });
  await assert.rejects(failed.request("GET", "/repos/owner/spillcheck/releases"), (error) => {
    assert.equal(error.status, 403);
    assert.equal(error.message.includes(token), false);
    return true;
  });
});

test("release body describes the initial changelog-only scope", () => {
  assert.equal(githubReleaseBody("- A feature."), "- A feature.\n\n---\n\nThis release contains the changelog only. Signed macOS app distribution remains deferred until the recorded release checks pass.\n");
});
