#!/usr/bin/env python3
"""Exercise release rejection and staging contracts with synthetic code and fake tools.

No signing identity, provider, Keychain item, app process or network operation is used.
These fixtures do not establish genuine Developer ID, notarization or installation.
"""
import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release_policy as policy

spec = importlib.util.spec_from_file_location("spillcheck_package_release", ROOT / "scripts/package-release.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
CERTIFICATE = b"synthetic personal distribution certificate"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
IDENTITY = "Developer ID Application: Synthetic Spillcheck Owner (" + policy.TEAM_ID + ")"
NOW = datetime.datetime(2026, 10, 8, tzinfo=datetime.timezone.utc)


def build_metadata():
    return {"applicationBuild": {"configuration": "Release", "swiftCompilationConditions": [], "otherSwiftFlags": [],
                                "architectures": ["arm64"], "minimumSystemVersion": "14.0"}}


def app_entitlements():
    return {"com.apple.application-identifier": policy.ACCESS_GROUP,
            "keychain-access-groups": [policy.ACCESS_GROUP]}


def distribution_profile():
    return {"TeamIdentifier": [policy.TEAM_ID], "DeveloperCertificates": [CERTIFICATE],
            "Platform": ["OSX"], "ProvisionsAllDevices": True,
            "ExpirationDate": NOW + datetime.timedelta(days=90),
            "Entitlements": {"com.apple.application-identifier": policy.ACCESS_GROUP,
                             "keychain-access-groups": [policy.TEAM_ID + ".*"]}}


class ReleasePolicyContracts(unittest.TestCase):
    def reject(self, function, *args, **kwargs):
        with self.assertRaises(policy.ReleaseError):
            function(*args, **kwargs)

    def test_identity_is_explicit_personal_and_unambiguous(self):
        installed = '  1) ' + FINGERPRINT + ' "' + IDENTITY + '"\n'
        self.assertEqual(policy.select_explicit_identity(IDENTITY, policy.TEAM_ID, installed), FINGERPRINT)
        self.assertEqual(policy.select_explicit_identity(FINGERPRINT.lower(), policy.TEAM_ID, installed), FINGERPRINT)
        for identity, team in [("Developer ID Application", policy.TEAM_ID),
                               ("Apple Development: Synthetic (" + policy.TEAM_ID + ")", policy.TEAM_ID),
                               ("Developer ID Application: Example Organization (ABCDE12345)", policy.TEAM_ID),
                               (FINGERPRINT, "ABCDE12345")]:
            with self.subTest(identity=identity, team=team):
                self.reject(policy.select_explicit_identity, identity, team, installed)
        corporate = '  1) ' + FINGERPRINT + ' "Developer ID Application: Example Organization (ABCDE12345)"\n'
        self.reject(policy.select_explicit_identity, FINGERPRINT, policy.TEAM_ID, corporate)
        self.reject(policy.select_explicit_identity, IDENTITY, policy.TEAM_ID, installed + installed.replace("1)", "2)"))
        self.reject(policy.select_explicit_identity, "F" * 40, policy.TEAM_ID, installed)

    def test_debug_metadata_and_unvalidated_architecture_are_rejected(self):
        policy.validate_build(build_metadata())
        for key, value in [("configuration", "Debug"), ("swiftCompilationConditions", ["DEBUG"]),
                           ("swiftCompilationConditions", ""), ("architectures", ["arm64", "x86_64"]),
                           ("otherSwiftFlags", ["-DDEBUG"]), ("otherSwiftFlags", ["-D", "DEBUG"]),
                           ("minimumSystemVersion", "15.0")]:
            with self.subTest(key=key, value=value):
                manifest = build_metadata()
                manifest["applicationBuild"][key] = value
                self.reject(policy.validate_build, manifest)
        self.reject(policy.validate_build, {})

    def test_entitlement_group_and_runtime_exceptions_fail_closed(self):
        policy.validate_entitlements(app_entitlements(), app=True)
        policy.validate_entitlements({}, app=False)
        for key in policy.RUNTIME_EXCEPTIONS:
            with self.subTest(key=key):
                invalid = app_entitlements()
                invalid[key] = True
                self.reject(policy.validate_entitlements, invalid, app=True)
        for changes in [{"keychain-access-groups": [policy.ACCESS_GROUP, "other.group"]},
                        {"com.apple.application-identifier": "ABCDE12345.com.leakret.app"},
                        {"com.apple.developer.team-identifier": "ABCDE12345"},
                        {"com.apple.security.network.client": True}]:
            self.reject(policy.validate_entitlements, dict(app_entitlements(), **changes), app=True)
        self.reject(policy.validate_entitlements, app_entitlements(), app=False)

    def test_signatures_require_distribution_timestamp_and_runtime(self):
        description = ("Authority=" + IDENTITY + "\nAuthority=Developer ID Certification Authority\n"
                       "Authority=Apple Root CA\nTeamIdentifier=" + policy.TEAM_ID + "\n"
                       "Timestamp=Oct 8, 2026 at 08:00:00\nCodeDirectory flags=0x10000(runtime)\n")
        policy.validate_signature(description, policy.TEAM_ID)
        for invalid in [description.replace(IDENTITY, "Apple Development: Synthetic (" + policy.TEAM_ID + ")"),
                        description.replace("Timestamp=", "Signed Time="),
                        description.replace("Oct 8, 2026 at 08:00:00", "none"),
                        description.replace("0x10000(runtime)", "0x0(none)"),
                        description.replace(policy.TEAM_ID, "ABCDE12345")]:
            self.reject(policy.validate_signature, invalid, policy.TEAM_ID)

    def test_profile_authorizes_certificate_group_and_distribution(self):
        valid = distribution_profile()
        policy.validate_profile(valid, policy.TEAM_ID, FINGERPRINT, NOW)
        for key, value in [("ProvisionedDevices", ["synthetic-device"]), ("DeveloperCertificates", [b"different cert"]),
                           ("TeamIdentifier", ["ABCDE12345"]), ("Platform", ["iOS"]),
                           ("ExpirationDate", NOW - datetime.timedelta(seconds=1))]:
            with self.subTest(key=key):
                self.reject(policy.validate_profile, dict(valid, **{key: value}), policy.TEAM_ID, FINGERPRINT, NOW)
        for key, value in [("get-task-allow", True), ("com.apple.security.get-task-allow", True),
                           ("com.apple.application-identifier", "other.app"),
                           ("keychain-access-groups", ["*"]), ("keychain-access-groups", ["ABCDE12345.*"])]:
            invalid = copy.deepcopy(valid)
            invalid["Entitlements"][key] = value
            self.reject(policy.validate_profile, invalid, policy.TEAM_ID, FINGERPRINT, NOW)

    def test_mach_o_minimum_os_is_checked(self):
        for valid in ["cmd LC_BUILD_VERSION\n platform MACOS\n minos 14.0\n sdk 26.0\n",
                      "cmd LC_BUILD_VERSION\n platform MACOS\n minos 11.0.0\n sdk 26.0\n",
                      "cmd LC_VERSION_MIN_MACOSX\n version 10.13\n sdk 14.0\n"]:
            policy.validate_minimum_os(valid)
        for invalid in ["platform MACOS\nminos 14.1\n", "platform IOS\nminos 14.0\n",
                        "platform MACOS\n", "platform MACOS\nminos 14.0\nminos 15.0\n"]:
            self.reject(policy.validate_minimum_os, invalid)

    def test_pinned_grdb_notice_is_bundled(self):
        notice = ROOT / "Spillcheck/Resources/ThirdPartyLicenses/GRDB-7.11.1.txt"
        self.assertEqual(packager.digest(notice), policy.GRDB_LICENSE_SHA256)
        self.assertIn("Copyright (C) 2015-2025 Gwendal Roué", notice.read_text())

    def test_build_wrapper_rejects_release_bypasses_before_building(self):
        for arguments in [["--configuration", "Release"], ["--", "-configuration", "Release"],
                          ["-derivedDataPath", "/tmp/unused"],
                          ["--configuration", "Release", "--signing-identity", IDENTITY,
                           "--team-id", policy.TEAM_ID, "CODE_SIGNING_ALLOWED=NO"],
                          ["--configuration", "Release", "--signing-identity", IDENTITY,
                           "--team-id", policy.TEAM_ID, "OTHER_SWIFT_FLAGS=-DDEBUG"]]:
            result = subprocess.run(["/bin/zsh", str(ROOT / "scripts/build-app.sh"), *arguments],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertNotIn("Built ", result.stdout)


class ReleaseStagingContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spillcheck-release-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "Original.app"
        contents = self.source / "Contents"
        for subdirectory in ["MacOS", "Helpers", "Resources/Scanner", "Resources/ThirdPartyLicenses"]:
            (contents / subdirectory).mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": policy.BUNDLE_ID, "CFBundleExecutable": "Spillcheck",
            "LSMinimumSystemVersion": "14.0", "SpillcheckKeychainAccessGroup": policy.ACCESS_GROUP}))
        for path in [contents / "MacOS/Spillcheck", contents / "Helpers/spillcheck-hook", contents / "Helpers/betterleaks"]:
            path.write_bytes(bytes.fromhex("cffaedfe") + b"synthetic executable fixture")
            path.chmod(0o755)
        scanner = contents / "Resources/Scanner"
        (scanner / "betterleaks.toml").write_bytes(b"synthetic rules fixture\n")
        (scanner / "LICENSE").write_bytes(b"synthetic scanner license fixture\n")
        for name, value in [("BETTERLEAKS_RULES_SHA256", packager.digest(scanner / "betterleaks.toml")),
                            ("BETTERLEAKS_LICENSE_SHA256", packager.digest(scanner / "LICENSE"))]:
            patcher = patch.object(packager, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        shutil.copyfile(ROOT / "Spillcheck/Resources/ThirdPartyLicenses/GRDB-7.11.1.txt",
                        contents / "Resources/ThirdPartyLicenses/GRDB-7.11.1.txt")
        manifest = dict(build_metadata(), schemaVersion=1, engine="betterleaks", version="1.9.0", regexEngine="stdlib",
                        verifiedBeforeSigning={"betterleaks": policy.BETTERLEAKS_BINARY_SHA256,
                                               "betterleaks.toml": packager.BETTERLEAKS_RULES_SHA256,
                                               "LICENSE": packager.BETTERLEAKS_LICENSE_SHA256},
                        bundledExecutableSHA256=packager.digest(contents / "Helpers/betterleaks"))
        self.manifest_path = scanner / "dependencies.json"
        self.manifest_path.write_text(json.dumps(manifest))
        self.output = self.directory / "artifacts/Spillcheck-0.1.0.zip"

    def arguments(self, **changes):
        values = {"app": self.source, "identity": IDENTITY, "team_id": policy.TEAM_ID,
                  "output": self.output, "dry_run": False, "notarize": False, "notary_profile": None}
        values.update(changes)
        return argparse.Namespace(**values)

    def test_stale_scanner_hash_unreviewed_code_and_external_links_are_rejected(self):
        packager.structure(self.source)
        scanner = self.source / "Contents/Helpers/betterleaks"
        original = scanner.read_bytes()
        scanner.write_bytes(original + b"resigned")
        with self.assertRaisesRegex(policy.ReleaseError, "sealed signed hash"):
            packager.structure(self.source)
        scanner.write_bytes(original)
        unreviewed = self.source / "Contents/MacOS/unreviewed"
        unreviewed.write_bytes(original)
        with self.assertRaisesRegex(policy.ReleaseError, "unreviewed executable"):
            packager.structure(self.source)
        unreviewed.unlink()
        link = self.source / "Contents/Resources/external"
        link.symlink_to(self.directory)
        with self.assertRaisesRegex(policy.ReleaseError, "external symbolic link"):
            packager.structure(self.source)

    def test_dry_run_is_pure_and_existing_reports_and_notary_options_are_rejected(self):
        original = packager.bundle_digest(self.source)
        with patch.object(packager, "run", side_effect=AssertionError("dry run invoked a tool")):
            report = packager.package(self.arguments(dry_run=True))
            self.assertTrue(report["dryRun"])
            self.assertFalse(report["networkUsed"])
            self.assertFalse(self.output.parent.exists())
            for changes in [{"notarize": True}, {"notary_profile": "synthetic-notary-profile"},
                            {"team_id": "ABCDE12345"}]:
                with self.assertRaises(policy.ReleaseError):
                    packager.package(self.arguments(dry_run=True, **changes))
            self.output.parent.mkdir()
            self.output.with_suffix(".release.json").write_text("existing report")
            with self.assertRaisesRegex(policy.ReleaseError, "report path already exists"):
                packager.package(self.arguments(dry_run=True))
        self.assertEqual(packager.bundle_digest(self.source), original)

    def fake_package(self, *, notarize=False, status="Accepted", issues=None, corrupt_archive=False):
        actions = []
        staged_reference = []

        def fake_run(arguments, **kwargs):
            if arguments[0] == "/usr/bin/ditto" and arguments[1] != "-x":
                staged_reference.append(Path(arguments[-1]))
                shutil.copytree(Path(arguments[1]), Path(arguments[2]), symlinks=True)
            elif arguments[0] == "/usr/bin/codesign":
                target = Path(arguments[-1])
                actions.append(target.name)
                self.assertIn("--timestamp", arguments)
                self.assertNotIn("--deep", arguments)
                self.assertEqual(arguments[arguments.index("--sign") + 1], FINGERPRINT)
                if target.name == "betterleaks":
                    target.write_bytes(target.read_bytes() + b"signed fixture")
                elif target.suffix == ".app":
                    manifest = json.loads((target / "Contents/Resources/Scanner/dependencies.json").read_text())
                    self.assertEqual(manifest["bundledExecutableSHA256"], packager.digest(target / "Contents/Helpers/betterleaks"))
            elif arguments[:4] == ["/usr/bin/ditto", "-x", "-k", str(staged_reference[0].parent / "distribution.zip")]:
                shutil.copytree(staged_reference[0], Path(arguments[-1]) / "Spillcheck.app", symlinks=True)
                if corrupt_archive:
                    (Path(arguments[-1]) / "Spillcheck.app/Contents/Resources/extra-file").write_bytes(b"changed archive")
            elif arguments[:3] == ["/usr/bin/xcrun", "notarytool", "submit"]:
                self.assertIn("--keychain-profile", arguments)
                self.assertEqual(arguments[arguments.index("--keychain-profile") + 1], "synthetic-notary-profile")
                return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps({
                    "id": "884a9d61-cf0b-4e43-ad1b-1e3b8ad56880", "status": status}).encode(), stderr=b"")
            elif arguments[:3] == ["/usr/bin/xcrun", "notarytool", "log"]:
                Path(arguments[-1]).write_text(json.dumps({"issues": issues}))
            elif arguments[:3] == ["/usr/bin/xcrun", "stapler", "staple"]:
                actions.append("stapled")
            else:
                self.fail("Unexpected fake tool: " + repr(arguments))
            return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=b"")

        def fake_inspect(app, team, **kwargs):
            packager.structure(app)
            self.assertEqual(kwargs["expected_fingerprint"], FINGERPRINT)
            manifest = json.loads((app / "Contents/Resources/Scanner/dependencies.json").read_text())
            return {"releaseAcceptance": "not-checked", "scannerSignedSHA256": manifest["bundledExecutableSHA256"],
                    "notarized": kwargs.get("require_notarized", False)}, app_entitlements()

        with patch.object(packager, "identity_fingerprint", return_value=FINGERPRINT), \
             patch.object(packager, "inspect", side_effect=fake_inspect), \
             patch.object(packager, "run", side_effect=fake_run), \
             patch.object(packager, "make_zip", side_effect=lambda app, target: target.write_bytes(b"synthetic archive")):
            report = packager.package(self.arguments(notarize=notarize,
                notary_profile="synthetic-notary-profile" if notarize else None))
        return report, actions

    def test_packaging_signs_children_then_seals_hash_and_preserves_source(self):
        original = packager.bundle_digest(self.source)
        report, actions = self.fake_package()
        self.assertEqual(actions, ["betterleaks", "spillcheck-hook", "Spillcheck.app"])
        self.assertEqual(packager.bundle_digest(self.source), original)
        self.assertEqual(report["sourceBundleSHA256"], original)
        self.assertFalse(report["packagingReady"])
        self.assertTrue(report["archiveRoundTripVerified"])
        self.assertTrue(self.output.exists())
        self.assertEqual(json.loads(self.output.with_suffix(".release.json").read_text()), report)

    def test_notary_rejection_and_warning_preserve_evidence_without_archive(self):
        for status, issues in [("Invalid", [{"severity": "error"}]), ("Accepted", [{"severity": "warning"}])]:
            with self.subTest(status=status):
                with self.assertRaises(policy.ReleaseError):
                    self.fake_package(notarize=True, status=status, issues=issues)
                self.assertFalse(self.output.exists())
                self.assertFalse(self.output.with_suffix(".release.json").exists())
                evidence_path = self.output.with_suffix(".notary.json")
                evidence = json.loads(evidence_path.read_text())
                self.assertEqual(evidence["status"], status)
                self.assertEqual(evidence["log"]["issues"], issues)
                self.assertFalse(evidence["logPending"])
                evidence_path.unlink()

    def test_fake_notary_acceptance_staples_then_verifies_final_artifact(self):
        original = packager.bundle_digest(self.source)
        report, actions = self.fake_package(notarize=True)
        self.assertEqual(actions[-1], "stapled")
        self.assertTrue(report["packagingReady"])
        self.assertTrue(report["notarized"])
        self.assertEqual(report["releaseAcceptance"], "not-checked")
        self.assertEqual(packager.bundle_digest(self.source), original)
        self.assertTrue(self.output.exists())

    def test_changed_round_trip_is_rejected_before_output_creation(self):
        with self.assertRaisesRegex(policy.ReleaseError, "archive changed"):
            self.fake_package(corrupt_archive=True)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix(".release.json").exists())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({"passed": result.wasSuccessful(), "tests": result.testsRun, "syntheticOnly": True,
                      "signingOperations": 0, "notarizationUploads": 0, "appProcessesLaunched": 0,
                      "command": "python3 Tests/Tooling/check-release-policy.py", "releaseAcceptance": "not-checked"}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
