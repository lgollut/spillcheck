#!/usr/bin/env python3
"""Constructed boundary checks only; no app, provider, build, vault, or Keychain access."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("claude_recovery", Path(__file__).with_name("run-app-claude-recovery.py"))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryBuildBoundaryTests(unittest.TestCase):
    def test_fixed_build_rejects_another_bundle_and_has_no_optional_shell_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / ".build/app/Build/Products/Debug/Spillcheck.app"
            self.assertEqual(recovery.fixed_rebuild_command(root, app), [
                str(root / "scripts/build-app.sh"), "--configuration", "Debug",
                "--derived-data", str(root / ".build/app")])
            with self.assertRaises(RuntimeError):
                recovery.fixed_rebuild_command(root, root / "elsewhere/Spillcheck.app")

    def test_schema_migration_requires_measured_loaded_and_persisted_versions(self):
        observed = {"recoveryProfileSchemaMeasurementAvailable": True,
                    "recoveryLoadedProfileSchemaVersion": 2, "recoverySavedProfileSchemaVersion": 3}
        self.assertTrue(recovery.migration_schema_observed(observed))
        for changes in [{"recoveryProfileSchemaMeasurementAvailable": False},
                        {"recoveryLoadedProfileSchemaVersion": 3},
                        {"recoverySavedProfileSchemaVersion": 2},
                        {"recoveryLoadedProfileSchemaVersion": "2"},
                        {"recoverySavedProfileSchemaVersion": "3"}]:
            self.assertFalse(recovery.migration_schema_observed({**observed, **changes}))
        self.assertFalse(recovery.migration_schema_observed({}))

    def test_frozen_snapshot_detects_changed_added_or_removed_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "Sources/Core").mkdir(parents=True)
            source = root / "Sources/Core/A.swift"
            source.write_text("let value = 1\n")
            original = recovery.source_snapshot(root)
            self.assertEqual(recovery.source_snapshot(root), original)
            source.write_text("let value = 2\n")
            self.assertNotEqual(recovery.source_snapshot(root), original)
            source.write_text("let value = 1\n")
            added = root / "Sources/Core/B.swift"
            added.write_text("let other = 2\n")
            self.assertNotEqual(recovery.source_snapshot(root), original)
            added.unlink()
            source.unlink()
            with self.assertRaises(RuntimeError):
                recovery.source_snapshot(root)


if __name__ == "__main__":
    unittest.main()
