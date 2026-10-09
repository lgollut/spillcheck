// Disposable Git repositories and app metadata shared by the release tooling tests.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { git } from "../../scripts/release-metadata.mjs";

export const project = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export function gitRepository(t, prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  git(root, ["init", "--quiet", "--initial-branch=main"]);
  git(root, ["config", "user.name", "Release tests"]);
  git(root, ["config", "user.email", "release-tests@example.invalid"]);
  return root;
}

export function writeFile(root, path, contents) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), contents);
}

export function infoPlist(version, build) {
  return `<plist><dict><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>${build}</string></dict></plist>\n`;
}
