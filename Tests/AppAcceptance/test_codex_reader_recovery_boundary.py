import base64
import copy
import importlib.util
import os
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("reader_recovery", Path(__file__).with_name("run-app-codex-reader-recovery.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

CAPTURE = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"


def digest(number):
    return base64.b64encode(bytes([number]) * 32).decode()


def baseline():
    value = {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "recoveryCaptureIdentityMeasurementAvailable": True,
        "queueCount": 0, "valueCount": 0, "occurrenceCount": 0, "gapReasons": [],
        "coverageReportTruncated": False, "recoveryQueueClaimedCount": 0}
    for key in (*reader.shared.DIGEST_KEYS, "recoveryPendingCaptureDigests", "recoveryConsumedCaptureDigests",
            "recoverySuccessfullyProcessedCaptureDigests"):
        value[key] = []
    return value


def pending():
    return {**baseline(), "queueCount": 1, "recoveryEncryptedQueueBytes": 128, "recoveryPendingCaptureDigests": [digest(2)]}


def recovered():
    return {**baseline(), "valueCount": 1, "occurrenceCount": 7,
        "recoveryOccurrenceDigests": [digest(3)], "recoveryReceiptDigests": [digest(4)],
        "recoveryConsumedCaptureDigests": [digest(2)], "recoverySuccessfullyProcessedCaptureDigests": [digest(2)]}


def make_database(root, rows=()):
    os.chmod(root, 0o700)
    path = root / "leakret.sqlite"
    connection = sqlite3.connect(path)
    connection.executescript("CREATE TABLE captures (id TEXT PRIMARY KEY, retry_count INTEGER, state INTEGER, encoded BLOB);"
        "CREATE TABLE capture_receipts (id TEXT PRIMARY KEY); CREATE TABLE unrelated (secret TEXT);")
    connection.executemany("INSERT INTO captures VALUES (?, ?, ?, ?)", [(*row, b"PRIVATE_ENCRYPTED_SENTINEL") for row in rows])
    connection.execute("INSERT INTO capture_receipts VALUES (?)", (CAPTURE,))
    connection.commit()
    connection.close()
    os.chmod(path, 0o600)
    return path


class ReaderRecoveryBoundaryTests(unittest.TestCase):
    def test_worker_has_no_automatic_source_or_profile_catchup(self):
        arguments = reader.worker_command(Path("/owned/Spillcheck"), Path("/private/tmp/owned"),
            selection={"home": Path("/exact/home"), "native": CAPTURE}, reader=Path("/private/tmp/owned/reader"),
            version="reader", host="host")
        self.assertIn("--acceptance-no-profile-catchup", arguments)
        self.assertIn("--acceptance-recovery-worker", arguments)
        for flag in ("--codex-active-thread", "--acceptance-cleanup-new-vault", "--acceptance-recovery-install-profile"):
            self.assertNotIn(flag, arguments)
        self.assertEqual(arguments[arguments.index("--codex-executable") + 1], "/private/tmp/owned/reader")
        self.assertEqual(arguments[arguments.index("--codex-authorized-host") + 1], "t3")

    def test_initial_empty_gate_rejects_prior_work_or_unverified_storage(self):
        self.assertTrue(reader.empty_ready(baseline()))
        for key, value in (("queueCount", False), ("valueCount", 1), ("occurrenceCount", 1),
                ("recoveryLoadedExistingManifest", False), ("recoveryManifestDigest", None),
                ("recoveryCaptureIdentityMeasurementAvailable", False), ("gapReasons", ["source-unavailable"]),
                ("coverageReportTruncated", True), ("recoveryReceiptDigests", [digest(3)]),
                ("recoveryConsumedCaptureDigests", [digest(2)])):
            with self.subTest(key=key):
                self.assertFalse(reader.empty_ready({**baseline(), key: value}))

    def test_retry_proof_requires_one_unclaimed_nonterminal_failed_capture(self):
        for retry_count in (1, 2):
            self.assertTrue(reader.failed_pending(pending(), baseline(), {"rows": [(CAPTURE, retry_count, 0)]}))
        for rows in ([], [(CAPTURE, 0, 0)], [(CAPTURE, 3, 0)], [(CAPTURE, True, 0)],
                [(CAPTURE, 1, False)], [(CAPTURE, 1, 1)], [(CAPTURE, 1, 0), (OTHER, 1, 0)]):
            with self.subTest(rows=rows):
                self.assertFalse(reader.failed_pending(pending(), baseline(), {"rows": rows}))
        for key, value in (("queueCount", True), ("queueCount", 2), ("recoveryQueueClaimedCount", 1),
                ("recoveryEncryptedQueueBytes", 0), ("recoveryEncryptedQueueBytes", True),
                ("recoveryPendingCaptureDigests", []), ("recoveryPendingCaptureDigests", [digest(2), digest(3)]),
                ("recoverySuccessfullyProcessedCaptureDigests", [digest(2)]), ("recoveryConsumedCaptureDigests", [digest(2)]),
                ("occurrenceCount", 1), ("recoveryManifestDigest", digest(9)), ("gapReasons", ["source-unavailable"])):
            with self.subTest(key=key):
                self.assertFalse(reader.failed_pending({**pending(), key: value}, baseline(), {"rows": [(CAPTURE, 1, 0)]}))
        self.assertFalse(reader.failed_pending({**pending(), "recoveryManifestDigest": None}, {}, {"rows": [(CAPTURE, 1, 0)]}))

    def test_recovery_needs_same_successful_capture_not_just_consumption(self):
        self.assertTrue(reader.shared.pending_recovered(pending(), recovered()))
        for value in ([], [digest(9)]):
            changed = {**recovered(), "recoverySuccessfullyProcessedCaptureDigests": value}
            self.assertFalse(reader.shared.pending_recovered(pending(), changed))

    def test_repeat_proof_requires_new_completion_and_identical_inventory(self):
        before = recovered()
        after = {**copy.deepcopy(before), "recoverySuccessfullyProcessedCaptureDigests": [digest(2), digest(5)]}
        self.assertTrue(reader.repeated_processing(before, after))
        self.assertFalse(reader.repeated_processing(before, before))
        for key, value in (("recoveryReceiptDigests", [digest(4), digest(8)]), ("recoveryOccurrenceDigests", [digest(8)]),
                ("recoveryAlertDigests", [digest(8)]), ("recoveryManifestDigest", digest(9)),
                ("queueCount", 1), ("queueCount", False), ("gapReasons", ["source-unavailable"]),
                ("recoverySuccessfullyProcessedCaptureDigests", [digest(5)])):
            with self.subTest(key=key):
                self.assertFalse(reader.repeated_processing(before, {**after, key: value}))

    def test_metadata_reads_only_bounded_rows_and_exact_receipt_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            database = make_database(root, [(CAPTURE, 1, 0)])
            original = database.read_bytes()
            result = reader.queue_metadata(root, CAPTURE)
            self.assertEqual(result, {"rows": [(CAPTURE, 1, 0)], "consumed": True})
            self.assertFalse(reader.queue_metadata(root, OTHER)["consumed"])
            self.assertEqual(database.read_bytes(), original)
            self.assertEqual({path.name for path in root.iterdir()}, {"leakret.sqlite"})
            self.assertNotIn("PRIVATE_ENCRYPTED_SENTINEL", repr(result))

    def test_authorizer_rejects_payloads_other_tables_and_mutations(self):
        with tempfile.TemporaryDirectory() as directory:
            database = make_database(Path(directory).resolve(), [(CAPTURE, 1, 0)])
            connection = sqlite3.connect(database)
            connection.set_authorizer(reader.metadata_authorizer)
            self.assertEqual(connection.execute("SELECT id, retry_count, state FROM captures LIMIT 2").fetchall(), [(CAPTURE, 1, 0)])
            for query in ("SELECT encoded FROM captures", "SELECT secret FROM unrelated", "DELETE FROM captures",
                    "UPDATE captures SET retry_count = 0", "PRAGMA journal_mode=WAL", "ATTACH ':memory:' AS other"):
                with self.subTest(query=query), self.assertRaises(sqlite3.DatabaseError):
                    connection.execute(query)
            connection.close()

    def test_metadata_can_read_writer_created_wal_without_modifying_database_or_wal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            database = make_database(root)
            writer = sqlite3.connect(database)
            try:
                self.assertEqual(writer.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
                writer.execute("INSERT INTO captures VALUES (?, 1, 0, ?)", (CAPTURE, b"ENCRYPTED_FAKE_ONLY"))
                writer.commit()
                wal = Path(str(database) + "-wal")
                before = (database.read_bytes(), wal.read_bytes())
                self.assertEqual(reader.queue_metadata(root, CAPTURE), {"rows": [(CAPTURE, 1, 0)], "consumed": True})
                self.assertEqual((database.read_bytes(), wal.read_bytes()), before)
            finally:
                writer.close()

    def test_database_boundary_rejects_multiple_or_malformed_capture_rows(self):
        for rows in ([(CAPTURE, 1, 0), (OTHER, 1, 0)], [("not-native", 1, 0)],
                [(CAPTURE, -1, 0)], [(CAPTURE, 4, 0)], [(CAPTURE, 1, 2)], [(CAPTURE, "bad", 0)]):
            with self.subTest(rows=rows), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                make_database(root, rows)
                with self.assertRaises((reader.GateFailure, ValueError)):
                    reader.queue_metadata(root)

    def test_database_boundary_rejects_aliases_links_and_public_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            store = root / "store"
            store.mkdir(mode=0o700)
            database = make_database(store)
            alias = root / "alias"
            alias.symlink_to(store)
            with self.assertRaises(reader.GateFailure):
                reader.queue_metadata(alias)
            os.chmod(database, 0o644)
            with self.assertRaises(reader.GateFailure):
                reader.queue_metadata(store)
            os.chmod(database, 0o600)
            hardlink = root / "hardlink"
            os.link(database, hardlink)
            with self.assertRaises(reader.GateFailure):
                reader.queue_metadata(store)
            hardlink.unlink()
            target = root / "target.sqlite"
            database.rename(target)
            database.symlink_to(target)
            with self.assertRaises(reader.GateFailure):
                reader.queue_metadata(store)

    def test_database_boundary_rejects_writerless_wal_and_view_indirection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            database = make_database(root)
            wal = Path(str(database) + "-wal")
            reader.shared.write_new(wal, b"fake")
            with self.assertRaises(reader.GateFailure):
                reader.queue_metadata(root)
            wal.unlink()
            connection = sqlite3.connect(database)
            connection.executescript("DROP TABLE captures; CREATE VIEW captures AS SELECT secret AS id, 1 AS retry_count, 0 AS state FROM unrelated;")
            connection.close()
            with self.assertRaises(sqlite3.DatabaseError):
                reader.queue_metadata(root)

    def test_reader_restoration_is_exclusive_and_never_mutates_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            os.chmod(root, 0o700)
            target = root / "real-reader"
            target.write_bytes(b"fake executable fixture")
            target.chmod(0o700)
            original = target.read_bytes()
            path = root / "reader"
            reader.restore_owned_reader(root, path, target)
            self.assertEqual(os.readlink(path), str(target))
            with self.assertRaises(reader.GateFailure):
                reader.restore_owned_reader(root, path, target)
            self.assertEqual(target.read_bytes(), original)
            path.unlink()
            with self.assertRaises(reader.GateFailure):
                reader.restore_owned_reader(root, root / "outside", target)
            target.chmod(0o600)
            with self.assertRaises(reader.GateFailure):
                reader.restore_owned_reader(root, path, target)

    def test_retry_wait_brackets_same_capture_identity(self):
        worker = SimpleNamespace(pump=Mock(), process=SimpleNamespace(poll=lambda: None))
        missing = SimpleNamespace(exists=lambda: False, is_symlink=lambda: False)
        row = {"rows": [(CAPTURE, 1, 0)]}
        with patch.object(reader, "queue_metadata", side_effect=[row, row]), \
                patch.object(reader.shared, "private_json", return_value=pending()):
            report, identifier, count = reader.wait_failed_capture(worker, Path("/owned"), baseline(), missing)
        self.assertEqual((identifier, count), (CAPTURE, 1))
        self.assertEqual(report, pending())
        with patch.object(reader, "queue_metadata", side_effect=[row, {"rows": [(OTHER, 1, 0)]}]), \
                patch.object(reader.shared, "private_json", return_value=pending()), \
                patch.object(reader.time, "monotonic", side_effect=[0, 0.1, 2]), \
                patch.object(reader.time, "sleep"), self.assertRaises(reader.GateFailure):
            reader.wait_failed_capture(worker, Path("/owned"), baseline(), missing, timeout=1)

    def test_retry_wait_never_restores_without_exact_failure_observation(self):
        worker = SimpleNamespace(pump=Mock(), process=SimpleNamespace(poll=lambda: None))
        present = SimpleNamespace(exists=lambda: True, is_symlink=lambda: False)
        with patch.object(reader, "queue_metadata") as metadata, self.assertRaises(reader.GateFailure):
            reader.wait_failed_capture(worker, Path("/owned"), baseline(), present)
        metadata.assert_not_called()
        busy = sqlite3.OperationalError("synthetic busy")
        busy.sqlite_errorcode = 5
        missing = SimpleNamespace(exists=lambda: False, is_symlink=lambda: False)
        with patch.object(reader, "queue_metadata", side_effect=busy), \
                patch.object(reader.time, "monotonic", side_effect=[0, 0.1, 2]), \
                patch.object(reader.time, "sleep"), self.assertRaises(reader.GateFailure):
            reader.wait_failed_capture(worker, Path("/owned"), baseline(), missing, timeout=1)

    def test_helper_failure_preserves_independent_process_cleanup_measurement(self):
        state = {"stopped": True}
        def completed_failure(*args, **kwargs):
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
            return 1, b"", b""
        with patch.object(reader.shared.live, "bounded", completed_failure), self.assertRaises(reader.GateFailure):
            reader.deliver(Path("/fake/helper"), Path("/private/tmp/fake"), b"fake", state)
        self.assertTrue(state["stopped"])
        with patch.object(reader.shared.live, "bounded", side_effect=TimeoutError), self.assertRaises(TimeoutError):
            reader.deliver(Path("/fake/helper"), Path("/private/tmp/fake"), b"fake", state)
        self.assertFalse(state["stopped"])


if __name__ == "__main__":
    unittest.main()
