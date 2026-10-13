#!/usr/bin/env python3
"""Constructed boundary checks only; no app, provider, build, vault, or Keychain access."""
import importlib.util
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import tempfile
import unittest
import uuid
from unittest import mock

spec = importlib.util.spec_from_file_location("claude_recovery", Path(__file__).with_name("run-app-claude-recovery.py"))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryBuildBoundaryTests(unittest.TestCase):
    def test_exact_reread_cannot_discover_siblings_or_substitute_source_identity(self):
        path, session = Path("/private/fake-owned/original.jsonl"), "fake-original-session"
        request = recovery.exact_source_reread(path, session)
        self.assertEqual(request["directories"], [])
        self.assertEqual(request["pending"], [str(path)])
        self.assertEqual(request["restartSources"], [str(path)])
        self.assertEqual(request["selectedSessionID"], session)
        self.assertEqual(request["deferred"], [])
        self.assertFalse(request["partial"])
        self.assertEqual(request["audit"]["end"] - request["audit"]["start"], 604800)
        self.assertNotEqual(request["audit"]["id"], recovery.exact_source_reread(path, session)["audit"]["id"])

    def test_committed_roles_require_every_marker_and_exact_pair_for_both_producers(self):
        report = {"claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
            "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
            "claudeCommittedNativeParentChildPairCountByProducer": {"old": 1, "new": 1},
            "claudeTypedCommittedMarkersByRole": {role: {marker: 1 for marker in recovery.fixture.EXPECTED_MARKERS
                if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
            "claudeCommittedContentTypesByRole": {role: sorted(set(recovery.fixture.EXPECTED_MARKERS.values()))
                for role in ("parent", "child")}}
        self.assertTrue(recovery.committed_role_coverage_complete(report, ["old", "new"]))
        self.assertFalse(recovery.committed_role_coverage_complete({**report,
            "claudeCommittedNativeParentChildPairCountByProducer": {"old": 1}}, ["old", "new"]))
        report["claudeTypedCommittedMarkersByRole"]["child"].pop("CHILD_TOOL_ERROR")
        self.assertFalse(recovery.committed_role_coverage_complete(report, ["old", "new"]))

    def test_identity_comparisons_require_unique_nonempty_keyed_digests(self):
        first, second = (base64.b64encode(value * 32).decode() for value in (b"a", b"b"))
        before = {"ids": [first]}
        self.assertTrue(recovery.comparison(before, {"ids": [first, second]}, "ids"))
        for invalid in ([], [True], ["native-id"], [first, first], [{}], None):
            self.assertFalse(recovery.comparison({"ids": invalid}, before, "ids"))
            self.assertFalse(recovery.comparison(before, {"ids": invalid}, "ids"))
        self.assertFalse(recovery.comparison(before, {"ids": [second]}, "ids"))

    def test_full_native_roles_require_one_exact_complete_pair_per_producer(self):
        evidence = {"requiredNativeFieldsValid": True, "completeJSONLFraming": True,
                    "individualNativeRoleCoverageComplete": True,
                    "completeNativeParentChildPairCountByProducer": {"old": 1, "new": 1}}
        self.assertTrue(recovery.native_role_coverage_complete(evidence, ["old", "new"]))
        for key in evidence:
            self.assertFalse(recovery.native_role_coverage_complete({k: v for k, v in evidence.items() if k != key}, ["old", "new"]))
        for counts in ({"old": 1}, {"old": 1, "new": True}, {"old": 1, "new": 0}):
            self.assertFalse(recovery.native_role_coverage_complete({**evidence,
                "completeNativeParentChildPairCountByProducer": counts}, ["old", "new"]))
        self.assertFalse(recovery.native_role_coverage_complete({"typedMarkersByProducer": {
            "old": list(recovery.fixture.EXPECTED_MARKERS), "new": list(recovery.fixture.EXPECTED_MARKERS)}}, ["old", "new"]))

    def test_uncertain_process_group_cleanup_cannot_authorize_creator_cleanup(self):
        self.assertTrue(recovery.cleanup_confirmed({"term_permission_denied": False, "kill_permission_denied": False}))
        for invalid in ({}, None, {"term_permission_denied": False},
                        {"term_permission_denied": True, "kill_permission_denied": False},
                        {"term_permission_denied": False, "kill_permission_denied": True}):
            self.assertFalse(recovery.cleanup_confirmed(invalid))

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

    def test_selected_starting_schema_must_match_exact_measured_integer(self):
        for selected in (1, 2):
            observed = {"recoveryProfileSchemaMeasurementAvailable": True,
                        "recoveryLoadedProfileSchemaVersion": selected, "recoverySavedProfileSchemaVersion": 3}
            self.assertTrue(recovery.migration_schema_observed(observed, selected))
            for field in observed:
                incomplete = {key: value for key, value in observed.items() if key != field}
                self.assertFalse(recovery.migration_schema_observed(incomplete, selected))
            for changes in [{"recoveryProfileSchemaMeasurementAvailable": 1},
                            {"recoveryLoadedProfileSchemaVersion": 3 - selected},
                            {"recoveryLoadedProfileSchemaVersion": True},
                            {"recoveryLoadedProfileSchemaVersion": str(selected)},
                            {"recoverySavedProfileSchemaVersion": True},
                            {"recoverySavedProfileSchemaVersion": "3"},
                            {"recoverySavedProfileSchemaVersion": 2}]:
                self.assertFalse(recovery.migration_schema_observed({**observed, **changes}, selected))
        for invalid in (True, False, 0, 3, "1", None):
            self.assertFalse(recovery.migration_schema_observed(observed, invalid))
            with self.assertRaises(RuntimeError):
                recovery.migration_checks(invalid)

    def test_schema_option_requires_rebuild_and_defaults_to_existing_schema2_mode(self):
        base = ["--output", "/synthetic-report.json", "--starting-executable", "/synthetic-claude"]
        self.assertEqual(recovery.parse_arguments(base).expected_starting_schema, 2)
        rebuilt = base + ["--rebuild-app-between-workers"]
        self.assertEqual(recovery.parse_arguments(rebuilt).expected_starting_schema, 2)
        self.assertEqual(recovery.migration_checks(), recovery.MIGRATION_CHECKS)
        for schema in (1, 2):
            args = recovery.parse_arguments(rebuilt + ["--expected-starting-schema", str(schema)])
            self.assertEqual(args.expected_starting_schema, schema)
            checks = recovery.migration_checks(schema)
            self.assertIn(f"encryptedProfileSchema{schema}MigratedTo3", checks)
            self.assertNotIn(f"encryptedProfileSchema{3 - schema}MigratedTo3", checks)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                recovery.parse_arguments(base + ["--expected-starting-schema", str(schema)])
            self.assertEqual(error.exception.code, 2)
        for schema in ("0", "3", "true"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                recovery.parse_arguments(rebuilt + ["--expected-starting-schema", schema])
            self.assertEqual(error.exception.code, 2)

    def test_migration_claims_require_full_run_and_distinguish_selected_schema(self):
        for selected in (1, 2):
            observed = {"recoveryProfileSchemaMeasurementAvailable": True,
                        "recoveryLoadedProfileSchemaVersion": selected, "recoverySavedProfileSchemaVersion": 3}
            arguments = {"passed": True, "rebuild_requested": True, "owner_smoke": False,
                         "expected_starting_schema": selected, "report": observed}
            claims = recovery.migration_claims(**arguments)
            self.assertIs(claims[f"signedAppSchema{selected}To3MigrationEstablished"], True)
            self.assertIs(claims[f"signedAppSchema{3 - selected}To3MigrationEstablished"], False)
            for changes in [{"passed": False}, {"rebuild_requested": False}, {"owner_smoke": True},
                            {"report": {}}, {"expected_starting_schema": 3 - selected},
                            {"report": {**observed, "recoveryLoadedProfileSchemaVersion": True}}]:
                self.assertEqual(recovery.migration_claims(**{**arguments, **changes}), {
                    "signedAppSchema1To3MigrationEstablished": False,
                    "signedAppSchema2To3MigrationEstablished": False})

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


class RecoveryCleanupLifetimeTests(unittest.TestCase):
    def run_smoke(self, root, *, auth_cleanup=True, group_cleanup=True):
        owned = root / "owned"
        owned.mkdir()
        output = root / "report.json"
        events = []

        class FakeProcess:
            def __init__(self, command, **kwargs):
                self.owner = "--acceptance-vault-owner" in command
                self.returncode = None
                self.pid = 10 if self.owner else 11
                self.report = Path(command[command.index("--acceptance-report") + 1])
                if self.owner:
                    store = owned / "protected-store"
                    store.mkdir()
                    vault = str(uuid.uuid4()).upper()
                    manifest = {"schemaVersion": 1, "vaultID": vault, "queueKeyID": str(uuid.uuid4()).upper(),
                        "identityKeyID": str(uuid.uuid4()).upper(), "inventoryRightID": "com.leakret.app.inventory.v1." + vault}
                    connection = sqlite3.connect(store / "leakret.sqlite")
                    connection.execute("CREATE TABLE protection_manifest (id INTEGER PRIMARY KEY, encoded BLOB)")
                    connection.execute("INSERT INTO protection_manifest VALUES (1, ?)", (json.dumps(manifest).encode(),))
                    connection.commit()
                    connection.close()
                    value = {"ownerReady": True, "createdFreshVault": True, "cleanupPassed": False}
                    (owned / "claude/projects/original.jsonl").write_text("fake original native bytes\n")
                else:
                    value = {"storageReady": True, "recoveryLoadedExistingManifest": True,
                             "recoveryManifestDigest": "private-fake-digest"}
                self.write_report(value)

            def write_report(self, value):
                # Match the signed app's atomic reports while the journal observes.
                temporary = self.report.with_suffix(".new")
                temporary.write_text(json.dumps(value))
                temporary.replace(self.report)

            def poll(self):
                return self.returncode

            def wait(self, **kwargs):
                self.returncode = 0
                if self.owner:
                    events.append("creator-cleanup")
                    assert (owned / "owner-finish").exists()
                    self.write_report({"cleanupPassed": True})
                else:
                    events.append("worker-exit")
                return 0

        def stopped(process):
            process.returncode = 0
            events.append("owner-stop" if process.owner else "worker-stop")
            return {"term_permission_denied": not group_cleanup, "kill_permission_denied": False}

        def authentication_removed(config, env):
            events.append("authentication-cleanup")
            return auth_cleanup

        arguments = ["--output", str(output), "--app", str(root / "fake.app"),
            "--starting-executable", str(root / "old"), "--upgraded-executable", str(root / "new"),
            "--expected-starting-version", "2.1.295", "--expected-upgraded-version", "2.1.296", "--owner-smoke"]
        mask = os.umask(0o077)
        try:
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(recovery.sys, "argv", ["runner"] + arguments))
                stack.enter_context(mock.patch("Support.acceptance_artifacts.tempfile.mkdtemp", return_value=str(owned)))
                stack.enter_context(mock.patch.object(recovery.subprocess, "check_output", side_effect=lambda args, **kwargs:
                    "2.1.295" if args[0].endswith("/old") else "2.1.296"))
                stack.enter_context(mock.patch.object(recovery.subprocess, "run", side_effect=lambda args, **kwargs:
                    subprocess.CompletedProcess(args, 1 if args[0] == "/usr/bin/pgrep" else 0)))
                stack.enter_context(mock.patch.object(recovery.subprocess, "Popen", side_effect=FakeProcess))
                stack.enter_context(mock.patch.object(recovery, "stop_group", side_effect=stopped))
                stack.enter_context(mock.patch.object(recovery.live, "remove_provider_authentication", side_effect=authentication_removed))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                code = recovery.main()
        finally:
            os.umask(mask)
        return code, json.loads(output.read_text()), owned, events

    def test_creator_cleanup_follows_worker_exit_group_cleanup_and_auth_removal(self):
        with tempfile.TemporaryDirectory(dir=recovery.ROOT / ".build") as directory:
            code, report, owned, events = self.run_smoke(Path(directory))
            self.assertEqual(code, 0)
            self.assertTrue(report["passed"])
            for stage in ("worker-exit", "worker-stop", "authentication-cleanup"):
                self.assertLess(events.index(stage), events.index("creator-cleanup"))
            self.assertFalse(owned.exists())

    def test_uncertain_auth_or_group_cleanup_retains_original_source_and_protection(self):
        for options in ({"auth_cleanup": False}, {"group_cleanup": False}):
            with tempfile.TemporaryDirectory(dir=recovery.ROOT / ".build") as directory:
                code, report, owned, events = self.run_smoke(Path(directory), **options)
                self.assertEqual(code, 1)
                self.assertFalse(report["passed"])
                self.assertTrue(report["ownedProtectionCleanupPending"])
                self.assertNotIn("creator-cleanup", events)
                self.assertFalse((owned / "owner-finish").exists())
                self.assertEqual((owned / "claude/projects/original.jsonl").read_text(), "fake original native bytes\n")


if __name__ == "__main__":
    unittest.main()
