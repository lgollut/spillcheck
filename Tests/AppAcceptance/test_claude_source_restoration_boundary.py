import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("claude_source_restoration_runner", Path(__file__).with_name("run-app-claude-source-restoration.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def digest(number):
    return base64.b64encode(bytes([number]) * 32).decode()


def observed(count, *, missing=False):
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "recoveryCaptureIdentityMeasurementAvailable": True,
        "queueCount": 0, "recoveryQueueClaimedCount": 0, "recoveryPendingCaptureDigests": [],
        "coverageReportTruncated": False, "transportRejectionCountsByStageAndReason": {},
        "valueCount": 1, "occurrenceCount": count, "syntheticOccurrenceCount": count,
        "syntheticSessionCount": 2, "syntheticValuePresent": True,
        "syntheticOccurrencesByContentType": {"userPrompt": count}, "observedAgentVersions": [runner.VERSION],
        "gapReasons": ["sourceUnavailable"] if missing else [],
        "recoveryOccurrenceDigests": [digest(index) for index in range(2, count + 2)],
        "recoveryReceiptDigests": [digest(index) for index in range(12, count + 12)],
        "recoveryAlertDigests": [digest(30)], "alertCount": 1,
        "recoveryConsumedCaptureDigests": [digest(40)], "recoverySuccessfullyProcessedCaptureDigests": [digest(40)]}


def restored(before):
    value = copy.deepcopy(before)
    value["gapReasons"] = []
    for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
        value[key].append(digest(41))
    return value


class ClaudeSourceRestorationBoundaryTests(unittest.TestCase):
    def test_fixture_uses_two_distinct_exact_empty_sources_and_no_provider_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = runner.create_sources(root)
            self.assertEqual(set(sources), {"affected", "healthy"})
            self.assertNotEqual(sources["affected"]["session"], sources["healthy"]["session"])
            for value in sources.values():
                self.assertEqual(value["path"].read_bytes(), b"")
                self.assertEqual(value["path"].stat().st_mode & 0o777, 0o600)
                self.assertEqual(value["path"].parent, root / "claude/projects/selected")
            command = runner.worker_command(Path("/signed/app"), root, sources)
            self.assertEqual(command.count("--claude-active-source"), 2)
            self.assertEqual(command.count("--claude-session"), 2)
            self.assertEqual(command.count("--claude-authorized-host"), 1)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertIn("--acceptance-recovery-worker", command)
            self.assertFalse(any("cleanup-new-vault" in item or "vault-owner" in item or "history-request" in item
                or "install-profile" in item or "role-evidence" in item or "codex" in item for item in command))
            self.assertFalse((root / "claude/settings.json").exists())

    def test_real_rename_restores_same_inode_mtime_and_bytes_then_only_appends_expected_row(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = runner.create_sources(root)
            affected, healthy = sources["affected"], sources["healthy"]
            runner.append_prompt(root, affected, "AFFECTED_INITIAL")
            runner.append_prompt(root, healthy, "HEALTHY_INITIAL")
            original = (affected["signature"], affected["bytes"])
            runner.move_original(affected)
            self.assertFalse(affected["path"].exists())
            self.assertEqual(runner.signature(affected["parked"]), original[0])
            runner.append_prompt(root, healthy, "HEALTHY_WHILE_MISSING")
            self.assertEqual(affected["parked"].read_bytes(), original[1])
            runner.move_original(affected, restore=True)
            self.assertEqual((runner.signature(affected["path"]), affected["path"].read_bytes()), original)
            runner.append_prompt(root, affected, "AFFECTED_AFTER_RESTORE")
            self.assertEqual(affected["signature"][:2], original[0][:2])
            self.assertTrue(affected["bytes"].startswith(original[1]))
            self.assertEqual(affected["bytes"].count(runner.shared.TOKEN), 2)
            self.assertEqual(healthy["bytes"].count(runner.shared.TOKEN), 2)
            self.assertFalse(affected["parked"].exists())
            rows = [json.loads(line) for line in affected["bytes"].splitlines()]
            self.assertEqual({row["sessionId"] for row in rows}, {affected["session"]})
            self.assertEqual(len({row["uuid"] for row in rows}), 2)

    def test_changed_symlink_hardlink_or_public_source_refuses_append(self):
        for mode in ("bytes", "symlink", "hardlink", "public"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                source = runner.create_sources(root)["affected"]
                if mode == "bytes":
                    source["path"].write_bytes(b"unexpected owned fake content")
                elif mode == "public":
                    os.chmod(source["path"], 0o644)
                else:
                    copy = root / "copy.jsonl"; copy.touch(mode=0o600)
                    if mode == "symlink":
                        source["path"].unlink(); source["path"].symlink_to(copy)
                    else:
                        copy.unlink(); os.link(source["path"], copy)
                with self.assertRaises((RuntimeError, OSError)):
                    runner.append_prompt(root, source, "AFFECTED_INITIAL")

    def test_rename_never_overwrites_a_new_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = runner.create_sources(root)["affected"]
            runner.append_prompt(root, source, "AFFECTED_INITIAL")
            source["parked"].write_bytes(b"other fake test bytes")
            with self.assertRaises(runner.shared.GateFailure):
                runner.move_original(source)
            self.assertEqual(source["parked"].read_bytes(), b"other fake test bytes")
            self.assertEqual(source["path"].read_bytes(), source["bytes"])

    def test_healthy_progress_must_keep_warning_and_restore_must_remove_only_that_warning(self):
        self.assertTrue(runner.observed(observed(2), 2))
        self.assertTrue(runner.observed(observed(3, missing=True), 3, missing=True))
        self.assertFalse(runner.observed(observed(3), 3, missing=True))
        before = observed(3, missing=True)
        after = restored(before)
        self.assertTrue(runner.unchanged_restoration(before, after))
        for update in ({"gapReasons": ["sourceUnavailable"]}, {"gapReasons": ["malformedSource"]},
                {"occurrenceCount": 4}, {"syntheticSessionCount": 1}, {"valueCount": 2},
                {"queueCount": 1}, {"transportRejectionCountsByStageAndReason": {"admission": {"invalidMetadata": 1}}}):
            self.assertFalse(runner.unchanged_restoration(before, {**after, **update}), update)

    def test_empty_collector_requires_empty_inventory_alerts_and_complete_coverage(self):
        empty = {**observed(0), "valueCount": 0, "alertCount": 0, "syntheticSessionCount": 0,
            "syntheticValuePresent": False, "syntheticOccurrencesByContentType": {},
            "recoveryAlertDigests": []}
        self.assertTrue(runner.empty_ready(empty))
        # The two selected empty files may already have completed ordinary polls.
        self.assertTrue(runner.empty_ready({**empty,
            "recoveryConsumedCaptureDigests": [digest(40), digest(41)],
            "recoverySuccessfullyProcessedCaptureDigests": [digest(40), digest(41)]}))
        for key in ("valueCount", "occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount"):
            self.assertFalse(runner.empty_ready({**empty, key: 1}), key)
            self.assertFalse(runner.empty_ready({**empty, key: False}), key)
        for key in runner.shared.DIGEST_KEYS:
            self.assertFalse(runner.empty_ready({**empty, key: [digest(99)]}), key)
            self.assertFalse(runner.empty_ready({**empty, key: None}), key)
        for update in ({"syntheticValuePresent": True}, {"syntheticOccurrencesByContentType": {"userPrompt": 0}},
                {"coverageReportTruncated": True}, {"gapReasons": ["sourceUnavailable"]}, {"queueCount": 1},
                {"transportRejectionCountsByStageAndReason": {"admission": {"invalidMetadata": 1}}}):
            self.assertFalse(runner.empty_ready({**empty, **update}), update)

    def test_each_prompt_adds_one_occurrence_and_receipt_without_replacing_existing_inventory(self):
        for count, missing in ((2, True), (3, False)):
            with self.subTest(count=count, missing=missing):
                before, after = observed(count, missing=missing), observed(count + 1, missing=missing)
                self.assertTrue(runner.prompt_growth(before, after, count, missing=missing))
                # Empty/ordinary polls can vary independently of new source content.
                after["recoveryConsumedCaptureDigests"] += [digest(41), digest(42)]
                after["recoverySuccessfullyProcessedCaptureDigests"] += [digest(41), digest(42)]
                self.assertTrue(runner.prompt_growth(before, after, count, missing=missing))
                for key in ("recoveryOccurrenceDigests", "recoveryReceiptDigests"):
                    replacements = (before[key], after[key][1:] + [digest(99)], after[key] + [digest(99)])
                    for values in replacements:
                        self.assertFalse(runner.prompt_growth(before, {**after, key: values}, count, missing=missing), key)
                    self.assertFalse(runner.prompt_growth({**before, key: before[key][1:]}, after,
                        count, missing=missing), key)
                for update in ({"recoveryManifestDigest": digest(99)}, {"alertCount": 2},
                        {"recoveryAlertDigests": [digest(99)]}, {"occurrenceCount": count},
                        {"gapReasons": [] if missing else ["sourceUnavailable"]}):
                    self.assertFalse(runner.prompt_growth(before, {**after, **update}, count, missing=missing), update)

    def test_equal_counts_without_fresh_completed_read_or_with_new_receipts_cannot_pass(self):
        before = observed(3, missing=True)
        after = restored(before)
        for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
            self.assertFalse(runner.unchanged_restoration(before, {**after, key: before[key]}))
            self.assertFalse(runner.unchanged_restoration(before, {**after, key: after[key] + [digest(42)]}))
        for key in (*runner.shared.DIGEST_KEYS, "recoveryManifestDigest"):
            changed = copy.deepcopy(after)
            changed[key] = digest(99) if key == "recoveryManifestDigest" else [digest(99)]
            self.assertFalse(runner.unchanged_restoration(before, changed))
        self.assertFalse(runner.same_alerts(before, {**after, "alertCount": 2}))

    def test_cleanup_reuses_only_creator_authority_and_requires_normal_worker_stop(self):
        valid = [{"exitCode": 0, "shutdownPhase": "shutdown-complete", "groupStopped": True}]
        self.assertTrue(runner.shared.safe_creator_cleanup(valid, helper_stopped=True, socket_absent=True))
        for field, value in (("exitCode", 1), ("shutdownPhase", "working"), ("groupStopped", False)):
            self.assertFalse(runner.shared.safe_creator_cleanup([{**valid[0], field: value}], helper_stopped=True, socket_absent=True))
        self.assertFalse(runner.shared.safe_creator_cleanup(valid, helper_stopped=True, socket_absent=False))

    def test_failed_candidate_prevents_source_or_app_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            args = SimpleNamespace(candidate_manifest=None, expected_bundle_sha256=None,
                app=root / "fake.app", output=root / "out.json", private_control=root / "control.json")
            with patch.object(runner.setup, "ReportProcess") as process, patch.object(runner, "create_sources") as source:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.run(args)
                process.assert_not_called(); source.assert_not_called()


if __name__ == "__main__":
    unittest.main()
