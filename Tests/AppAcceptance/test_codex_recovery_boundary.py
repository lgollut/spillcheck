import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("codex_recovery", Path(__file__).with_name("run-app-codex-recovery.py"))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

CHILD = "11111111-1111-4111-8111-111111111111"
ROOT_NATIVE = "22222222-2222-4222-8222-222222222222"
COUNTS = {"userPrompt": 3, "intermediateResponse": 1, "finalResponse": 1, "toolOutput": 1, "toolError": 1}
BUNDLE = "a" * 64


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def report():
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "syntheticOccurrencesByContentType": dict(COUNTS),
        "syntheticOccurrenceCount": 7, "occurrenceCount": 7, "valueCount": 1, "syntheticSessionCount": 1,
        "observedAgentVersions": ["producer"], "gapReasons": [], "coverageReportTruncated": False,
        "recoveryOccurrenceDigests": [digest(2)], "recoveryReceiptDigests": [digest(3)], "recoveryAlertDigests": [],
        "recoveryCaptureIdentityMeasurementAvailable": True, "queueCount": 0, "recoveryQueueClaimedCount": 0,
        "recoveryPendingCaptureDigests": [], "recoveryConsumedCaptureDigests": [digest(4)],
        "recoverySuccessfullyProcessedCaptureDigests": [digest(4)]}


def proofs():
    return {
        "native-identity.json": {"threadID": CHILD, "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID",
            "cwd": "/synthetic/repo", "sourceEnumerationPerformed": False,
            "homeSource": "CODEX_HOME", "home": "/synthetic/home"},
        "t3-task-terminal.json": {"status": "completed", "hasPendingChildRuns": False,
            "providerInstanceId": "codex", "hostVersion": "host", "model": "inherited-model"},
        "t3-lineage.json": {"source": "t3_thread_read", "creationSource": "mcp", "createdBy": "agent",
            "relationshipToParent": "subagent", "providerInstanceId": "codex", "model": "inherited-model",
            "status": "completed", "runCount": 1, "pendingRequestCount": 0, "worktreeIsExpected": True,
            "isExactCreatedChild": True, "parentMatchesCurrent": True},
        "t3-live-overlap.json": {"observerTaskLifetimeOverlapEstablished": True, "firstCanonicalReadBeforeTaskCompletion": True},
        "observer-report.json": {"passed": True, "hostVersion": "host", "readerVersion": "reader",
            "candidateBundleSHA256": BUNDLE, "sourceEnumerationPerformed": False, "selectedThreadCount": 1,
            "producerCompletedSignal": True, "waitIdentityMatched": True, "ownedObserverGroupsStopped": True,
            "observerBinaryUnchanged": True, "candidateExecutableUnchanged": True,
            "pipeline": {"typedCommitted": dict(recovery.MARKERS), "typedCommittedBeforeCatchUp": dict(recovery.MARKERS),
                "typedCommittedByRole": {"parent": dict(recovery.MARKERS), "child": {}},
                "nativeSourceRoles": {"primarySessionCount": 1, "verifiedPrimarySessionCount": 1,
                    "nativeLinkedChildSessionCount": 0, "verifiedNativeLinkedChildSessionCount": 0},
                "sessionCount": 1, "queueCount": 0, "gapReasons": [], "replayStable": True,
                "ciphertextMarkerInspectionPassed": True, "actualReaderVersion": "reader",
                "observedProducerVersions": ["producer"], "interface": "t3", "hostVersion": "host",
                "occurrencesByContentType": dict(COUNTS), "occurrenceCount": 7}},
        "signed-summary.json": {"passed": True, "signedSelectedSourceAcceptance": True,
            "candidateBundleSHA256": BUNDLE, "candidateBundleUnchanged": True, "actualReaderVersion": "reader",
            "observedProducerVersions": ["producer"], "hostVersion": "host", "actualOccurrencesByContentType": dict(COUNTS),
            "actualOccurrenceCount": 7, "actualSyntheticSessionCount": 1, "newVaultCleanupPassed": True, "cleanupPending": False},
        "candidate-build.json": {"bundleSHA256": BUNDLE},
    }


