import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import semver from "semver";

export function git(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trimEnd();
}

export function readFileAt({ root = process.cwd(), ref, path }) {
  return ref ? execFileSync("git", ["show", `${ref}:${path}`], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) : readFileSync(resolve(root, path), "utf8");
}

export function parseReleaseVersion(version) {
  if (typeof version !== "string" || !/^\d+\.\d+\.\d+$/.test(version) || semver.valid(version) !== version) {
    throw new Error(`Expected a canonical release version, received ${JSON.stringify(version)}`);
  }
  return version;
}

function plistString(contents, key) {
  const pattern = new RegExp(`<key>\\s*${key}\\s*</key>\\s*<string>([^<]*)</string>`, "g");
  const matches = [...contents.matchAll(pattern)];
  if (matches.length !== 1) throw new Error(`Info.plist must contain exactly one ${key} string`);
  return matches[0][1];
}

export function readAppMetadata(options = {}) {
  const plist = readFileAt({ ...options, path: "Spillcheck/Info.plist" });
  const version = parseReleaseVersion(plistString(plist, "CFBundleShortVersionString"));
  const buildString = plistString(plist, "CFBundleVersion");
  if (!/^[1-9]\d*$/.test(buildString) || !Number.isSafeInteger(Number(buildString))) {
    throw new Error("CFBundleVersion must be a positive safe integer");
  }
  return { version, build: Number(buildString) };
}

export function extractChangelogSection(contents, version) {
  parseReleaseVersion(version);
  const headings = [...contents.matchAll(/^## ([^\r\n]+)\r?$/gm)];
  const matching = headings.filter((heading) => heading[1] === version);
  if (matching.length !== 1) throw new Error(`CHANGELOG.md must contain exactly one section for ${version}`);
  const index = headings.indexOf(matching[0]);
  const start = matching[0].index + matching[0][0].length;
  const end = headings[index + 1]?.index ?? contents.length;
  const section = contents.slice(start, end).trim();
  if (!section) throw new Error(`CHANGELOG.md section ${version} is empty`);
  return section;
}

export function validateMetadata(options = {}) {
  const manifest = JSON.parse(readFileAt({ ...options, path: "package.json" }));
  const lock = JSON.parse(readFileAt({ ...options, path: "package-lock.json" }));
  const metadata = readAppMetadata(options);
  const version = parseReleaseVersion(manifest.version);
  if (manifest.name !== "spillcheck" || manifest.private !== true) {
    throw new Error("The root release package must be private and named spillcheck");
  }
  if (lock.name !== manifest.name || lock.packages?.[""]?.name !== manifest.name || lock.version !== version || lock.packages[""].version !== version || metadata.version !== version) {
    throw new Error("The package, lockfile root, and Info.plist versions must agree");
  }
  if (options.requireChangelog) {
    extractChangelogSection(readFileAt({ ...options, path: "CHANGELOG.md" }), version);
  }
  return metadata;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const metadata = validateMetadata();
    console.log(`Release metadata agrees: ${metadata.version}, build ${metadata.build}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
