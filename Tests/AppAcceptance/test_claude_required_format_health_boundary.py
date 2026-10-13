"""Offline boundaries for the constructed signed required-format health check."""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

spec = importlib.util.spec_from_file_location("claude_required_format_health_runner",
    Path(__file__).with_name("run-app-claude-required-format-health.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def observed(count, sessions=2):
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "recoveryCaptureIdentityMeasurementAvailable": True,
        "queueCount": 0, "recoveryQueueClaimedCount": 0, "recoveryPendingCaptureDigests": [],
        "coverageReportTruncated": False, "transportRejectionCountsByStageAndReason": {},
        "valueCount": 1, "occurrenceCount": count, "syntheticOccurrenceCount": count,
        "syntheticSessionCount": sessions, "syntheticValuePresent": True,
        "syntheticOccurrencesByContentType": {"userPrompt": count}, "observedAgentVersions": [runner.VERSION],
        "gapReasons": ["unsupportedContent"], "gapCountsByOperation": {"liveRead": {"unsupportedContent": 1}},
        "scopedGapCount": 1, "notificationState": "Allowed", "recoveryOmissionMeasurementAvailable": True,
        "recoveryOmissionTruncated": False,
        "recoveryOmissionRecords": [{"omissionDigest": digest(80), "state": "blocked", "reason": "unsupportedContent"}],
        "recoveryOccurrenceDigests": [digest(index) for index in range(2, count + 2)],
        "recoveryReceiptDigests": [digest(index) for index in range(12, count + 12)],
        "recoveryAlertDigests": [digest(30), digest(31)], "alertCount": 2,
        "recoveryConsumedCaptureDigests": [digest(40)], "recoverySuccessfullyProcessedCaptureDigests": [digest(40)]}


def database(root, rows):
    store = root / "protected-store"
    store.mkdir(mode=0o700, exist_ok=True)
    path = store / "leakret.sqlite"
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE collection_health_incidents (id TEXT, resolved_at REAL, delivery TEXT, requires_assessment INTEGER, encoded BLOB)")
        connection.executemany("INSERT INTO collection_health_incidents VALUES (?,?,?,?,?)",
            [(*row, b"FAKE_PRIVATE_ENCODED_BODY_NEVER_READ") for row in rows])
    path.chmod(0o600)
    return path


COLD = {"acceptancePhase": "shutdown-complete"}


def candidate_manifest(root):
    expected = {}
    for relative in runner.MASKED_SOURCES:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        data = ("fake reviewed source " + relative).encode()
        path.write_bytes(data)
        expected[relative] = hashlib.sha256(data).hexdigest()
    manifest = root / "candidate-build.json"
    manifest.write_text(json.dumps({"schemaVersion": 1, "bundleDigestFormat": runner.claude.preflight.DIGEST_FORMAT,
        "bundleSHA256": "a" * 64, "executableSHA256": "b" * 64, "sourceSHA256": expected}))
    manifest.chmod(0o644)
    binding = {"manifestSHA256": hashlib.sha256(manifest.read_bytes()).hexdigest()}
    return manifest, binding, expected


class ClaudeRequiredFormatHealthBoundaries(unittest.TestCase):
    def test_public_candidate_manifest_uses_schema_reader_without_changing_frozen_bytes_or_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); manifest, binding, expected = candidate_manifest(root)
            before = (manifest.read_bytes(), manifest.stat().st_mode, manifest.stat().st_mtime_ns)
            with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "MASKED_SOURCES", expected), \
                    mock.patch.object(runner.shared, "private_json", side_effect=AssertionError("private report reader used")):
                self.assertEqual(runner.masking_contract(manifest, binding), expected)
            self.assertEqual((manifest.read_bytes(), manifest.stat().st_mode, manifest.stat().st_mtime_ns), before)

    def test_manifest_must_remain_bound_to_original_candidate_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); manifest, binding, expected = candidate_manifest(root)
            with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "MASKED_SOURCES", expected):
                with self.assertRaises(runner.shared.GateFailure):
                    runner.masking_contract(manifest, {"manifestSHA256": "f" * 64})
                read = runner.claude.preflight.read_manifest
                def changed_after_read(path):
                    value = read(path)
                    path.write_bytes(path.read_bytes() + b"\n")
                    return value
                with mock.patch.object(runner.claude.preflight, "read_manifest", side_effect=changed_after_read):
                    with self.assertRaises(runner.shared.GateFailure):
                        runner.masking_contract(manifest, binding)

    def test_manifest_schema_and_exact_reviewed_source_digests_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); manifest, binding, expected = candidate_manifest(root)
            original = manifest.read_bytes()
            with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "MASKED_SOURCES", expected):
                for data in (b'{"schemaVersion":1,"sourceSHA256":{}}',
                        original.replace(b'"schemaVersion": 1', b'"schemaVersion": 1,"schemaVersion": 1')):
                    manifest.write_bytes(data)
                    with self.assertRaises(runner.claude.preflight.Invalid):
                        runner.masking_contract(manifest, {"manifestSHA256": hashlib.sha256(data).hexdigest()})
                manifest.write_bytes(original)
                (root / next(iter(expected))).write_text("changed fake contract")
                with self.assertRaises(runner.shared.GateFailure):
                    runner.masking_contract(manifest, binding)

    def test_linked_manifest_or_reviewed_source_cannot_enter_masking_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); manifest, binding, expected = candidate_manifest(root)
            linked = root / "linked.json"; linked.symlink_to(manifest)
            with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "MASKED_SOURCES", expected):
                with self.assertRaises(OSError):
                    runner.masking_contract(linked, binding)
                source = root / next(iter(expected)); parked = source.with_suffix(".parked")
                source.rename(parked); source.symlink_to(parked)
                with self.assertRaises(OSError):
                    runner.masking_contract(manifest, binding)

    def test_constructed_source_preserves_readable_sibling_and_unknown_required_block(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); sources = runner.restoration.create_sources(root)
            runner.append_fixture(root, sources["affected"], "AFFECTED_REQUIRED")
            affected = sources["affected"]["bytes"]
            runner.append_fixture(root, sources["healthy"], "HEALTHY_INITIAL")
            runner.append_fixture(root, sources["healthy"], "HEALTHY_PROGRESS")
            runner.append_fixture(root, sources["healthy"], "HEALTHY_AFTER_RESTART")
            self.assertEqual(sources["affected"]["path"].read_bytes(), affected)
            row = json.loads(affected)
            self.assertEqual([b["type"] for b in row["message"]["content"]], ["text", "future_required_output"])
            self.assertEqual(affected.count(runner.shared.TOKEN), 1)
            self.assertEqual(sources["healthy"]["bytes"].count(runner.shared.TOKEN), 3)
            self.assertEqual(len(sources["healthy"]["bytes"].splitlines()), 3)
            with self.assertRaises(runner.shared.GateFailure):
                runner.append_fixture(root, sources["affected"], "AFFECTED_REQUIRED")
            self.assertEqual(sources["affected"]["path"].read_bytes(), affected)

    def test_fixed_worker_has_two_selected_sources_without_notification_suppression(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); sources = runner.restoration.create_sources(root)
            for name in ("worker1", "worker2"):
                command = runner.worker_command(Path("/fake/signed-app"), root, sources, name)
                self.assertEqual(command.count("--claude-active-source"), 2)
                self.assertEqual(command.count("--claude-session"), 2)
                self.assertIn("--acceptance-no-profile-catchup", command)
                self.assertIn("--acceptance-recovery-worker", command)
                self.assertIn(str(root / (name + "-report.json")), command)
                self.assertFalse(any("inventory-state" in part or "cleanup-new-vault" in part
                    or "vault-owner" in part or "review" in part or "desktop-beta" in part for part in command))
            with self.assertRaises(runner.shared.GateFailure):
                runner.worker_command(Path("/fake"), root, sources, "arbitrary-worker")

    def test_exact_one_required_omission_and_nontruncated_measurement_are_required(self):
        value = observed(2)
        self.assertTrue(runner.observed(value, 2))
        for update in ({"recoveryOmissionMeasurementAvailable": False}, {"recoveryOmissionTruncated": True},
                {"recoveryOmissionRecords": []}, {"recoveryOmissionRecords": value["recoveryOmissionRecords"] * 2},
                {"gapReasons": []}, {"scopedGapCount": True}, {"gapCountsByOperation": {"historicalRead": {"unsupportedContent": 1}}},
                {"gapCountsByOperation": {"liveRead": {"unsupportedContent": True}}},
                {"queueCount": 1}, {"notificationState": "Denied"}, {"transportRejectionCountsByStageAndReason": {"admission": {"invalidMetadata": 1}}}):
            self.assertFalse(runner.observed({**value, **update}, 2), update)
        for key, changed in (("state", "retryable"), ("reason", "sourceUnavailable"), ("omissionDigest", "not-a-digest")):
            updated = copy.deepcopy(value); updated["recoveryOmissionRecords"][0][key] = changed
            self.assertFalse(runner.observed(updated, 2), key)

    def test_affected_single_sibling_can_commit_before_other_source_is_written(self):
        self.assertTrue(runner.observed(observed(1, 1), 1, 1))
        self.assertFalse(runner.observed(observed(1, 2), 1, 1))

    def test_health_progress_cannot_clear_replace_or_duplicate_original_omission(self):
        before, after = observed(2), observed(3)
        self.assertTrue(runner.growth(before, after, 2))
        changed = copy.deepcopy(after); changed["recoveryOmissionRecords"][0]["omissionDigest"] = digest(81)
        self.assertFalse(runner.growth(before, changed, 2))
        for key in ("recoveryOccurrenceDigests", "recoveryReceiptDigests"):
            for values in (before[key], after[key][1:] + [digest(99)], after[key] + [digest(99)]):
                self.assertFalse(runner.growth(before, {**after, key: values}, 2))
        self.assertFalse(runner.growth(before, {**after, "gapReasons": []}, 2))
        self.assertFalse(runner.growth(before, {**after, "alertCount": 3}, 2))
        self.assertFalse(runner.growth(before, {**after, "recoveryManifestDigest": digest(99)}, 2))

    def test_equal_counts_with_changed_receipts_or_omission_cannot_pass_restart(self):
        before = observed(3)
        self.assertTrue(runner.stable(before, copy.deepcopy(before), 3))
        for key in runner.shared.DIGEST_KEYS:
            self.assertFalse(runner.stable(before, {**before, key: [digest(99)]}, 3))
        changed = copy.deepcopy(before); changed["recoveryOmissionRecords"][0]["omissionDigest"] = digest(81)
        self.assertFalse(runner.stable(before, changed, 3))

    def test_poll_output_is_not_a_processing_witness_and_environment_has_no_auth(self):
        captured = {}
        def bounded(command, **kwargs):
            captured.update(command=command, **kwargs)
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
            return 0, b"{}\n", 0
        root = Path("/fake-owned")
        source = {"session": str(uuid.uuid4()), "path": root / "claude/projects/selected/fake.jsonl"}
        lifetime = {"stopped": True}
        with mock.patch.object(runner.shared.live, "bounded", side_effect=bounded):
            runner.deliver_poll(Path("/signed/helper"), root, source, lifetime)
        self.assertTrue(lifetime["stopped"])
        self.assertEqual(captured["environment"], {"PATH": "/usr/bin:/bin", "LANG": "C"})
        packet = json.loads(captured["input_bytes"])
        self.assertEqual(packet["transcript_path"], str(source["path"]))
        self.assertEqual(packet["hook_event_name"], "SpillcheckTranscriptPoll")
        self.assertFalse(runner.restoration.new_processed_read(observed(3), observed(3)))

    def test_failed_helper_lifetime_never_authorizes_creator_cleanup(self):
        def bounded(command, **kwargs):
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=True)
            return 0, b"{}", 0
        lifetime = {"stopped": True}
        with mock.patch.object(runner.shared.live, "bounded", side_effect=bounded):
            with self.assertRaises(runner.shared.GateFailure):
                runner.deliver_poll(Path("/signed/helper"), Path("/fake"), {"path": Path("/fake/source"), "session": "fake"}, lifetime)
        self.assertFalse(lifetime["stopped"])
        self.assertFalse(runner.shared.safe_creator_cleanup([
            {"exitCode": 0, "shutdownPhase": "shutdown-complete", "groupStopped": True}],
            helper_stopped=lifetime["stopped"], socket_absent=True))

    def test_cold_metadata_reads_only_four_health_fields_and_never_encoded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); identifier = str(uuid.uuid4())
            path = database(root, [(identifier, None, "delivered", 0)])
            reads = set(); original = runner.metadata_authorizer
            def authorizer(action, first, second, db, trigger):
                if action == sqlite3.SQLITE_READ:
                    reads.add((first, second))
                return original(action, first, second, db, trigger)
            with mock.patch.object(runner, "metadata_authorizer", side_effect=authorizer):
                rows = runner.health_metadata(root, COLD)
            self.assertEqual(rows, [(identifier, None, "delivered", 0)])
            self.assertEqual(reads, {("collection_health_incidents", key) for key in ("id", "resolved_at", "delivery", "requires_assessment")})
            with sqlite3.connect(path) as connection:
                connection.set_authorizer(runner.metadata_authorizer)
                with self.assertRaises(sqlite3.DatabaseError):
                    connection.execute("SELECT encoded FROM collection_health_incidents").fetchall()
                with self.assertRaises(sqlite3.DatabaseError):
                    connection.execute("DELETE FROM collection_health_incidents")

    def test_initial_empty_incident_inventory_and_receipt_states_do_not_claim_delivery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); database(root, [])
            self.assertEqual(runner.health_metadata(root, {"ownerReady": True, "createdFreshVault": True}), [])
        identifier = str(uuid.uuid4())
        self.assertTrue(runner.delivered_content_incident([(identifier, None, "delivered", 0)]))
        for rows in ([], [(identifier, None, "pending", 0)], [(identifier, None, "permissionDenied", 0)],
                [(identifier, 1, "delivered", 0)], [(identifier, None, "delivered", 1)],
                [(identifier, None, "delivered", 0)] * 2):
            self.assertFalse(runner.delivered_content_incident(rows))

    def test_multiple_incidents_and_invalid_metadata_fail_closed(self):
        for rows in ([(str(uuid.uuid4()), None, "delivered", 0)] * 2,
                [("not-uuid", None, "delivered", 0)], [(str(uuid.uuid4()), None, "arbitrary", 0)]):
            with self.subTest(rows=len(rows)), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); database(root, rows)
                with self.assertRaises((runner.shared.GateFailure, ValueError)):
                    runner.health_metadata(root, COLD)

    def test_live_socket_unknown_shutdown_or_nonempty_wal_prevents_metadata_read(self):
        for mode in ("live", "phase", "wal"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); path = database(root, [])
                report = COLD
                if mode == "live":
                    (path.parent / "capture.sock").touch()
                elif mode == "phase":
                    report = {"acceptancePhase": "working"}
                else:
                    wal = path.with_name(path.name + "-wal"); wal.write_bytes(b"not checkpointed"); wal.chmod(0o600)
                with mock.patch.object(runner.sqlite3, "connect", side_effect=AssertionError("must not open SQLite")):
                    with self.assertRaises(runner.shared.GateFailure):
                        runner.health_metadata(root, report)

    def test_metadata_rejects_symlink_fifo_hardlink_and_public_database(self):
        for mode in ("symlink", "fifo", "hardlink", "public"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); path = database(root, [])
                if mode == "public":
                    path.chmod(0o644)
                elif mode == "hardlink":
                    os.link(path, root / "alias")
                else:
                    original = root / "original"; path.rename(original)
                    if mode == "fifo": os.mkfifo(path)
                    else: path.symlink_to(original)
                with self.assertRaises((runner.shared.GateFailure, OSError)):
                    runner.health_metadata(root, COLD)

    def test_sqlite_uses_original_pinned_inode_when_store_path_is_substituted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); original_id, decoy_id = str(uuid.uuid4()), str(uuid.uuid4())
            database(root, [(original_id, None, "delivered", 0)])
            outside = root / "outside"; outside.mkdir()
            database(outside, [(decoy_id, None, "delivered", 0)])
            connect = sqlite3.connect; observed_ids = []
            def swapped_connect(database_uri, **kwargs):
                self.assertRegex(database_uri, r"^file:/dev/fd/[0-9]+\?mode=ro&immutable=1$")
                parked = root / "parked-store"
                (root / "protected-store").rename(parked)
                (outside / "protected-store").rename(root / "protected-store")
                try:
                    connection = connect(database_uri, **kwargs)
                    observed_ids.extend(row[0] for row in connection.execute("SELECT id FROM collection_health_incidents"))
                finally:
                    (root / "protected-store").rename(outside / "protected-store")
                    parked.rename(root / "protected-store")
                return connection
            with mock.patch.object(runner.sqlite3, "connect", side_effect=swapped_connect):
                rows = runner.health_metadata(root, COLD)
            self.assertEqual(observed_ids, [original_id])
            self.assertEqual(rows, [(original_id, None, "delivered", 0)])

    def test_database_mutation_during_projection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); path = database(root, [])
            connect = sqlite3.connect
            def changed_connect(database_uri, **kwargs):
                connection = connect(database_uri, **kwargs)
                os.utime(path, ns=(path.stat().st_atime_ns, path.stat().st_mtime_ns + 1000000))
                return connection
            with mock.patch.object(runner.sqlite3, "connect", side_effect=changed_connect):
                with self.assertRaises(runner.shared.GateFailure):
                    runner.health_metadata(root, COLD)

    def test_preflight_failure_never_launches_or_creates_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            args = SimpleNamespace(candidate_manifest=None, expected_bundle_sha256=None,
                app=root / "app", output=root / "report", private_control=root / "control")
            with mock.patch.object(runner.setup, "ReportProcess") as process, mock.patch.object(runner.restoration, "create_sources") as sources:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.run(args)
                process.assert_not_called(); sources.assert_not_called()


if __name__ == "__main__":
    unittest.main()
