"""Collector boundary checks. These create no real provider or GUI sessions."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BINARY = Path(os.environ.get("SPILLCHECK_GUI_PROBE_BINARY", str(
    ROOT / ".build/harness-compatibility/manual-codex-gui-2026-10-09/codex-gui-format-probe")))


class GUIProbeScopeTests(unittest.TestCase):
    def test_reuse_rejects_changed_core_artifacts_before_fixture_handoff(self):
        spec = importlib.util.spec_from_file_location("codex_gui_probe_runner", HERE / "run.py")
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory(prefix="spillcheck-gui-build-check-") as temporary:
            root = Path(temporary)
            products = root / "products"
            products.mkdir()
            module = products / "SpillcheckCore.swiftmodule"
            module.mkdir()
            (module / "controlled.swiftmodule").write_bytes(b"owned-module-fixture")
            library = products / "libSpillcheckCore.a"
            library.write_bytes(b"owned-library-fixture")
            binary = root / "never-launched-probe"
            binary.write_bytes(b"owned-no-executable-fixture")
            source_hash = runner.hashlib.sha256((HERE / "main.swift").read_bytes()).hexdigest()
            binary.with_suffix(".build.json").write_text(json.dumps({"coreProducts": runner.core_fingerprints(products),
                "probeSourceSHA256": source_hash}))
            runner.verify_reusable_build(products, binary)
            library.write_bytes(b"replacement-owned-library-fixture")
            with self.assertRaisesRegex(SystemExit, "does not match current Core/source artifacts"):
                runner.verify_reusable_build(products, binary)

    def test_missing_native_runtime_identity_has_no_store_guess(self):
        with tempfile.TemporaryDirectory(prefix="spillcheck-gui-helper-check-") as temporary:
            work = Path(temporary)
            result = subprocess.run(["python3", str(HERE / "fixture.py"), "register", "parent", "--work", str(work)],
                cwd=work, env={"PATH": os.defpath, "HOME": str(work)}, timeout=5, capture_output=True)
            self.assertEqual(result.returncode, 64)
            self.assertFalse((work / "parent-identity.json").exists())
            self.assertEqual(json.loads((work / "parent-unavailable.json").read_text())["reason"],
                "native-runtime-CODEX_THREAD_ID-unavailable")

    def test_wrong_authorized_store_cannot_start_reader(self):
        self.assertTrue(BINARY.is_file(), "Run run.py prepare against cached core products first.")
        with tempfile.TemporaryDirectory(prefix="spillcheck-gui-scope-check-") as temporary:
            root = Path(temporary).resolve()
            work, home, private = root / "work", root / "authorized", root / "private"
            for path in (work, home, private):
                path.mkdir(mode=0o700)
            sentinel = root / "reader-called"
            fake_reader = root / "codex-sentinel"
            # This owned executable must never be called, including --version.
            fake_reader.write_text("#!/bin/sh\nprintf '%s\\n' 'called' > '" + str(sentinel) + "'\nexit 64\n")
            fake_reader.chmod(0o700)
            child = subprocess.Popen([str(BINARY), "--project", str(work), "--authorized-home", str(home),
                "--private-directory", str(private), "--host-version", "fixture-only", "--executable", str(fake_reader),
                "--scanner", str(ROOT / ".build/scanner/betterleaks"), "--rules", str(ROOT / ".build/scanner/betterleaks.toml"),
                "--duration", "10"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(json.loads(child.stdout.readline())["ready"])
                manifest = {"role": "parent", "nativeThreadID": "owned-fixture-native-id",
                    "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID", "storeCandidate": str(root / "different-store"),
                    "storeCandidateSource": "own-runtime-CODEX_HOME", "workingDirectory": str(work),
                    "registeredAtUnix": time.time()}
                (work / "parent-identity.json").write_text(json.dumps(manifest))
                output, errors = child.communicate(timeout=5)
                report = json.loads(output)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(report["reason"], "runtime-selection-or-store-authorization-mismatch")
                self.assertFalse(report["passed"])
                self.assertFalse(report["productionGUICollectionEnabled"])
                self.assertFalse(sentinel.exists())
                self.assertFalse((work / "parent-collector-ready").exists())
                self.assertEqual(errors, "")
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
