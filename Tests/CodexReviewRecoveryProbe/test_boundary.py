import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("recovery_probe", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
INPUT = {"textSHA256": "a" * 64, "textBytes": 645}
OUTPUT = {"textSHA256": "b" * 64, "textBytes": 120}


def report(stage="resume"):
    value = {key: True for key in probe.COMMON_CHECKS}
    value.update({key: False for key in probe.LIMITS})
    value.update({key: 0 for key in probe.COUNTS})
    value.update(schemaVersion=1, stage=stage, passed=True, parserContract=probe.PARSER,
        readerVersion=probe.VERSION, producerVersion=probe.VERSION, detectorVersion=probe.DETECTOR,
        scannerSHA256=probe.SCANNER_SHA, rulesSHA256=probe.RULES_SHA,
        cryptoScope="disposable-deterministic-test-keys", inputTextSHA256=INPUT["textSHA256"],
        inputTextBytes=INPUT["textBytes"], outputTextSHA256=OUTPUT["textSHA256"], outputTextBytes=OUTPUT["textBytes"],
        checks={key: True for key in probe.STAGE_CHECKS[stage]}, threadReadCalls=3, itemReadCalls=20,
        turnReadCalls=12, cursorCalls=5, exactTurnCalls=4, analysisReceiptCount=2, occurrenceCount=2, sourceCount=2, valueCount=1)
    if stage == "queue":
        value.update(queueCount=1, gapCount=1, detectorScanCalls=1, queueInspectionKind="entry",
                     analysisReceiptCount=1, occurrenceCount=1, sourceCount=1)
    elif stage == "resume":
        value["detectorScanCalls"] = 1
    return value


class RecoveryBoundaryTests(unittest.TestCase):
    def test_fixture_is_fake_only_and_does_not_change_original_probe(self):
        original = probe.load("unchanged_review_probe", probe.ROOT / "Tests/CodexReviewProbe/run.py")
        self.assertNotIn(probe.FAKE_TOKEN, original.INSTRUCTIONS)
        self.assertEqual(probe.producer.INSTRUCTIONS.count(probe.FAKE_TOKEN), 1)
        self.assertEqual(probe.producer.INSTRUCTIONS.count(probe.producer.MARKER), 1)
        self.assertIn("Do not use tools", probe.producer.INSTRUCTIONS)
        self.assertIn("There are no repository changes to inspect", probe.producer.INSTRUCTIONS)

    def test_each_worker_requires_complete_current_evidence(self):
        for stage in probe.STAGES:
            self.assertTrue(probe.stage_gate(report(stage), stage, INPUT, OUTPUT))
            for key in probe.COMMON_CHECKS | {"passed"}:
                for bad in (False, None, "true", 1):
                    value = report(stage); value[key] = bad
                    with self.subTest(stage=stage, key=key, bad=bad):
                        self.assertFalse(probe.stage_gate(value, stage, INPUT, OUTPUT))

    def test_unsigned_fixture_cannot_claim_other_acceptance(self):
        for key in probe.LIMITS:
            for bad in (True, None, 0, "false"):
                value = report(); value[key] = bad
                with self.subTest(key=key, bad=bad):
                    self.assertFalse(probe.stage_gate(value, "resume", INPUT, OUTPUT))

    def test_stage_specific_checks_cannot_be_substituted(self):
        for stage in probe.STAGES:
            for key in probe.STAGE_CHECKS[stage]:
                for bad in (False, None, 1, "true"):
                    value = report(stage); value["checks"][key] = bad
                    with self.subTest(stage=stage, key=key, bad=bad):
                        self.assertFalse(probe.stage_gate(value, stage, INPUT, OUTPUT))
            for other in probe.STAGES:
                if other != stage:
                    self.assertFalse(probe.stage_gate(report(other), stage, INPUT, OUTPUT))

    def test_original_bytes_versions_scanner_and_scope_are_bound(self):
        changes = {"inputTextSHA256": "c" * 64, "outputTextSHA256": "c" * 64,
            "inputTextBytes": 1, "outputTextBytes": 1, "parserContract": "old",
            "readerVersion": "old", "producerVersion": "old", "detectorVersion": "fake-detector",
            "scannerSHA256": "0" * 64, "rulesSHA256": "0" * 64, "cryptoScope": "keychain"}
        for key, bad in changes.items():
            value = report(); value[key] = bad
            with self.subTest(key=key): self.assertFalse(probe.stage_gate(value, "resume", INPUT, OUTPUT))

    def test_report_rejects_bool_counters_and_missing_or_unbounded_counts(self):
        for key in probe.COUNTS | {"schemaVersion", "inputTextBytes", "outputTextBytes"}:
            for bad in (True, False, -1, 1_000_001, "2", 2.0, None):
                value = report(); value[key] = bad
                with self.subTest(key=key, bad=bad):
                    self.assertFalse(probe.stage_gate(value, "resume", INPUT, OUTPUT))

    def test_gap_and_duplicates_cannot_pass_as_complete(self):
        for stage in ("resume", "replay"):
            for key, bad in {"gapCount": 1, "queueCount": 1, "analysisReceiptCount": 3,
                             "sourceCount": 4, "occurrenceCount": 4, "valueCount": 2,
                             "threadListCalls": 1, "threadReadCalls": 0,
                             "itemReadCalls": 1, "turnReadCalls": 0, "cursorCalls": 0, "exactTurnCalls": 0}.items():
                value = report(stage); value[key] = bad
                with self.subTest(stage=stage, key=key):
                    self.assertFalse(probe.stage_gate(value, stage, INPUT, OUTPUT))
        value = report("replay"); value["detectorScanCalls"] = 1
        self.assertFalse(probe.stage_gate(value, "replay", INPUT, OUTPUT))

    def test_queue_requires_one_durable_pending_work_and_actual_warning(self):
        for key, bad in {"queueCount": 0, "gapCount": 0, "detectorScanCalls": 3}.items():
            value = report("queue"); value[key] = bad
            with self.subTest(key=key): self.assertFalse(probe.stage_gate(value, "queue", INPUT, OUTPUT))

    def test_queue_purposeful_first_page_is_sufficient_and_kind_is_bound(self):
        value = report("queue"); value.update(itemReadCalls=1, turnReadCalls=1)
        self.assertTrue(probe.stage_gate(value, "queue", INPUT, OUTPUT))
        value["turnReadCalls"] = 0
        self.assertFalse(probe.stage_gate(value, "queue", INPUT, OUTPUT))
        value.update(queueInspectionKind="exit", itemReadCalls=2)
        self.assertTrue(probe.stage_gate(value, "queue", INPUT, OUTPUT))
        for kind in (None, "unknown", "private", 1):
            value["queueInspectionKind"] = kind
            self.assertFalse(probe.stage_gate(value, "queue", INPUT, OUTPUT))

    def test_public_output_is_closed_and_never_includes_private_native_data(self):
        value = report(); value.update(nativeText="private", nativeID="private", failureStage="private")
        value["checks"]["private"] = "private"
        self.assertNotIn("private", json.dumps(probe.public_stage(value)))
        self.assertEqual(probe.public_stage([]), {})
        for key in ("inputTextSHA256", "outputTextSHA256", "scannerSHA256", "rulesSHA256"):
            value = report(); value[key] = "private"
            self.assertNotIn(key, probe.public_stage(value))

    def test_other_opt_in_probes_are_removed_from_worker_environment(self):
        with patch.dict(os.environ, {"SPILLCHECK_OTHER_PROBE_HOME": "/personal", "VISIBLE_SAFE": "kept"}):
            value = probe.clean_env()
        self.assertNotIn("SPILLCHECK_OTHER_PROBE_HOME", value)
        self.assertEqual(value["VISIBLE_SAFE"], "kept")

    def test_build_manifest_binds_sources_and_compiled_test_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = SimpleNamespace(build_binding=root / "binding.json", scratch_path=root / "scratch")
            binding = {"schemaVersion": 1, "inputsStableAcrossBuild": True, "parserContract": probe.PARSER,
                "scratchPath": str(args.scratch_path.resolve()), "sources": {"s": "a"}, "artifacts": {"b": "b"}}
            probe.write_json(args.build_binding, binding)
            with patch.object(probe, "source_hashes", return_value={"s": "a"}), \
                 patch.object(probe, "artifact_hashes", return_value={"b": "b"}):
                self.assertEqual(probe.verify_build(args), probe.digest(probe.private_bytes(args.build_binding)))
            for sources, artifacts in [({"s": "changed"}, {"b": "b"}), ({"s": "a"}, {"b": "changed"})]:
                with patch.object(probe, "source_hashes", return_value=sources), \
                     patch.object(probe, "artifact_hashes", return_value=artifacts), self.assertRaises(probe.ProbeFailure):
                    probe.verify_build(args)

    def test_group_cleanup_must_be_confirmed(self):
        self.assertTrue(probe.stopped({"leaderExited": True, "groupKillPermissionDenied": False, "ownedGroupAbsent": True}))
        for cleanup in ({}, {"leaderExited": True}, {"leaderExited": True, "groupKillPermissionDenied": True},
                        {"leaderExited": 1, "groupKillPermissionDenied": False, "ownedGroupAbsent": True},
                        {"leaderExited": True, "groupKillPermissionDenied": False},
                        {"leaderExited": True, "groupKillPermissionDenied": False, "ownedGroupAbsent": False}):
            self.assertFalse(probe.stopped(cleanup))

    def test_group_absence_is_observed_not_assumed_after_kill_request(self):
        with patch.object(probe.os, "killpg", side_effect=[None, ProcessLookupError()]), \
             patch.object(probe.time, "sleep"):
            self.assertTrue(probe.group_absent(42))
        with patch.object(probe.os, "killpg", return_value=None):
            self.assertFalse(probe.group_absent(42, timeout=0))
        with patch.object(probe.os, "killpg", side_effect=PermissionError()):
            self.assertFalse(probe.group_absent(42))

    def run_fixture(self, directory, *, producer_failure=False, denied_worker=False):
        root = Path(directory)
        fixture = root / "spillcheck-native-review-recovery-fake"
        fixture.mkdir(mode=0o700)
        args = SimpleNamespace(model="gpt-6-astra", report=root / "report.json", private_control=root / "private",
            executable=root / "codex", scanner_executable=root / "scanner", scanner_rules=root / "rules",
            auth_file=root / "source-auth", scratch_path=root / "scratch", build_binding=root / "build.json")
        for path, content in [(args.executable, b"binary"), (args.scanner_executable, b"scanner"),
                              (args.scanner_rules, b"rules"), (args.auth_file, b"fake-auth-only")]:
            probe.exclusive(path, content)
        calls = []

        def version(*a, **kw):
            kw["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False, ownedGroupAbsent=True)
            return probe.VERSION

        def produce(executable, model, owned, home, work, lifetime, control):
            self.assertEqual(probe.private_bytes(home / "auth.json"), b"fake-auth-only")
            lifetime.update(producerStopped=True, providerLaunchCount=1)
            if producer_failure:
                raise probe.ProbeFailure("fixture-production-failed")
            observed = SimpleNamespace(thread="00000000-0000-4000-8000-000000000001", turn="turn",
                                       input_message=INPUT, message=OUTPUT)
            return observed, {"nativeReviewCompleted": True}

        def worker(command, **kw):
            env = kw["environment"]
            self.assertFalse((fixture / "home/auth.json").exists())
            self.assertNotIn("SPILLCHECK_OTHER_PROBE_HOME", env)
            stage = env["SPILLCHECK_REVIEW_RECOVERY_STAGE"]
            calls.append(stage)
            probe.write_json(Path(env["SPILLCHECK_REVIEW_RECOVERY_REPORT"]), report(stage))
            kw["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=denied_worker,
                                       ownedGroupAbsent=not denied_worker)
            return 0, b"", 1

        with patch.object(probe, "verify_build", return_value="b" * 64), \
             patch.object(probe, "SCANNER_SHA", probe.digest(b"scanner")), \
             patch.object(probe, "RULES_SHA", probe.digest(b"rules")), \
             patch.object(probe.tempfile, "mkdtemp", return_value=str(fixture)), \
             patch.object(probe.producer.live, "observe_version", side_effect=version), \
             patch.object(probe.producer, "produce", side_effect=produce), \
             patch.object(probe.producer.live, "bounded", side_effect=worker), \
             patch("builtins.print"), \
             patch.dict(os.environ, {"SPILLCHECK_OTHER_PROBE_HOME": "/personal"}):
            code = probe.run(args)
        return code, probe.decode(probe.private_bytes(args.report)), fixture, calls

    def test_lifecycle_runs_three_workers_only_after_auth_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            code, value, fixture, calls = self.run_fixture(directory)
            self.assertEqual(code, 0)
            self.assertEqual(calls, list(probe.STAGES))
            self.assertTrue(value["passed"])
            self.assertTrue(value["originalAuthUnchanged"])
            self.assertFalse(fixture.exists())

    def test_failed_producer_still_removes_owned_auth_after_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            code, value, fixture, calls = self.run_fixture(directory, producer_failure=True)
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])
            self.assertTrue(value["authRemoved"])
            self.assertTrue(value["originalAuthUnchanged"])
            self.assertFalse(fixture.exists())

    def test_uncertain_worker_shutdown_stops_sequence_and_retains_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            code, value, fixture, calls = self.run_fixture(directory, denied_worker=True)
            self.assertEqual(code, 1)
            self.assertEqual(calls, ["queue"])
            self.assertFalse(value["passed"])
            self.assertTrue(value["privateCleanupPending"])
            self.assertTrue(fixture.is_dir())
            handoff = probe.decode(probe.private_bytes(Path(directory) / "private/cleanup-handoff.json"))
            self.assertEqual(handoff["ownedRoot"], str(fixture.resolve()))
            self.assertFalse(handoff["authenticationMayRemain"])


if __name__ == "__main__":
    unittest.main()