def validate(value, root=ROOT_NATIVE):
    return recovery.validate_proofs(value, root_native=root, host="host", reader="reader", producer="producer",
        bundle=BUNDLE, cwd=Path("/synthetic/repo"))


class CodexRecoveryBoundaryTests(unittest.TestCase):
    @staticmethod
    def report_process(exit_code=None):
        process = recovery.OwnedProcess.__new__(recovery.OwnedProcess)
        process.process = SimpleNamespace(poll=lambda: exit_code)
        process.pump = Mock()
        return process

    def test_exact_owned_selection_requires_all_independent_proofs(self):
        selected = validate(proofs())
        self.assertEqual(selected["native"], CHILD)
        self.assertEqual(selected["counts"], COUNTS)
        for name in recovery.PROOFS:
            changed = proofs()
            del changed[name]
            with self.subTest(name=name), self.assertRaises((recovery.GateFailure, KeyError)):
                validate(changed)
        mutations = [
            ("native-identity.json", "nativeIdentitySource", "task-id-guess"),
            ("native-identity.json", "cwd", "/unrelated"), ("native-identity.json", "home", "relative"),
            ("native-identity.json", "sourceEnumerationPerformed", True),
            ("t3-task-terminal.json", "hasPendingChildRuns", True),
            ("t3-task-terminal.json", "providerInstanceId", "claude-code"),
            ("t3-lineage.json", "parentMatchesCurrent", False), ("t3-lineage.json", "runCount", True),
            ("t3-lineage.json", "model", "other-model"), ("t3-lineage.json", "isExactCreatedChild", False),
            ("observer-report.json", "passed", False), ("observer-report.json", "candidateBundleSHA256", "b" * 64),
            ("signed-summary.json", "cleanupPending", True), ("signed-summary.json", "actualOccurrenceCount", 9),
            ("t3-live-overlap.json", "firstCanonicalReadBeforeTaskCompletion", False),
        ]
        for name, key, value in mutations:
            changed = proofs()
            changed[name][key] = value
            with self.subTest(name=name, key=key), self.assertRaises(recovery.GateFailure):
                validate(changed)
        for root in (None, CHILD, "not-native"):
            with self.subTest(root=root), self.assertRaises((recovery.GateFailure, ValueError)):
                validate(proofs(), root=root)

    def test_counts_come_from_observer_and_cannot_pool_missing_types(self):
        for value in ({}, {"userPrompt": 7}, {**COUNTS, "toolError": True}, {**COUNTS, "toolError": 0}):
            with self.assertRaises(recovery.GateFailure):
                recovery.checked_counts(value)
        changed = proofs()
        changed["observer-report.json"]["pipeline"]["typedCommitted"]["SHELL_ERROR"] = 0
        with self.assertRaises(recovery.GateFailure):
            validate(changed)

    def test_collection_requires_exact_durable_counts_versions_and_no_gaps(self):
        original = report()
        self.assertTrue(recovery.collected(original, COUNTS, "producer"))
        for key, value in [("recoveryLoadedExistingManifest", False), ("syntheticSessionCount", True),
            ("valueCount", 2), ("syntheticOccurrenceCount", 8), ("observedAgentVersions", ["other"]),
            ("gapReasons", ["source-unavailable"]), ("coverageReportTruncated", True),
            ("recoveryReceiptDigests", []), ("recoveryManifestDigest", None)]:
            with self.subTest(key=key):
                self.assertFalse(recovery.collected({**original, key: value}, COUNTS, "producer"))

    def test_pending_gate_requires_new_singleton_after_processing_barrier(self):
        baseline = report()
        pending = {**baseline, "recoveryProcessingStopped": True, "queueCount": 1,
            "recoveryEncryptedQueueBytes": 128, "recoveryPendingCaptureDigests": [digest(5)]}
        self.assertTrue(recovery.singleton_pending(pending, baseline))
        for key, value in [("recoveryProcessingStopped", False), ("queueCount", 0), ("queueCount", True),
            ("queueCount", 2), ("recoveryQueueClaimedCount", 1), ("recoveryEncryptedQueueBytes", 0),
            ("recoveryCaptureIdentityMeasurementAvailable", False), ("recoveryPendingCaptureDigests", []),
            ("recoveryPendingCaptureDigests", [digest(4)]), ("recoveryPendingCaptureDigests", [digest(5), digest(6)])]:
            with self.subTest(key=key, value=value):
                self.assertFalse(recovery.singleton_pending({**pending, key: value}, baseline))

    def test_consumed_does_not_mean_successful_processing(self):
        stopped = {"recoveryPendingCaptureDigests": [digest(5)]}
        recovered = {**report(), "recoveryConsumedCaptureDigests": [digest(4), digest(5)],
            "recoverySuccessfullyProcessedCaptureDigests": [digest(5)]}
        self.assertTrue(recovery.pending_recovered(stopped, recovered))
        for key, value in [("recoverySuccessfullyProcessedCaptureDigests", []),
            ("recoverySuccessfullyProcessedCaptureDigests", [digest(6)]), ("recoveryConsumedCaptureDigests", []),
            ("recoveryPendingCaptureDigests", [digest(5)]), ("queueCount", 1), ("queueCount", False),
            ("recoveryQueueClaimedCount", 1), ("recoveryCaptureIdentityMeasurementAvailable", False)]:
            with self.subTest(key=key):
                self.assertFalse(recovery.pending_recovered(stopped, {**recovered, key: value}))

    def test_shutdown_and_pause_barriers_require_an_empty_unclaimed_queue(self):
        original = report()
        self.assertTrue(recovery.empty_unclaimed_queue(original))
        for key, value in [("queueCount", 1), ("queueCount", False), ("recoveryQueueClaimedCount", 1),
            ("recoveryPendingCaptureDigests", [digest(5)]), ("recoveryPendingCaptureDigests", None),
            ("recoveryCaptureIdentityMeasurementAvailable", False)]:
            with self.subTest(key=key, value=value):
                self.assertFalse(recovery.empty_unclaimed_queue({**original, key: value}))

    def test_restart_preserves_exact_sets_not_just_counts_or_supersets(self):
        original = report()
        self.assertTrue(recovery.inventory_unchanged(original, copy.deepcopy(original)))
        for key in recovery.DIGEST_KEYS:
            for replacement in ([digest(8)], original[key] + [digest(8)]):
                with self.subTest(key=key):
                    self.assertFalse(recovery.inventory_unchanged(original, {**original, key: replacement}))
        self.assertFalse(recovery.inventory_unchanged(original, {**original, "recoveryManifestDigest": digest(9)}))
        for value in (["private arbitrary text"], [digest(2), digest(2)], None):
            self.assertIsNone(recovery.digest_set({"test": value}, "test"))

    def test_only_clean_shutdown_authorizes_fresh_creator_cleanup(self):
        worker = {"exitCode": 0, "shutdownPhase": "shutdown-complete", "groupStopped": True}
        self.assertTrue(recovery.safe_creator_cleanup([worker, worker], helper_stopped=True, socket_absent=True))
        for changes in ({"exitCode": -9}, {"exitCode": False}, {"shutdownPhase": "stopping-scanner"}, {"groupStopped": False}):
            self.assertFalse(recovery.safe_creator_cleanup([worker, {**worker, **changes}], helper_stopped=True, socket_absent=True))
        self.assertFalse(recovery.safe_creator_cleanup([worker], helper_stopped=False, socket_absent=True))
        self.assertFalse(recovery.safe_creator_cleanup([worker], helper_stopped=True, socket_absent=False))

    def test_worker_commands_never_install_profiles_or_delete_loaded_keys(self):
        root = Path("/private/tmp/owned")
        arguments = recovery.command(Path("/owned/Spillcheck"), root, "worker1",
            selection={"home": Path("/original/home"), "native": CHILD}, reader=Path("/owned/codex"), version="reader", host="host")
        for flag in ("--acceptance-recovery-worker", "--acceptance-no-profile-catchup"):
            self.assertIn(flag, arguments)
        for flag in ("--acceptance-cleanup-new-vault", "--acceptance-recovery-install-profile", "--acceptance-vault-owner"):
            self.assertNotIn(flag, arguments)
        self.assertEqual(arguments[arguments.index("--codex-active-thread") + 1], CHILD)
        self.assertEqual(arguments.count("--codex-active-thread"), 1)
        self.assertEqual(arguments[arguments.index("--codex-authorized-host") + 1], "t3")
        for name in ("worker2", "worker3"):
            paused = recovery.command(Path("/owned/Spillcheck"), root, name, active=False,
                selection={"home": Path("/original/home"), "native": CHILD}, reader=Path("/owned/codex"), version="reader", host="host")
            self.assertNotIn("--codex-active-thread", paused)
            self.assertNotIn(CHILD, paused)
            self.assertIn("--acceptance-no-profile-catchup", paused)
            self.assertIn("--acceptance-recovery-worker", paused)
        owner = recovery.command(Path("/owned/Spillcheck"), root, "owner")
        self.assertIn("--acceptance-vault-owner", owner)
        self.assertNotIn("--codex-profile", owner)

    def test_private_reads_are_bounded_owned_and_no_follow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "proof.json"
            recovery.write_json(source, {"owned": True})
            self.assertEqual(recovery.private_json(source), {"owned": True})
            with self.assertRaises(FileExistsError):
                recovery.write_json(source, {})
            alias = root / "alias.json"
            alias.symlink_to(source)
            with self.assertRaises(OSError):
                recovery.private_json(alias)
            os.chmod(source, 0o644)
            with self.assertRaises(recovery.GateFailure):
                recovery.private_json(source)
            os.chmod(source, 0o600)
            with self.assertRaises(recovery.GateFailure):
                recovery.private_bytes(source, limit=1)
            source.write_text('{"key":1,"key":2}')
            with self.assertRaises(recovery.GateFailure):
                recovery.private_json(source)

    def test_report_replacement_never_passes_unsafe_snapshot_to_predicate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            recovery.write_json(path, {"ready": True, "unsafe": True})
            os.chmod(path, 0o644)
            clock = [0.0]

            def replace_after_wait(duration):
                clock[0] += duration
                replacement = path.with_name("replacement.json")
                recovery.write_json(replacement, {"ready": True, "private": True})
                os.replace(replacement, path)

            predicate = Mock(side_effect=lambda row: row.get("ready") is True)
            process = self.report_process()
            with patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(recovery.time, "sleep", side_effect=replace_after_wait):
                result = process.wait_report(path, predicate, "not-ready")
            self.assertEqual(result, {"ready": True, "private": True})
            predicate.assert_called_once_with(result)
            self.assertEqual(process.pump.call_count, 2)

    def test_changed_or_incomplete_report_retries_with_no_stale_predicate_input(self):
        clock = [0.0]
        predicate = Mock(side_effect=lambda row: row.get("ready") is True)
        with patch.object(recovery, "private_json", side_effect=[
                recovery.GateFailure("private-file-changed"), {"ready": False},
                json.JSONDecodeError("replaced", "", 0), {"ready": True}]), \
                patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(recovery.time, "sleep", side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)):
            result = self.report_process().wait_report(Path("/owned/report"), predicate, "not-ready")
        self.assertEqual(result, {"ready": True})
        self.assertEqual(predicate.call_args_list, [unittest.mock.call({"ready": False}), unittest.mock.call(result)])

    def test_stable_unsafe_reports_fail_within_short_snapshot_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            recovery.write_json(target, {"ready": True})
            unsafe_mode = root / "mode.json"
            recovery.write_json(unsafe_mode, {"ready": True})
            os.chmod(unsafe_mode, 0o644)
            symlink = root / "symlink.json"
            symlink.symlink_to(target)
            hardlink = root / "hardlink.json"
            os.link(target, hardlink)
            for path in (unsafe_mode, symlink, hardlink):
                with self.subTest(path=path.name):
                    clock = [0.0]
                    predicate = Mock(return_value=True)
                    process = self.report_process()
                    with patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                            patch.object(recovery.time, "sleep", side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)):
                        with self.assertRaises(recovery.GateFailure) as error:
                            process.wait_report(path, predicate, "not-ready", timeout=40)
                    self.assertEqual(error.exception.gate, "private-report-snapshot-unavailable")
                    self.assertLess(clock[0], 2.1)
                    predicate.assert_not_called()

    def test_report_disappearance_after_observation_stays_bounded(self):
        for first in ({"ready": False}, recovery.GateFailure("private-file-boundary")):
            with self.subTest(first=first):
                clock = [0.0]
                reads = [first]
                def read(_):
                    if reads:
                        value = reads.pop()
                        if isinstance(value, Exception):
                            raise value
                        return value
                    raise FileNotFoundError()
                predicate = Mock(side_effect=lambda row: row.get("ready") is True)
                with patch.object(recovery, "private_json", side_effect=read), \
                        patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(recovery.time, "sleep", side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)):
                    with self.assertRaises(recovery.GateFailure) as error:
                        self.report_process().wait_report(Path("/owned/report"), predicate, "not-ready")
                self.assertEqual(error.exception.gate, "private-report-snapshot-unavailable")
                self.assertLess(clock[0], 2.2)
                self.assertEqual(predicate.call_args_list, [] if isinstance(first, Exception) else [unittest.mock.call(first)])

    def test_report_creation_uses_stage_deadline_then_requires_private_snapshot(self):
        clock = [0.0]
        def read(_):
            if clock[0] < 5:
                raise FileNotFoundError()
            return {"ready": True}
        predicate = Mock(side_effect=lambda row: row.get("ready") is True)
        with patch.object(recovery, "private_json", side_effect=read), \
                patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(recovery.time, "sleep", side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)):
            self.assertEqual(self.report_process().wait_report(Path("/owned/report"), predicate, "not-ready"), {"ready": True})
        predicate.assert_called_once_with({"ready": True})
        clock[0] = 0
        with patch.object(recovery, "private_json", side_effect=FileNotFoundError()), \
                patch.object(recovery.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(recovery.time, "sleep", side_effect=lambda duration: clock.__setitem__(0, clock[0] + duration)):
            with self.assertRaises(recovery.GateFailure) as error:
                self.report_process().wait_report(Path("/owned/report"), predicate, "not-ready", timeout=1)
        self.assertEqual(error.exception.gate, "not-ready")

    def test_unavailable_report_does_not_hide_process_exit_or_structural_failure(self):
        for unavailable in (FileNotFoundError(), recovery.GateFailure("private-file-boundary"),
                recovery.GateFailure("private-file-changed"), json.JSONDecodeError("invalid", "", 0)):
            with self.subTest(unavailable=type(unavailable).__name__):
                predicate = Mock(return_value=True)
                with patch.object(recovery, "private_json", side_effect=unavailable), patch.object(recovery.time, "sleep") as sleep:
                    with self.assertRaises(recovery.GateFailure) as error:
                        self.report_process(exit_code=0).wait_report(Path("/owned/report"), predicate, "worker-exited")
                self.assertEqual(error.exception.gate, "worker-exited")
                predicate.assert_not_called()
                sleep.assert_not_called()
        for gate in ("duplicate-json-key", "private-object-required"):
            with patch.object(recovery, "private_json", side_effect=recovery.GateFailure(gate)), \
                    patch.object(recovery.time, "sleep") as sleep:
                with self.assertRaises(recovery.GateFailure) as error:
                    self.report_process().wait_report(Path("/owned/report"), lambda _: True, "not-ready")
            self.assertEqual(error.exception.gate, gate)
            sleep.assert_not_called()

    def test_successful_report_after_clean_exit_is_available_for_shutdown_checks(self):
        with patch.object(recovery, "private_json", return_value={"shutdown": True}):
            self.assertEqual(self.report_process(exit_code=0).wait_report(Path("/owned/report"),
                lambda row: row.get("shutdown") is True, "not-ready"), {"shutdown": True})


if __name__ == "__main__":
    unittest.main()
