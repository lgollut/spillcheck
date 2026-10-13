"""Constructed fake files only. Never runs an app/provider or accesses the Keychain."""
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Support.acceptance_artifacts import AcceptanceArtifacts
from Support.acceptance_journal import ClaudeRecoveryJournal, JournalFailure

ROOT = Path(__file__).resolve().parents[2]


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data)
    path.chmod(0o600)


def manifest_store(root):
    store = root / "protected-store"
    store.mkdir(mode=0o700)
    vault = str(uuid.uuid4()).upper()
    manifest = {"schemaVersion": 1, "vaultID": vault, "queueKeyID": str(uuid.uuid4()).upper(),
        "identityKeyID": str(uuid.uuid4()).upper(), "inventoryRightID": "com.leakret.app.inventory.v1." + vault}
    connection = sqlite3.connect(store / "leakret.sqlite")
    connection.execute("CREATE TABLE protection_manifest (id INTEGER PRIMARY KEY, encoded BLOB)")
    connection.execute("CREATE TABLE private_payload (secret BLOB)")
    connection.execute("INSERT INTO private_payload VALUES ('DO_NOT_COPY_ENCRYPTED_ROWS')")
    connection.execute("INSERT INTO protection_manifest VALUES (1, ?)", (json.dumps(manifest).encode(),))
    connection.commit()
    connection.close()
    (store / "leakret.sqlite").chmod(0o600)
    return manifest


class JournalTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".build")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "owned"
        self.root.mkdir(mode=0o700)
        self.output = self.base / "report.json"
        self.journals = []
        self.addCleanup(self.close_journals)

    def close_journals(self):
        for journal in self.journals:
            journal.stop()
            journal.finish(False)

    def journal(self):
        value = ClaudeRecoveryJournal(self.root, self.output)
        self.journals.append(value)
        return value

    def source(self, name="session.jsonl", data=b'{"type":"fake"}\n'):
        path = self.root / "claude/projects/project" / name
        write(path, data)
        # mkdir(parents=True) uses default permissions for intermediate directories.
        for parent in path.parents:
            if parent == self.root:
                break
            parent.chmod(0o700)
        return path

    def read(self, journal):
        return json.loads((journal.directory / "journal.json").read_text())

    def test_initial_pending_journal_exists_without_granting_authority(self):
        journal = self.journal()
        report = self.read(journal)
        self.assertEqual(report["state"], "running")
        self.assertFalse(report["cleanupAuthorityGranted"])
        self.assertIsNone(report["protectionManifest"])
        self.assertFalse(report["committedProtectionManifestObserved"])
        self.assertEqual(journal.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((journal.directory / "journal.json").stat().st_mode & 0o777, 0o600)

    def test_only_exact_fake_sources_manifest_and_closed_report_projection_are_retained(self):
        native = self.source(data=b'{"type":"fake","value":"ONLY_FAKE_CONTENT"}\n')
        manifest = manifest_store(self.root)
        write(self.root / "claude/.credentials.json", b"DO_NOT_COPY_CREDENTIALS")
        write(self.root / "run-token", b"DO_NOT_COPY_TOKEN")
        write(self.root / "worker1-stdout.bin", b"DO_NOT_COPY_STDOUT")
        write(self.root / "claude/settings.json", b"DO_NOT_COPY_SETTINGS")
        write(self.root / "worker1-report.json", json.dumps({"queueCount": 7, "gapReasons": ["unsupportedContent"],
            "gapCountsByOperation": {"liveRead": {"unsupportedContent": 1}, "DO_NOT_COPY_PATH": {"secret": 9}},
            "transportRejectionCountsByStageAndReason": {"frameHeader": {"invalidFrame": 1, "DO_NOT_COPY_NEW_REASON": 2}},
            "futureSecret": "DO_NOT_COPY_FUTURE_FIELD", "recoveryVerificationPrompt": "DO_NOT_COPY_PROMPT",
            "occurrenceCount": True}).encode())
        journal = self.journal()
        journal.require_manifest()
        report = self.read(journal)
        self.assertEqual(report["protectionManifest"], manifest)
        self.assertTrue(report["committedProtectionManifestObserved"])
        projected = report["reports"]["worker1-report.json"]
        self.assertEqual(projected["queueCount"], 7)
        self.assertNotIn("occurrenceCount", projected)
        self.assertEqual(projected["gapCountsByOperation"], {"liveRead": {"unsupportedContent": 1}})
        self.assertEqual(projected["transportRejectionCountsByStageAndReason"], {"frameHeader": {"invalidFrame": 1}})
        copied = report["sources"][str(native.relative_to(self.root))]
        self.assertEqual((journal.directory / copied["file"]).read_bytes(), native.read_bytes())
        for file in journal.directory.iterdir():
            self.assertNotIn(b"DO_NOT_COPY", file.read_bytes())
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_bootstrap_identity_is_not_a_committed_manifest_or_cleanup_authority(self):
        manifest = manifest_store(self.root)
        (self.root / "protected-store/leakret.sqlite").unlink()
        write(self.root / "protected-store/.protection-bootstrap.json", json.dumps({"manifest": manifest,
            "accessGroup": "DO_NOT_COPY_FUTURE_DATA", "phase": "creating"}).encode())
        journal = self.journal()
        with self.assertRaises(JournalFailure):
            journal.require_manifest()
        report = self.read(journal)
        self.assertEqual(report["protectionManifest"], manifest)
        self.assertFalse(report["committedProtectionManifestObserved"])
        self.assertFalse(report["cleanupAuthorityGranted"])
        self.assertNotIn("DO_NOT_COPY", (journal.directory / "journal.json").read_text())

    def test_existing_or_symlink_journal_is_never_replaced(self):
        path = self.output.with_name(self.output.name + ".private-diagnostics")
        path.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(FileExistsError):
            self.journal()
        self.assertTrue(path.is_symlink())
        self.assertTrue(self.root.is_dir())

    def test_temporary_and_symlink_output_parents_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(JournalFailure):
                ClaudeRecoveryJournal(self.root, Path(temporary) / "report.json")
        link = self.base / "linked"
        link.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(JournalFailure):
            ClaudeRecoveryJournal(self.root, link / "report.json")

    def test_missing_output_parent_is_rejected_before_new_ancestor_entries(self):
        missing = self.base / "not-created"
        with self.assertRaises(JournalFailure):
            ClaudeRecoveryJournal(self.root, missing / "report.json")
        self.assertFalse(missing.exists())

    def test_source_symlink_hardlink_or_oversized_file_fail_closed(self):
        for case in ("symlink", "hardlink", "oversized"):
            with self.subTest(case=case):
                source = self.source()
                if case == "symlink":
                    source.unlink()
                    source.symlink_to(self.base / "unreadable-outside")
                elif case == "hardlink":
                    os.link(source, self.base / "unreadable-outside")
                else:
                    source.write_bytes(b"x" * (ClaudeRecoveryJournal.MAX_FILE_BYTES + 1))
                journal = self.journal()
                self.assertFalse(journal.snapshot())
                self.assertTrue(self.read(journal)["snapshotFailed"])
                self.assertEqual(self.read(journal)["sources"], {})
                self.journals.remove(journal)
                journal.stop()
                journal.finish(False)
                shutil.rmtree(journal.directory)
                source.unlink()
                (self.base / "unreadable-outside").unlink(missing_ok=True)

    def test_source_count_and_aggregate_byte_budgets_are_enforced(self):
        self.source("one.jsonl", b"1234")
        self.source("two.jsonl", b"5678")
        journal = self.journal()
        with mock.patch.object(journal, "MAX_SOURCE_BYTES", 6):
            self.assertFalse(journal.snapshot())
        self.assertTrue(self.read(journal)["snapshotFailed"])
        self.assertLessEqual(sum(path.stat().st_size for path in journal.directory.glob("source-*.jsonl")), 6)

    def test_source_count_exhaustion_does_not_copy_the_extra_file(self):
        self.source("one.jsonl")
        self.source("two.jsonl")
        journal = self.journal()
        with mock.patch.object(journal, "MAX_FILES", 1):
            self.assertFalse(journal.snapshot())
        self.assertEqual(len(list(journal.directory.glob("source-*.jsonl"))), 1)

    def test_source_directory_budget_cannot_be_avoided_with_empty_directories(self):
        self.source()
        (self.root / "claude/projects/another").mkdir(mode=0o700)
        journal = self.journal()
        with mock.patch.object(journal, "MAX_DIRECTORIES", 1):
            self.assertFalse(journal.snapshot())

    def test_symlink_database_and_sidecars_fail_before_read(self):
        manifest_store(self.root)
        (self.root / "protected-store/leakret.sqlite-wal").symlink_to(self.base / "outside")
        journal = self.journal()
        with mock.patch("Support.acceptance_journal.sqlite3.connect") as connection:
            self.assertFalse(journal.snapshot())
            connection.assert_not_called()

    def test_manifest_read_uses_pinned_inode_during_parent_path_substitution(self):
        expected = manifest_store(self.root)
        outside = self.base / "outside"
        outside.mkdir(mode=0o700)
        decoy = manifest_store(outside)
        journal = self.journal()
        connect = sqlite3.connect
        original = self.root / "protected-store"
        parked = self.root / "parked-store"
        def substitute(database_url, **kwargs):
            self.assertIn("file:/dev/fd/", database_url)
            self.assertIn("immutable=1", database_url)
            original.rename(parked)
            original.symlink_to(outside / "protected-store", target_is_directory=True)
            try:
                return connect(database_url, **kwargs)
            finally:
                original.unlink()
                parked.rename(original)
        with mock.patch("Support.acceptance_journal.sqlite3.connect", side_effect=substitute):
            journal.require_manifest()
        retained = self.read(journal)["protectionManifest"]
        self.assertEqual(retained, expected)
        self.assertNotEqual(retained, decoy)

    def test_wal_only_manifest_cannot_pass_committed_manifest_gate(self):
        store = self.root / "protected-store"
        store.mkdir(mode=0o700)
        connection = sqlite3.connect(store / "leakret.sqlite")
        try:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE protection_manifest (id INTEGER PRIMARY KEY, encoded BLOB)")
            connection.commit()
            for file in store.iterdir():
                file.chmod(0o600)
            journal = self.journal()
            with self.assertRaises(JournalFailure):
                journal.require_manifest()
            self.assertFalse(self.read(journal)["committedProtectionManifestObserved"])
        finally:
            connection.close()

    def test_interrupted_source_update_keeps_previous_index_and_bytes_consistent(self):
        source = self.source(data=b"original fake bytes\n")
        journal = self.journal()
        self.assertTrue(journal.snapshot())
        previous = self.read(journal)
        previous_copy = next(iter(previous["sources"].values()))
        source.write_bytes(b"updated fake bytes\n")
        write_original = journal._write
        def interrupted(name, content):
            if name == "journal.json":
                raise OSError("simulated interruption before index publication")
            return write_original(name, content)
        with mock.patch.object(journal, "_write", side_effect=interrupted):
            self.assertFalse(journal.snapshot())
        self.assertEqual(self.read(journal), previous)
        self.assertEqual((journal.directory / previous_copy["file"]).read_bytes(), b"original fake bytes\n")
        self.assertEqual(len(list(journal.directory.glob("source-*.jsonl"))), 2)
        self.assertFalse(journal.snapshot())
        current_copy = next(iter(self.read(journal)["sources"].values()))
        self.assertEqual((journal.directory / current_copy["file"]).read_bytes(), b"updated fake bytes\n")
        self.assertEqual(len(list(journal.directory.glob("source-*.jsonl"))), 1)

    def test_enumerated_source_rename_during_stat_or_read_is_retried_with_original_copy_retained(self):
        for boundary in ("stat", "read"):
            with self.subTest(boundary=boundary):
                source = self.source(data=b"owned fake original\n")
                journal = self.journal()
                self.assertTrue(journal.snapshot())
                previous = self.read(journal)["sources"]
                parked = self.root / "parked-original.jsonl"
                if boundary == "stat":
                    original = os.stat
                    def disappear(name, *args, **kwargs):
                        if name == source.name and kwargs.get("dir_fd") is not None:
                            source.rename(parked)
                        return original(name, *args, **kwargs)
                    target = "Support.acceptance_journal.os.stat"
                else:
                    from Support.acceptance_journal import _read as original
                    def disappear(descriptor, name, maximum):
                        if name == source.name:
                            source.rename(parked)
                        return original(descriptor, name, maximum)
                    target = "Support.acceptance_journal._read"
                with mock.patch(target, side_effect=disappear):
                    self.assertTrue(journal.snapshot())
                current = self.read(journal)
                self.assertFalse(current["snapshotFailed"])
                self.assertEqual(current["sources"], previous)
                copied = next(iter(previous.values()))
                self.assertEqual((journal.directory / copied["file"]).read_bytes(), b"owned fake original\n")
                parked.rename(source)
                self.assertTrue(journal.snapshot())
                self.journals.remove(journal)
                journal.stop(); journal.finish(False)
                shutil.rmtree(journal.directory)

    def test_enumerated_owned_directory_rename_before_open_is_retried(self):
        source = self.source()
        journal = self.journal()
        self.assertTrue(journal.snapshot())
        directory, parked = source.parent, self.root / "parked-directory"
        original = os.open
        def disappear(name, *args, **kwargs):
            if name == directory.name and kwargs.get("dir_fd") is not None:
                directory.rename(parked)
            return original(name, *args, **kwargs)
        with mock.patch("Support.acceptance_journal.os.open", side_effect=disappear):
            self.assertTrue(journal.snapshot())
        self.assertFalse(self.read(journal)["snapshotFailed"])
        parked.rename(directory)
        self.assertTrue(journal.snapshot())

    def test_final_enumerated_source_disappearance_is_sticky_and_other_io_errors_still_fail(self):
        for boundary in ("final-missing", "permission"):
            with self.subTest(boundary=boundary):
                source = self.source()
                journal = self.journal()
                self.assertTrue(journal.snapshot())
                from Support.acceptance_journal import _read as original
                def fail(descriptor, name, maximum):
                    if name == source.name:
                        if boundary == "final-missing":
                            raise FileNotFoundError(errno.ENOENT, "simulated owned source rename")
                        raise PermissionError(errno.EACCES, "simulated unrelated failure")
                    return original(descriptor, name, maximum)
                with mock.patch("Support.acceptance_journal._read", side_effect=fail):
                    self.assertFalse(journal.snapshot(final=boundary == "final-missing"))
                self.assertTrue(self.read(journal)["snapshotFailed"])
                self.assertFalse(journal.snapshot())
                self.journals.remove(journal)
                journal.stop(); journal.finish(False)
                shutil.rmtree(journal.directory)

    def test_failed_sync_is_sticky_and_prevents_manifest_admission(self):
        manifest_store(self.root)
        journal = self.journal()
        with mock.patch("Support.acceptance_journal.os.fsync", side_effect=OSError("private detail")):
            with self.assertRaises(JournalFailure):
                journal.require_manifest()
        self.assertFalse(journal.snapshot())
        self.assertTrue(self.read(journal)["snapshotFailed"])
        self.assertNotIn("private detail", (journal.directory / "journal.json").read_text())

    def test_durable_sources_and_manifest_survive_abrupt_observer_kill_and_temp_root_loss(self):
        native = self.source()
        manifest = manifest_store(self.root)
        code = """import pathlib, sys, time
sys.path.insert(0, sys.argv[1])
from Support.acceptance_journal import ClaudeRecoveryJournal
j = ClaudeRecoveryJournal(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
j.require_manifest()
j.start()
print('ready', flush=True)
time.sleep(30)
"""
        child = subprocess.Popen([sys.executable, "-c", code, str(ROOT / "Tests"), str(self.root), str(self.output)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            child.kill()
            child.wait(timeout=5)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()
        expected = native.read_bytes()
        shutil.rmtree(self.root)
        retained = self.output.with_name(self.output.name + ".private-diagnostics")
        report = json.loads((retained / "journal.json").read_text())
        self.assertEqual(report["state"], "running")
        self.assertEqual(report["protectionManifest"], manifest)
        self.assertFalse(report["cleanupAuthorityGranted"])
        copied = next(iter(report["sources"].values()))
        self.assertEqual((retained / copied["file"]).read_bytes(), expected)

    def test_shared_artifacts_require_journal_success_and_creator_cleanup_for_removal(self):
        for condition in ("passing", "snapshot", "warning", "cleanup"):
            failure = condition != "passing"
            with self.subTest(condition=condition):
                output = self.base / (condition + ".json")
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    with AcceptanceArtifacts("spillcheck-journal-test-", output,
                            diagnostic_journal_factory=ClaudeRecoveryJournal) as artifacts:
                        manifest_store(artifacts.directory)
                        artifacts.diagnostic_journal.require_manifest()
                        if condition == "snapshot":
                            artifacts.diagnostic_journal._failed = True
                        artifacts.report.update(passed=condition != "warning",
                            result={"newVaultCleanupPassed": condition != "cleanup"})
                retained = output.with_name(output.name + ".private-diagnostics")
                report = json.loads(output.read_text())
                self.assertEqual(artifacts.passed, not failure)
                self.assertEqual(retained.exists(), failure)
                self.assertEqual(report["persistentDiagnosticsPassed"], condition != "snapshot")
                self.assertEqual(artifacts.directory.exists(), failure)
                if failure:
                    shutil.rmtree(artifacts.directory)

    def test_final_journal_write_failure_preserves_original_root(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with AcceptanceArtifacts("spillcheck-journal-test-", self.output,
                    diagnostic_journal_factory=ClaudeRecoveryJournal) as artifacts:
                manifest_store(artifacts.directory)
                artifacts.diagnostic_journal.require_manifest()
                artifacts.report.update(passed=True, diagnosticArtifactsRetained=False, result={"newVaultCleanupPassed": True})
                write_original = artifacts.diagnostic_journal._write
                def fail_final(name, content):
                    if name == "journal.json" and json.loads(content)["state"] != "running":
                        raise OSError("simulated final sync failure")
                    return write_original(name, content)
                artifacts.diagnostic_journal._write = fail_final
        self.assertFalse(artifacts.passed)
        self.assertTrue((artifacts.directory / "protected-store/leakret.sqlite").exists())
        self.assertTrue((artifacts.directory / "acceptance-run-private.json").exists())
        report = json.loads(self.output.read_text())
        self.assertFalse(report["persistentDiagnosticsPassed"])
        self.assertTrue(report["persistentDiagnosticsRetained"])
        self.assertTrue(report["diagnosticArtifactsRetained"])
        shutil.rmtree(artifacts.directory)

    def test_post_removal_sync_failure_does_not_claim_missing_directories_are_retained(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with AcceptanceArtifacts("spillcheck-journal-test-", self.output,
                    diagnostic_journal_factory=ClaudeRecoveryJournal) as artifacts:
                manifest_store(artifacts.directory)
                artifacts.diagnostic_journal.require_manifest()
                artifacts.report.update(passed=True, diagnosticArtifactsRetained=False, result={"newVaultCleanupPassed": True})
                finish = artifacts.diagnostic_journal.finish
                fsync = os.fsync
                parent_info = self.base.stat()
                def fail_parent_sync(fd):
                    info = os.fstat(fd)
                    if (info.st_dev, info.st_ino) == (parent_info.st_dev, parent_info.st_ino):
                        raise OSError("simulated parent sync failure after removal")
                    return fsync(fd)
                def wrapped_finish(passed):
                    with mock.patch("Support.acceptance_journal.os.fsync", side_effect=fail_parent_sync):
                        return finish(passed)
                artifacts.diagnostic_journal.finish = wrapped_finish
        self.assertFalse(artifacts.passed)
        self.assertFalse(artifacts.directory.exists())
        self.assertFalse(artifacts.diagnostic_journal.directory.exists())
        report = json.loads(self.output.read_text())
        self.assertFalse(report["persistentDiagnosticsPassed"])
        self.assertFalse(report["persistentDiagnosticsRetained"])
        self.assertFalse(report["diagnosticArtifactsRetained"])


if __name__ == "__main__":
    unittest.main()
