#!/usr/bin/env python3
"""Inspect or stage a personal-team Release bundle; upload only with explicit --notarize.

Examples:
  scripts/build-app.sh --configuration Release --signing-identity '<exact identity>' --team-id KBLA5ALX62
  python3 scripts/package-release.py inspect --app .build/release-app/Build/Products/Release/Spillcheck.app --team-id KBLA5ALX62
  python3 scripts/package-release.py package --app <Release.app> --identity '<exact identity>' --team-id KBLA5ALX62 --output <archive.zip> --dry-run

All package mutations affect a staged copy. The original build is never re-signed or stapled.
Credentials stay in a user-provided notarytool Keychain profile. This script never stores them.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

from release_policy import (
    ACCESS_GROUP, BUNDLE_ID, GRDB_LICENSE_SHA256, BETTERLEAKS_BINARY_SHA256,
    BETTERLEAKS_RULES_SHA256, BETTERLEAKS_LICENSE_SHA256, ReleaseError, require,
    validate_team, validate_identity_request, select_explicit_identity, validate_build,
    validate_entitlements, validate_signature, validate_profile, validate_minimum_os,
)

MACH_MAGICS = {bytes.fromhex(value) for value in
              ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}


def run(arguments, *, timeout=60, require_success=True):
    try:
        result = subprocess.run(arguments, check=False, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError("Release tool unavailable or timed out: " + Path(arguments[0]).name) from error
    require(not require_success or result.returncode == 0, "Release tool failed: " + Path(arguments[0]).name)
    return result


def identity_fingerprint(identity, team):
    validate_identity_request(identity, team)
    output = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).stdout.decode("utf-8", errors="replace")
    return select_explicit_identity(identity, team, output)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def bundle_digest(app):
    """Bind files, executable modes and links, without mutating the source bundle."""
    value = hashlib.sha256()
    for path in sorted(app.rglob("*"), key=str):
        relative = str(path.relative_to(app))
        if path.is_symlink():
            record = [relative, "link", os.readlink(path)]
        elif path.is_file():
            record = [relative, "file", path.stat().st_mode & 0o777, digest(path)]
        elif path.is_dir():
            record = [relative, "directory", path.stat().st_mode & 0o777]
        else:
            raise ReleaseError("Release bundle contains a special filesystem object.")
        value.update(json.dumps(record, ensure_ascii=True, separators=(",", ":")).encode())
        value.update(b"\n")
    return value.hexdigest()


def bounded_file(path, maximum):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum,
            "Release resource is absent, linked, or oversized: " + path.name)
    return path.read_bytes()


def structure(app):
    require(app.is_dir() and app.suffix == ".app", "Supply a Release .app bundle.")
    contents = app / "Contents"
    info = plistlib.loads(bounded_file(contents / "Info.plist", 128 * 1024))
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected application bundle identifier.")
    require(info.get("CFBundleExecutable") == "Spillcheck", "Unexpected application executable.")
    require(info.get("LSMinimumSystemVersion") == "14.0", "Application must retain its macOS 14 baseline.")
    require(info.get("SpillcheckKeychainAccessGroup") == ACCESS_GROUP, "Application Keychain access-group setting changed.")
    require(not (contents / "MacOS/Spillcheck.debug.dylib").exists() and not (contents / "MacOS/__preview.dylib").exists(),
            "Debug/preview dynamic libraries cannot enter a release archive.")
    manifest_path = contents / "Resources/Scanner/dependencies.json"
    manifest = json.loads(bounded_file(manifest_path, 16 * 1024))
    validate_build(manifest)
    require(manifest.get("schemaVersion") == 1 and manifest.get("engine") == "betterleaks" and
            manifest.get("version") == "1.9.0" and manifest.get("regexEngine") == "stdlib",
            "Scanner manifest does not describe the pinned stdlib engine.")
    expected = {"betterleaks": BETTERLEAKS_BINARY_SHA256, "betterleaks.toml": BETTERLEAKS_RULES_SHA256,
                "LICENSE": BETTERLEAKS_LICENSE_SHA256}
    require(manifest.get("verifiedBeforeSigning") == expected, "Scanner pre-signing provenance changed.")
    require(digest(contents / "Resources/Scanner/betterleaks.toml") == BETTERLEAKS_RULES_SHA256,
            "Bundled scanner rules changed.")
    require(digest(contents / "Resources/Scanner/LICENSE") == BETTERLEAKS_LICENSE_SHA256,
            "Bundled scanner license changed.")
    require(digest(contents / "Resources/ThirdPartyLicenses/GRDB-7.11.1.txt") == GRDB_LICENSE_SHA256,
            "The pinned GRDB copyright/license notice is absent or changed.")
    scanner = contents / "Helpers/betterleaks"
    require(manifest.get("bundledExecutableSHA256") == digest(scanner), "Scanner's sealed signed hash is stale.")
    expected_executables = {contents / "MacOS/Spillcheck", contents / "Helpers/spillcheck-hook", scanner}
    discovered = set()
    for path in contents.rglob("*"):
        if path.is_symlink():
            require(path.resolve().is_relative_to(app), "Release bundle contains an external symbolic link.")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACH_MAGICS:
                    discovered.add(path)
    require(discovered == expected_executables, "Release contains missing or unreviewed executable code.")
    for executable in expected_executables:
        require(os.access(executable, os.X_OK), "Bundled code is not executable: " + executable.name)
    return info, manifest_path, manifest, sorted(expected_executables, key=str)


def code_entitlements(path):
    result = run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)])
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def certificate_fingerprint(path):
    with tempfile.TemporaryDirectory(prefix="spillcheck-release-cert-") as directory:
        prefix = Path(directory) / "certificate-"
        run(["/usr/bin/codesign", "-d", "--extract-certificates", str(prefix), str(path)])
        certificate = bounded_file(Path(str(prefix) + "0"), 128 * 1024)
        return hashlib.sha1(certificate).hexdigest().upper()


def inspect(app, team, *, require_notarized=False, expected_fingerprint=None):
    validate_team(team)
    info, _, manifest, executables = structure(app)
    signatures = []
    app_entitlements = None
    fingerprints = set()
    for executable in executables:
        target = app if executable == app / "Contents/MacOS/Spillcheck" else executable
        run(["/usr/bin/codesign", "--verify", "--strict", str(target)])
        description = run(["/usr/bin/codesign", "-d", "--verbose=4", str(target)]).stderr.decode("utf-8", errors="replace")
        validate_signature(description, team)
        fingerprint = certificate_fingerprint(target)
        fingerprints.add(fingerprint)
        require(expected_fingerprint is None or fingerprint == expected_fingerprint,
                "Bundled code was not signed with the explicitly supplied certificate.")
        entitlements = code_entitlements(target)
        validate_entitlements(entitlements, app=target == app)
        if target == app:
            app_entitlements = entitlements
        architectures = run(["/usr/bin/xcrun", "lipo", "-archs", str(executable)]).stdout.decode().split()
        require(architectures == ["arm64"], "Bundled code contains an unvalidated architecture.")
        build_versions = run(["/usr/bin/xcrun", "vtool", "-show-build", str(executable)]).stdout.decode()
        validate_minimum_os(build_versions)
        signatures.append({"component": str(executable.relative_to(app)), "teamID": team,
                           "certificateSHA1": fingerprint, "developerID": True,
                           "secureTimestamp": True, "hardenedRuntime": True})
    require(len(fingerprints) == 1, "Every bundled executable must use the same personal signing certificate.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    profile_path = app / "Contents/embedded.provisionprofile"
    bounded_file(profile_path, 4 * 1024 * 1024)
    profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]).stdout)
    validate_profile(profile, team, next(iter(fingerprints)))
    notarized = False
    if require_notarized:
        run(["/usr/bin/xcrun", "stapler", "validate", str(app)], timeout=120)
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], timeout=120)
        notarized = True
    return {"configuration": "Release", "bundleIdentifier": BUNDLE_ID, "teamID": team,
            "accessGroup": ACCESS_GROUP, "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "architecture": "arm64", "minimumSystemVersion": "14.0",
            "signatures": signatures, "distributionProvisioningProfile": True,
            "scannerSignedSHA256": manifest["bundledExecutableSHA256"],
            "licenses": ["GRDB-7.11.1-MIT", "Betterleaks-1.9.0-MIT"], "notarized": notarized,
            "releaseAcceptance": "not-checked"}, app_entitlements


def make_zip(app, destination):
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination)], timeout=180)


def package(args):
    validate_identity_request(args.identity, args.team_id)
    source = args.app.resolve()
    output = args.output.resolve()
    report_path = output.with_suffix(".release.json")
    notary_path = output.with_suffix(".notary.json")
    require(output.suffix == ".zip", "Output must be a .zip archive.")
    require(not output.is_relative_to(source), "The output archive cannot be inside the source app.")
    require(not output.exists(), "Output already exists; choose a new artifact path.")
    require(not report_path.exists(), "Release report path already exists; choose a new artifact path.")
    require(not args.notarize or not notary_path.exists(), "Notarization evidence path already exists; choose a new artifact path.")
    require(bool(args.notary_profile) == args.notarize,
            "Notarization requires both --notarize and an explicitly supplied --notary-profile.")
    if args.dry_run:
        return {"dryRun": True, "mutations": False, "identitySelected": False, "networkUsed": False,
                "source": str(source), "output": str(output), "teamID": args.team_id,
                "steps": ["verify explicit personal identity", "inspect Release source", "stage owned copy",
                          "sign helper/scanner with secure timestamps", "refresh sealed scanner hash", "sign and verify app",
                          "notarize and staple staged app" if args.notarize else "leave notarization unverified",
                          "archive and round-trip verify exact final artifact"],
                "releaseAcceptance": "not-checked"}
    fingerprint = identity_fingerprint(args.identity, args.team_id)
    original_digest = bundle_digest(source)
    _, entitlements = inspect(source, args.team_id, expected_fingerprint=fingerprint)
    require(bundle_digest(source) == original_digest, "Source bundle changed during preflight.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="spillcheck-release-", dir=output.parent) as directory:
        work = Path(directory)
        staged = work / "Spillcheck.app"
        run(["/usr/bin/ditto", str(source), str(staged)], timeout=180)
        require(bundle_digest(staged) == original_digest and bundle_digest(source) == original_digest,
                "Source bundle changed while staging.")
        _, manifest_path, manifest, executables = structure(staged)
        # Sign each child explicitly. Re-signing recursively after writing this hash would invalidate it.
        for executable in executables:
            if executable != staged / "Contents/MacOS/Spillcheck":
                run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--options", "runtime",
                     "--timestamp", str(executable)], timeout=180)
        manifest["bundledExecutableSHA256"] = digest(staged / "Contents/Helpers/betterleaks")
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        entitlement_path = work / "release-entitlements.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True))
        run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--options", "runtime", "--timestamp",
             "--entitlements", str(entitlement_path), str(staged)], timeout=180)
        report, _ = inspect(staged, args.team_id, expected_fingerprint=fingerprint)
        submission = None
        if args.notarize:
            upload = work / "notary-upload.zip"
            make_zip(staged, upload)
            result = run(["/usr/bin/xcrun", "notarytool", "submit", str(upload), "--keychain-profile", args.notary_profile,
                          "--wait", "--output-format", "json"], timeout=3600, require_success=False)
            submission = json.loads(result.stdout)
            require(isinstance(submission.get("id"), str), "Notarization response has no submission identifier.")
            submission_id = str(uuid.UUID(submission["id"]))
            evidence = {"submissionID": submission_id, "status": submission.get("status"),
                        "toolExitCode": result.returncode, "logPending": True}
            with notary_path.open("x") as stream:
                json.dump(evidence, stream, indent=2, sort_keys=True)
                stream.write("\n")
            log_path = work / "notary-log.json"
            run(["/usr/bin/xcrun", "notarytool", "log", submission_id, "--keychain-profile", args.notary_profile,
                 str(log_path)], timeout=180)
            log = json.loads(log_path.read_text())
            evidence.update(logPending=False, log=log)
            notary_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
            require(result.returncode == 0 and submission.get("status") == "Accepted",
                    "Apple notarization was not accepted; inspect " + str(notary_path))
            require(not log.get("issues"), "Review Apple notarization warnings/issues in " + str(notary_path))
            run(["/usr/bin/xcrun", "stapler", "staple", str(staged)], timeout=180)
            report, _ = inspect(staged, args.team_id, require_notarized=True, expected_fingerprint=fingerprint)
        archive = work / "distribution.zip"
        make_zip(staged, archive)
        extracted = work / "round-trip"
        run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], timeout=180)
        round_trip, _ = inspect(extracted / "Spillcheck.app", args.team_id, require_notarized=args.notarize,
                                expected_fingerprint=fingerprint)
        require(round_trip == report and bundle_digest(extracted / "Spillcheck.app") == bundle_digest(staged),
                "The distribution archive changed its verified bundle.")
        require(bundle_digest(source) == original_digest, "Source bundle changed before archive completion.")
        report.update({"sourceUnchanged": True, "archiveRoundTripVerified": True,
                       "sourceBundleSHA256": original_digest,
                       "packagingReady": bool(args.notarize), "archiveSHA256": digest(archive),
                       "notarizationSubmissionID": submission["id"] if submission else None})
        # Source is read-only throughout; final output is created only after every requested check.
        staged_report = work / "distribution.release.json"
        with staged_report.open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.link(archive, output)
        try:
            os.link(staged_report, report_path)
        except OSError:
            output.unlink()
            raise
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="action", required=True)
    identity = commands.add_parser("identity", help="Check one explicit installed identity without choosing another.")
    identity.add_argument("--identity", required=True)
    identity.add_argument("--team-id", required=True)
    identity.add_argument("--quiet", action="store_true")
    inspection = commands.add_parser("inspect", help="Read-only signature, entitlement, profile, architecture and hash checks.")
    inspection.add_argument("--app", type=Path, required=True)
    inspection.add_argument("--team-id", required=True)
    inspection.add_argument("--require-notarized", action="store_true")
    preparation = commands.add_parser("package", help="Stage/sign/archive; notarize only when explicitly requested.")
    preparation.add_argument("--app", type=Path, required=True)
    preparation.add_argument("--identity", required=True)
    preparation.add_argument("--team-id", required=True)
    preparation.add_argument("--output", type=Path, required=True)
    preparation.add_argument("--dry-run", action="store_true")
    preparation.add_argument("--notarize", action="store_true")
    preparation.add_argument("--notary-profile")
    args = parser.parse_args()
    try:
        if args.action == "identity":
            fingerprint = identity_fingerprint(args.identity, args.team_id)
            report = {"identityVerified": True, "fingerprint": fingerprint, "teamID": args.team_id}
        elif args.action == "inspect":
            report, _ = inspect(args.app.resolve(), args.team_id, require_notarized=args.require_notarized)
        else:
            report = package(args)
        if not getattr(args, "quiet", False):
            print(json.dumps(report, sort_keys=True))
    except (ReleaseError, ValueError, OSError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(json.dumps({"passed": False, "releaseAcceptance": "not-checked", "error": str(error)}, sort_keys=True))
        raise SystemExit(2)


if __name__ == "__main__":
    main()
