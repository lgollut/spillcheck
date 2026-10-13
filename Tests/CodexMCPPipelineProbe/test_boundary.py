"""Offline boundary tests: no providers, scanners, vaults, or Swift builds."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("mcp_pipeline_boundary", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def keyed(value):
    return base64.b64encode(bytes.fromhex(probe.digest(value.encode()))).decode()


def report(stage):
    counts = {key: 0 for key in probe.DOMAINS}
    counts.update(records=1, occurrences=4, analysisReceipts=3, sourceKinds=3, sourceTimes=3,
                  locationReceipts=4, conversationLabels=1, valueLabels=1, historicalNotifications=1,
                  strongSignalReceipts=4)
    inventory = {"counts": counts, "digests": {key: sorted(keyed(key + str(i)) for i in range(count))
        for key, count in counts.items()}, "schemaVersion": 3, "nextValueLabel": 2, "payloadCount": 6}
    value = {"schemaVersion": 1, "stage": stage, "passed": True, "parserContract": probe.PARSER,
        "readerVersion": probe.VERSION, "producerVersion": probe.VERSION, "detectorVersion": probe.DETECTOR,
        "scannerSHA256": probe.SCANNER_SHA, "rulesSHA256": probe.RULES_SHA,
        "cryptoScope": "disposable-deterministic-test-keys", "inventory": inventory, "gapReasons": [],
        **{key: True for key in probe.COMMON_CHECKS | probe.CLOSURE}, **{key: False for key in probe.LIMITS},
        **{key: 0 for key in probe.COUNTS}, **{key: keyed(key) for key in probe.COMMITMENTS},
        "checks": {key: True for key in probe.STAGE_CHECKS[stage]}}
    value.update(targetSegmentCount=11, targetTextBytes=probe.TARGET_BYTES, targetOccurrenceCount=4,
                 valueCount=1, occurrenceCount=4, payloadRowCount=6, targetReceiptCount=1,
                 analysisReceiptCount=3, sourceCount=3,
                 targetReceiptDigest=inventory["digests"]["analysisReceipts"][0],
                 targetSourceDigest=inventory["digests"]["sourceKinds"][0])
    if stage == "cold":
        value.update(historyClientCreated=False, readerVersionMeasured=False, observedReaderVersions=[],
                     readerShutdown=None, readerShutdownNotNeeded=True, versionBinding="saved-evidence")
    else:
        value.update(historyClientCreated=True, readerVersionMeasured=True, observedReaderVersions=[probe.VERSION],
            readerShutdown=True, readerShutdownNotNeeded=False, versionBinding="same-response", threadReadCalls=1,
            itemReadCalls=1, nativeTargetReadCount=1, detectorScanCalls=3 if stage == "collect" else 0)
    return value


class PipelineBoundaries(unittest.TestCase):
    def test_fixture_has_exact_four_original_pointers_and_no_protocol_error(self):
        expected = {"/result/content/0/text", "/result/structuredContent/caption",
            "/result/structuredContent/content/0/encrypted_content", "/result/structuredContent/resource/blob"}
        segments = probe.fixture_segments()
        self.assertEqual(set(segments), set(probe.producer.EXPECTED_POINTERS))
        self.assertEqual(len(segments), 11)
        self.assertEqual({key for key, text in segments.items() if probe.fixture.FAKE_TOKEN in text}, expected)
        self.assertTrue(all(segments[key].count(probe.fixture.FAKE_TOKEN) == 1 for key in expected))
        self.assertFalse(probe.fixture.RESULT["isError"])
        self.assertTrue(probe.fixture.RESULT["structuredContent"]["isError"])
        self.assertEqual(probe.fixture.RESULT["structuredContent"]["exit_code"], 7)
        self.assertNotIn(probe.fixture.FAKE_TOKEN, probe.producer.PROMPT)

    def test_private_fixture_does_not_mutate_historical_module(self):
        old = probe.load("independent_old_mcp", probe.ROOT / "Tests/CodexMCPSourceProbe/run.py")
        self.assertNotIn(probe.fixture.FAKE_TOKEN, json.dumps(old.fixture.RESULT))
        self.assertIsNot(old.fixture, probe.producer.fixture)
        config = probe.producer.fixture_configuration("gpt-6-astra", Path("/owned/fixture.py"), Path("/owned/control"))
        self.assertNotIn(probe.fixture.FAKE_TOKEN.encode(), config)

    def test_actual_result_and_call_contract_remain_exact(self):
        native = {key: value for key, value in probe.fixture.RESULT.items() if key != "isError"}
        self.assertTrue(probe.producer.expected_result(native))
        changed = copy.deepcopy(native)
        changed["structuredContent"]["caption"] += "."
        self.assertFalse(probe.producer.expected_result(changed))
        self.assertEqual(probe.fixture.reply({"method": "tools/call", "params": {"name": probe.fixture.TOOL,
            "arguments": {}, "_meta": {"progressToken": 1}}}), probe.fixture.RESULT)
        for params in ({"name": "other", "arguments": {}}, {"name": probe.fixture.TOOL, "arguments": {"extra": 1}},
                       {"name": probe.fixture.TOOL, "arguments": {}, "_meta": "not-an-object"}):
            with self.assertRaises(ValueError):
                probe.fixture.reply({"method": "tools/call", "params": params})

    def test_complete_three_stage_contract(self):
        self.assertTrue(probe.stable_stages([report(stage) for stage in probe.STAGES]))

    def test_every_required_check_must_exist_and_be_boolean_true(self):
        for stage in probe.STAGES:
            for key in probe.COMMON_CHECKS | probe.CLOSURE:
                for invalid in (None, False, 1):
                    value = report(stage); value[key] = invalid
                    self.assertFalse(probe.stage_gate(value, stage), (stage, key, invalid))
            for key in probe.STAGE_CHECKS[stage]:
                value = report(stage); value["checks"].pop(key)
                self.assertFalse(probe.stage_gate(value, stage), (stage, key))

    def test_cold_never_claims_reader_measurement_or_starts_reads(self):
        for key, wrong in {"historyClientCreated": True, "readerVersionMeasured": True,
            "readerShutdown": True, "readerShutdownNotNeeded": False, "versionBinding": "same-response",
            "observedReaderVersions": [probe.VERSION], "threadReadCalls": 1, "itemReadCalls": 1,
            "turnReadCalls": 1, "nativeTargetReadCount": 1, "detectorScanCalls": 1}.items():
            value = report("cold"); value[key] = wrong
            self.assertFalse(probe.stage_gate(value, "cold"), key)

    def test_collection_requires_real_scans_and_replay_forbids_them(self):
        for stage, count in (("collect", 0), ("collect", 2), ("replay", 1)):
            value = report(stage); value["detectorScanCalls"] = count
            self.assertFalse(probe.stage_gate(value, stage))
        for stage in ("collect", "replay"):
            for key in ("nativeTargetReadCount", "itemReadCalls", "threadReadCalls"):
                value = report(stage); value[key] = 0
                self.assertFalse(probe.stage_gate(value, stage))

    def test_target_missing_reduced_or_inflated_receipts_fail(self):
        for key, wrong in {"targetReceiptCount": 0, "analysisReceiptCount": 2, "sourceCount": 0,
            "targetSegmentCount": 10, "targetTextBytes": probe.TARGET_BYTES - 1, "targetOccurrenceCount": 3,
            "occurrenceCount": 5, "valueCount": 2, "payloadRowCount": 0, "targetGapCount": 1,
            "queueCount": 1, "detectorVersion": probe.DETECTOR + "+reduced"}.items():
            value = report("collect"); value[key] = wrong
            self.assertFalse(probe.stage_gate(value, "collect"), key)
        for key in ("targetReceiptDigest", "targetSourceDigest"):
            value = report("collect"); value[key] = keyed("unrelated target row")
            self.assertFalse(probe.stage_gate(value, "collect"))

    def test_full_state_mutation_or_replaced_receipt_fails_even_equal_counts(self):
        for domain in probe.DOMAINS:
            stages = [report(stage) for stage in probe.STAGES]
            inv = stages[2]["inventory"]
            if inv["digests"][domain]:
                inv["digests"][domain][0] = keyed("replacement" + domain)
                inv["digests"][domain].sort()
            else:
                inv["counts"][domain] = 1; inv["digests"][domain] = [keyed("replacement" + domain)]
            self.assertFalse(probe.stable_stages(stages), domain)
        for key in probe.COMMITMENTS:
            stages = [report(stage) for stage in probe.STAGES]; stages[1][key] = keyed("changed")
            self.assertFalse(probe.stable_stages(stages))

    def test_inventory_shape_rejects_unbounded_and_uncanonical_digests(self):
        valid = report("cold")["inventory"]
        for mutate in (lambda x: x["counts"].update(records=True),
                       lambda x: x["counts"].update(records=257),
                       lambda x: x["digests"]["records"].append(x["digests"]["records"][0]),
                       lambda x: x["digests"]["records"].__setitem__(0, "not a digest"),
                       lambda x: x.update(rawText="private"), lambda x: x["counts"].pop("sourceTimes")):
            value = copy.deepcopy(valid); mutate(value)
            self.assertFalse(probe.inventory_valid(value))

    def test_public_projection_never_exports_extra_content_or_invalid_known_values(self):
        value = report("collect")
        value.update(nativeID="private", text="private", failureStage="private body", gapReasons=["private"],
                     targetResultDigest="private", observedReaderVersions=["private"])
        value["checks"]["rawText"] = "private"
        output = json.dumps(probe.public_stage(value))
        self.assertNotIn("private", output)
        self.assertNotIn("nativeID", output)
        self.assertFalse(probe.stage_gate(value, "collect"))

    def test_broader_claims_never_accepted(self):
        for key in probe.LIMITS:
            value = report("collect"); value[key] = True
            self.assertFalse(probe.stage_gate(value, "collect"))

    def test_all_dependencies_including_import_time_original_fixture_are_bound(self):
        self.assertTrue({"Tests/CodexMCPSourceProbe/fixture.py", "Tests/CodexMCPSourceProbe/run.py",
            "Tests/CodexReviewRecoveryProbe/run.py", "Tests/CodexReviewProbe/run.py", "Tests/CodexPlanProbe/run.py",
            "Tests/CodexLive/run.py", "Tests/Support/processes.py", "Tests/CodexMCPPipelineProbe/fixture.py"} <= probe.DEPENDENCIES)
        bindings = probe.source_hashes()
        self.assertIn("Sources/SpillcheckCore/CodexAdapter.swift", bindings)
        self.assertIn("Tests/CodexMCPPipelineProbe/test_boundary.py", bindings)
        self.assertIn("Package.swift", bindings)

    def test_build_binding_detects_source_artifact_and_binding_mutations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); binding = root / "binding.json"
            args = types.SimpleNamespace(build_binding=binding, scratch_path=root)
            value = {"schemaVersion": 1, "parserContract": probe.PARSER, "scratchPath": str(root.resolve()),
                "sources": {"source": "one"}, "artifacts": {"artifact": "two"}, "inputsStableAcrossBuild": True}
            probe.write_json(binding, value)
            with mock.patch.object(probe, "source_hashes", return_value=value["sources"]), mock.patch.object(
                    probe.support, "artifact_hashes", return_value=value["artifacts"]):
                self.assertEqual(probe.verify_build(args), probe.digest(binding.read_bytes()))
            for sources, artifacts in (({"source": "changed"}, value["artifacts"]), (value["sources"], {"artifact": "changed"})):
                with mock.patch.object(probe, "source_hashes", return_value=sources), mock.patch.object(
                        probe.support, "artifact_hashes", return_value=artifacts), self.assertRaises(probe.ProbeFailure):
                    probe.verify_build(args)

    def test_stale_build_or_unauthorized_auth_fails_before_provider_or_auth_read(self):
        args = types.SimpleNamespace(model="gpt-6-astra", auth_file=probe.AUTH_FILE, report=Path("/nonexistent-probe-report"))
        with mock.patch.object(probe, "verify_build", side_effect=probe.ProbeFailure("stale")), mock.patch.object(
                probe, "private_bytes") as read, mock.patch.object(probe.producer, "produce") as produce:
            with self.assertRaises(probe.ProbeFailure): probe.run(args)
            read.assert_not_called(); produce.assert_not_called()
        args.auth_file = Path("/other/auth.json")
        with mock.patch.object(probe, "verify_build") as verify, self.assertRaises(probe.ProbeFailure):
            probe.run(args)
        verify.assert_not_called()

    def test_source_files_are_bounded_and_immutable_without_personal_enumeration(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp); sessions = home / "sessions"; sessions.mkdir()
            source = sessions / "owned.jsonl"; probe.exclusive(source, b'{}\n')
            original = probe.source_files(home)
            source.write_bytes(b'{"changed":true}\n')
            self.assertNotEqual(probe.source_files(home), original)
            source.unlink(); source.symlink_to(home / "other")
            with self.assertRaises((probe.ProbeFailure, OSError)):
                probe.source_files(home)

    def test_producer_leader_exit_does_not_prove_group_absence(self):
        process = types.SimpleNamespace(pid=12345)
        with mock.patch.object(probe, "base_stop_group", return_value={}), mock.patch.object(
                probe.support, "group_absent", return_value=False), self.assertRaises(probe.ProbeFailure):
            probe.stop_producer(process)

    def test_independent_mcp_parent_and_group_absence_are_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            probe.write_json(path / "producer-process.json", {"pid": 1001, "root": str(path)})
            probe.write_json(path / "mcp-process.json", {"pid": 1002, "parentPID": 1001, "processGroup": 1002})
            lifetime = {"producerStopped": True, "providerLaunchCount": 1}
            with mock.patch.object(probe.producer.os, "kill", side_effect=ProcessLookupError), mock.patch.object(
                    probe.producer.os, "killpg", side_effect=ProcessLookupError):
                self.assertTrue(probe.producer.confirm_mcp_stopped(path, lifetime))
            with mock.patch.object(probe.producer.os, "kill", return_value=None), mock.patch.object(
                    probe.producer.os, "killpg", side_effect=ProcessLookupError):
                self.assertFalse(probe.producer.confirm_mcp_stopped(path, lifetime, wait_seconds=0))
            with mock.patch.object(probe.producer.os, "kill", side_effect=PermissionError), self.assertRaises(PermissionError):
                probe.producer.confirm_mcp_stopped(path, lifetime)
            (path / "mcp-process.json").unlink()
            probe.write_json(path / "mcp-process.json", {"pid": 1002, "parentPID": 9999, "processGroup": 1002})
            with self.assertRaises(probe.ProbeFailure): probe.producer.confirm_mcp_stopped(path, lifetime)

    def test_original_auth_rotation_does_not_skip_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root = base / "owned"; root.mkdir(); home = root / "home"; home.mkdir()
            original = base / "original"; probe.exclusive(original, b'changed')
            probe.exclusive(home / "auth.json", b'owned copy')
            ri, hi = root.stat(), home.stat()
            lifetime = {key: True for key in ("producerStopped", "readerStopped", "versionProcessStopped", "mcpServerStopped")}
            result = {"authRemoved": False, "ownedRootRemoved": False}
            probe.producer.finish_cleanup(result, lifetime, original_path=original, original_hash=probe.digest(b'old'),
                root=root, home=home, root_identity=(ri.st_dev, ri.st_ino), home_identity=(hi.st_dev, hi.st_ino))
            self.assertFalse(result["originalAuthUnchanged"])
            self.assertTrue(result["authRemoved"]); self.assertTrue(result["ownedRootRemoved"])

    def test_unconfirmed_mcp_or_worker_cleanup_retains_credentials_and_root(self):
        for key in ("producerStopped", "readerStopped", "versionProcessStopped", "mcpServerStopped"):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); home = root / "home"; home.mkdir(); probe.exclusive(home / "auth.json", b'owned')
                ri, hi = root.stat(), home.stat()
                lifetime = {k: True for k in ("producerStopped", "readerStopped", "versionProcessStopped", "mcpServerStopped")}
                lifetime[key] = False
                result = {"authRemoved": False, "ownedRootRemoved": False}
                probe.producer.finish_cleanup(result, lifetime, original_path=root / "absent", original_hash=None,
                    root=root, home=home, root_identity=(ri.st_dev, ri.st_ino), home_identity=(hi.st_dev, hi.st_ino))
                self.assertTrue((home / "auth.json").is_file()); self.assertFalse(result["ownedRootRemoved"])

    def test_worker_process_cleanup_requires_group_absence_and_no_denial(self):
        for value in ({"leaderExited": True, "groupKillPermissionDenied": False},
                      {"leaderExited": True, "groupKillPermissionDenied": True, "ownedGroupAbsent": True},
                      {"leaderExited": True, "groupKillPermissionDenied": False, "ownedGroupAbsent": False}):
            self.assertFalse(probe.support.stopped(value))

    def test_cli_help_executes_without_provider(self):
        completed = subprocess.run([sys.executable, str(Path(__file__).with_name("run.py")), "--help"],
                                   capture_output=True, timeout=10)
        self.assertEqual(completed.returncode, 0)
        self.assertIn(b"build", completed.stdout)


if __name__ == "__main__":
    unittest.main()
