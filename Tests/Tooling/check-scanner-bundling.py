#!/usr/bin/env python3
"""Check incremental scanner bundling using fake signing and disposable fixture paths."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "A" * 40


class IncrementalScannerContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spillcheck-scanner-bundle-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root / ".build/scanner"
        source.mkdir(parents=True)
        files = {"betterleaks": b"synthetic executable", "betterleaks.toml": b"synthetic rules", "LICENSE": b"synthetic license"}
        for name, content in files.items():
            (source / name).write_bytes(content)
        (source / "dependencies.json").write_text(json.dumps({"schemaVersion": 1, "engine": "betterleaks",
            "version": "1.9.0", "license": "MIT", "verifiedBeforeSigning": {
                name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}))
        self.contents = self.root / "products/Synthetic.app/Contents"
        self.environment = {"SRCROOT": str(self.root), "TARGET_BUILD_DIR": str(self.root / "products"),
            "CONTENTS_FOLDER_PATH": "Synthetic.app/Contents", "EXPANDED_CODE_SIGN_IDENTITY": IDENTITY,
            "CODE_SIGNING_ALLOWED": "YES", "CONFIGURATION": "Debug", "ARCHS": "arm64",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "MACOSX_DEPLOYMENT_TARGET": "14.0"}
        self.signs = []
        self.fail_verify = False

    def fake_run(self, arguments, **kwargs):
        if arguments[0] == "/usr/bin/python3":
            return subprocess.CompletedProcess(arguments, 0)
        self.assertEqual(arguments[0], "/usr/bin/codesign")
        executable = Path(arguments[-1])
        if "--sign" in arguments:
            identity = arguments[arguments.index("--sign") + 1]
            self.signs.append(identity)
            executable.write_bytes(executable.read_bytes() + (" signed-" + identity + "-" + str(len(self.signs))).encode())
        elif "--test-requirement" in arguments:
            identity = self.environment["EXPANDED_CODE_SIGN_IDENTITY"]
            self.assertEqual(arguments[arguments.index("--test-requirement") + 1],
                             '=certificate leaf = H"' + identity + '"')
            if self.fail_verify or identity.encode() not in executable.read_bytes():
                self.fail_verify = False
                return subprocess.CompletedProcess(arguments, 1, stdout=b"", stderr=b"invalid signature")
        elif "-d" in arguments:
            return subprocess.CompletedProcess(arguments, 0, stdout=b"",
                stderr=b"CodeDirectory flags=0x10000(runtime)\nTimestamp=synthetic timestamp\n")
        return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=b"")

    def bundle(self):
        with patch.dict(os.environ, self.environment, clear=True), patch("subprocess.run", side_effect=self.fake_run), \
             contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT / "scripts/bundle-scanner.py"), run_name="__main__")

    def snapshot(self):
        return {str(path.relative_to(self.contents)): (path.read_bytes(), path.stat().st_mtime_ns,
                                                     path.stat().st_mode & 0o777)
                for path in self.contents.rglob("*") if path.is_file()}

    def assert_sealed_hash(self):
        manifest = json.loads((self.contents / "Resources/Scanner/dependencies.json").read_text())
        scanner = self.contents / "Helpers/betterleaks"
        self.assertEqual(manifest["bundledExecutableSHA256"], hashlib.sha256(scanner.read_bytes()).hexdigest())

    def test_identical_second_build_preserves_all_sealed_bytes_and_mtimes(self):
        self.bundle()
        first = self.snapshot()
        self.bundle()
        self.assertEqual(self.snapshot(), first)
        self.assertEqual(self.signs, [IDENTITY])
        self.assert_sealed_hash()

    def test_invalid_or_changed_signature_is_replaced_and_resealed(self):
        self.bundle()
        for change in ["invalid signature", "tampered bytes", "different identity"]:
            with self.subTest(change=change):
                if change == "invalid signature":
                    self.fail_verify = True
                elif change == "tampered bytes":
                    scanner = self.contents / "Helpers/betterleaks"
                    scanner.write_bytes(scanner.read_bytes() + b"tampered")
                else:
                    self.environment["EXPANDED_CODE_SIGN_IDENTITY"] = "B" * 40
                prior_count = len(self.signs)
                self.bundle()
                self.assertEqual(len(self.signs), prior_count + 1)
                self.assert_sealed_hash()

    def test_changed_build_metadata_updates_only_manifest(self):
        self.bundle()
        first = self.snapshot()
        self.environment["OTHER_SWIFT_FLAGS"] = "-D ANOTHER_CONDITION"
        self.bundle()
        second = self.snapshot()
        for name in first:
            if name != "Resources/Scanner/dependencies.json":
                self.assertEqual(second[name], first[name])
        self.assertNotEqual(second["Resources/Scanner/dependencies.json"][0], first["Resources/Scanner/dependencies.json"][0])
        self.assertEqual(len(self.signs), 1)

    def test_changed_provenance_resigns_and_resource_repair_is_precise(self):
        self.bundle()
        source = self.root / ".build/scanner"
        raw = source / "betterleaks"
        raw.write_bytes(b"updated verified fixture")
        metadata_path = source / "dependencies.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["verifiedBeforeSigning"]["betterleaks"] = hashlib.sha256(raw.read_bytes()).hexdigest()
        metadata_path.write_text(json.dumps(metadata))
        self.bundle()
        self.assertEqual(len(self.signs), 2)
        self.assert_sealed_hash()
        first = self.snapshot()
        rules = self.contents / "Resources/Scanner/betterleaks.toml"
        rules.write_bytes(b"tampered rules")
        self.bundle()
        self.assertEqual(self.snapshot()["Helpers/betterleaks"], first["Helpers/betterleaks"])
        self.assertEqual(rules.read_bytes(), (source / "betterleaks.toml").read_bytes())

    def test_release_transition_resigns_once_with_secure_timestamp(self):
        self.bundle()
        self.environment.update(CONFIGURATION="Release", SWIFT_ACTIVE_COMPILATION_CONDITIONS="")
        self.bundle()
        self.assertEqual(len(self.signs), 2)
        first = self.snapshot()
        self.bundle()
        self.assertEqual(self.snapshot(), first)
        self.assertEqual(len(self.signs), 2)
        manifest = json.loads((self.contents / "Resources/Scanner/dependencies.json").read_text())
        self.assertTrue(manifest["bundledSigning"]["secureTimestamp"])


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    print(json.dumps({"passed": result.wasSuccessful(), "tests": result.testsRun, "syntheticOnly": True,
                      "actualSigningOperations": 0, "appProcessesLaunched": 0,
                      "command": "python3 Tests/Tooling/check-scanner-bundling.py", "incrementalAppSigning": "not-checked"}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
