import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import preflight
import trial


def digest(data): return hashlib.sha256(data).hexdigest()


class CandidatePreflight(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "PRIVATE_APP.app"
        self.source = self.root / "PRIVATE_SOURCE"
        self.executable = self.app / "Contents/MacOS/Spillcheck"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"FAKE_EXECUTABLE")
        self.source.mkdir()
        for name in preflight.FIXED_INPUTS | {"Sources/Core/value.swift", "Spillcheck/App/App.swift"}:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"FAKE_SOURCE")
        pairs = [["Contents/MacOS/Spillcheck", digest(self.executable.read_bytes())]]
        self.manifest = {"schemaVersion": 1, "bundleDigestFormat": preflight.DIGEST_FORMAT,
            "bundleSHA256": digest(json.dumps(pairs, separators=(",", ":")).encode()),
            "executableSHA256": digest(self.executable.read_bytes()),
            "sourceSHA256": {name: digest((self.source / name).read_bytes()) for name in preflight.source_files(self.source)}}
        self.manifest_path = self.root / "candidate.json"
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.signature = patch.object(preflight, "verify_signature", return_value="passed").start()
        self.addCleanup(patch.stopall)

    def check(self, log=None):
        return preflight.check(preflight.read_manifest(self.manifest_path), self.app, self.source, log)

    def test_matching_artifact_never_confers_beta_or_running_app_acceptance(self):
        result = self.check()
        self.assertTrue(result["consistent"])
        for key in ("betaAcceptanceEstablished", "runningAppVerified", "signatureIdentityVerified",
                    "completeBuildProvenanceVerified"):
            self.assertFalse(result[key])
        encoded = json.dumps(result)
        for forbidden in (str(self.root), "FAKE_SOURCE", "FAKE_EXECUTABLE", "PRIVATE_APP", "PRIVATE_SOURCE"):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(result["sourceInputScope"], "swiftSourcesAndRecordedBuildFiles")

    def test_stale_or_missing_or_new_sources_fail_without_changing_manifest(self):
        original = self.manifest_path.read_bytes()
        (self.source / "Sources/Core/value.swift").write_bytes(b"NEW_CODE")
        result = self.check()
        self.assertFalse(result["consistent"])
        self.assertEqual(result["changedSourceInputCount"], 1)
        (self.source / "Sources/Core/value.swift").unlink()
        (self.source / "Sources/Core/new.swift").write_bytes(b"NEW_FILE")
        result = self.check()
        self.assertEqual(result["newSourceInputCount"], 1)
        self.assertEqual(result["missingSourceInputCount"], 1)
        self.assertFalse(result["recordedSourceInputsMatch"])
        self.assertEqual(self.manifest_path.read_bytes(), original)

    def test_changed_executable_or_added_bundle_file_cannot_reuse_evidence(self):
        self.executable.write_bytes(b"REBUILT_EXECUTABLE")
        result = self.check()
        self.assertFalse(result["bundleMatchesRecord"])
        self.assertFalse(result["executableMatchesRecord"])
        self.executable.write_bytes(b"FAKE_EXECUTABLE")
        (self.app / "extra").write_bytes(b"EXTRA")
        result = self.check()
        self.assertTrue(result["executableMatchesRecord"])
        self.assertFalse(result["bundleMatchesRecord"])

    def test_signature_failure_or_unavailability_is_not_success(self):
        for state in ("failed", "unavailable"):
            self.signature.return_value = state
            result = self.check()
            self.assertFalse(result["consistent"])
            self.assertEqual(result["signatureValidation"], state)

    def test_mutation_during_signature_check_is_rejected(self):
        def mutate(_):
            self.executable.write_bytes(b"CHANGED_WHILE_CHECKING")
            return "passed"
        self.signature.side_effect = mutate
        with self.assertRaises(preflight.Invalid): self.check()

    def test_trial_binding_is_checked_without_editing_legacy_or_current_logs(self):
        log = self.root / "trial.json"
        for payload, state in ((trial.new_log(self.manifest["bundleSHA256"]), "matches"),
                               (trial.new_log("b" * 64), "mismatch"),
                               ({"schemaVersion": 1, "days": []}, "legacyUnbound")):
            log.write_text(json.dumps(payload))
            before = log.read_bytes()
            result = self.check(log)
            self.assertEqual(result["trialCandidateBinding"], state)
            self.assertEqual(result["consistent"], state == "matches")
            self.assertEqual(log.read_bytes(), before)

    def test_symlinked_bundle_file_and_source_directory_are_rejected(self):
        (self.app / "linked").symlink_to(self.executable)
        with self.assertRaises(preflight.Invalid): self.check()
        (self.app / "linked").unlink()
        (self.source / "Sources/linked").symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(preflight.Invalid): self.check()

    def test_manifest_path_traversal_unknown_digest_format_and_duplicate_keys_rejected(self):
        for bad in ("../outside.swift", "/outside.swift", "Sources/../outside.swift", "Sources/./code.swift", "Sources/a\x00.swift", "private.txt"):
            value = copy.deepcopy(self.manifest)
            value["sourceSHA256"][bad] = "a" * 64
            self.manifest_path.write_text(json.dumps(value))
            with self.assertRaises(preflight.Invalid): preflight.read_manifest(self.manifest_path)
        value = copy.deepcopy(self.manifest)
        value["bundleDigestFormat"] = "guess"
        self.manifest_path.write_text(json.dumps(value))
        with self.assertRaises(preflight.Invalid): preflight.read_manifest(self.manifest_path)
        self.manifest_path.write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaises(preflight.Invalid): preflight.read_manifest(self.manifest_path)

    def test_manifest_and_input_size_budgets_are_enforced(self):
        with patch.object(preflight, "MAX_FILE_BYTES", 2):
            with self.assertRaises(preflight.Invalid): self.check()
        with patch.object(preflight, "MAX_TOTAL_BYTES", 10):
            with self.assertRaises(preflight.Invalid): self.check()
        with patch.object(preflight, "MAX_FILES", 1):
            with self.assertRaises(preflight.Invalid): self.check()

    def test_fifo_trial_input_is_rejected_without_waiting_for_a_writer(self):
        fifo = self.root / "PRIVATE_FIFO"
        os.mkfifo(fifo)
        result = subprocess.run([sys.executable, str(Path(trial.__file__)), "--log", str(fifo), "summary"],
            capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"PRIVATE_FIFO", result.stdout + result.stderr)
        with self.assertRaises(trial.Invalid): self.check(fifo)

    def test_deeply_nested_json_is_a_controlled_rejection(self):
        nested = '{"ignored":' + '[' * 1500 + '0' + ']' * 1500 + '}'
        self.manifest_path.write_text(nested)
        with self.assertRaises(preflight.Invalid): preflight.read_manifest(self.manifest_path)
        log = self.root / "PRIVATE_DEEP_LOG"
        log.write_text(nested)
        result = subprocess.run([sys.executable, str(Path(trial.__file__)), "--log", str(log), "summary"],
            capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"Traceback", result.stderr)
        self.assertNotIn(b"PRIVATE_DEEP_LOG", result.stdout + result.stderr)

    def test_cli_errors_never_echo_private_input_or_raw_error(self):
        self.manifest_path.write_text("PRIVATE_BROKEN_CONTENT")
        result = subprocess.run([sys.executable, str(Path(preflight.__file__)), "--manifest", str(self.manifest_path),
            "--app", str(self.app), "--source-root", str(self.source)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)["consistent"])
        self.assertEqual(result.stderr, b"")
        self.assertNotIn(b"PRIVATE", result.stdout)


if __name__ == "__main__": unittest.main()
