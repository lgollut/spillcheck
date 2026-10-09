import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import semver from "semver";
import { validateMetadata } from "./release-metadata.mjs";

const require = createRequire(import.meta.url);
export const changesetsCli = require.resolve("@changesets/cli/bin.js");

export function versionRelease({ root = process.cwd(), cliPath = changesetsCli } = {}) {
  const before = validateMetadata({ root });
  const pending = readdirSync(resolve(root, ".changeset")).filter((name) => name.endsWith(".md") && name !== "README.md");
  if (!pending.length) return { ...before, changed: false, output: "No pending changesets" };
  const output = execFileSync(process.execPath, [cliPath, "version"], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const manifest = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
  if (manifest.version === before.version) return { ...before, changed: false, output };
  if (!semver.gt(manifest.version, before.version)) throw new Error("A release must increase the app version");
  const build = before.build + 1;
  if (!Number.isSafeInteger(build)) throw new Error("App build number is exhausted");
  const lockPath = resolve(root, "package-lock.json");
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  lock.version = manifest.version;
  lock.packages[""].version = manifest.version;
  writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  const plistPath = resolve(root, "Spillcheck/Info.plist");
  const plist = readFileSync(plistPath, "utf8")
    .replace(/(<key>\s*CFBundleShortVersionString\s*<\/key>\s*<string>)[^<]*(<\/string>)/, (_, prefix, suffix) => `${prefix}${manifest.version}${suffix}`)
    .replace(/(<key>\s*CFBundleVersion\s*<\/key>\s*<string>)[^<]*(<\/string>)/, (_, prefix, suffix) => `${prefix}${build}${suffix}`);
  writeFileSync(plistPath, plist);
  return { ...validateMetadata({ root, requireChangelog: true }), changed: true, output };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const result = versionRelease();
    console.log(result.output.trim());
    console.log(`App version ${result.version}, build ${result.build}${result.changed ? "" : " (unchanged)"}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
