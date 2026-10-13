import copy
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("signed_review_runner", Path(__file__).with_name("run-app-codex-review.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
VERSION = "0.162.1"


def descriptor():
    return {"schemaVersion": 1, "threadID": "11111111-1111-4111-8111-111111111111", "turnID": "review-native-turn",
        "inputID": "original-input", "outputID": "original-null-phase", "inputSHA256": "a" * 64,
        "outputSHA256": "b" * 64, "inputBytes": 100, "outputBytes": 200, "producerVersion": VERSION}


def observation():
    value = descriptor()
    return SimpleNamespace(thread=value["threadID"], turn=value["turnID"],
        input_message={"itemID": "live-input-differs", "textSHA256": value["inputSHA256"], "textBytes": value["inputBytes"]},
        message={"itemID": "live-output-differs", "textSHA256": value["outputSHA256"], "textBytes": value["outputBytes"]})


def discovery_report():
    report = {key: True for key in runner.producer.PASSIVE_CHECKS | runner.producer.INPUT_CHECKS}
    report.update({key: False for key in runner.producer.PASSIVE_LIMITS})
    report.update(schemaVersion=1, status="native-review-read-and-replayed", parserContract=runner.PARSER,
        readerVersion=VERSION, producerVersion=VERSION, inputTurnRelation="native-review-root", inputTurnMatchesReviewTurn=False,
        gapReasons=[], gapDiagnostics=[], inputGapReasons=[], inputGapDiagnostics=[],
        inputTextSHA256="a" * 64, reviewTextSHA256="b" * 64,
        inputTimeEvidence="matching-turn-interval", timeEvidence="item-completed",
        selectionBasis="unique-owned-turn-null-phase-live-bytes", liveItemIDEqualsPersistedItemID=False,
        liveInputItemIDEqualsPersistedItemID=False, persistedOriginalDescriptorExported=True,
        reviewItemCount=1, reviewSourceCount=1, threadReadCalls=2, itemReadCalls=2, turnReadCalls=2,
        threadListCalls=0, resumeCalls=0, forkCalls=0, presentationSourceCount=0, presentationItemCount=2,
        otherItemKindCount=0, reviewTextBytes=200, inputItemCount=1, inputSourceCount=1,
        totalOriginalSourceCount=2, inputTextBytes=100)
    return report


def stage_report(stage):
    value = {key: True for key in runner.recovery.COMMON_CHECKS - {"scannerArtifactsVerified", "storeClosed", "ciphertextVerified"}}
    value.update({key: False for key in ("applicationRouteEstablished", "desktopAcceptance", "t3Acceptance",
        "nativeChildCoverage", "providerUpgradeAcceptance", "systemNotificationDeliveryEstablished")})
    value.update({key: 0 for key in runner.recovery.COUNTS})
    value.update(passed=True, schemaVersion=1, stage=stage, bundledScannerSelected=True,
        parserContract=runner.PARSER, readerVersion=VERSION, producerVersion=VERSION, detectorVersion=runner.DETECTOR,
        upstreamScannerSHA256=runner.recovery.SCANNER_SHA, rulesSHA256=runner.recovery.RULES_SHA,
        cryptoScope="signed-original-owner-device-protection", checks={key: True for key in runner.recovery.STAGE_CHECKS[stage]},
        threadReadCalls=1, itemReadCalls=5, turnReadCalls=3, cursorCalls=2, exactTurnCalls=2,
        analysisReceiptCount=2, occurrenceCount=2, sourceCount=2, valueCount=1,
        inputTextSHA256="a" * 64, outputTextSHA256="b" * 64, inputTextBytes=100, outputTextBytes=200)
    if stage == "queue":
        value.update(queueInspectionKind="entry", queueCount=1, gapCount=2, detectorScanCalls=1)
    if stage == "resume": value["detectorScanCalls"] = 1
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryReviewEnabled": True, "recoveryCodexPollingStopped": True, "recoveryProcessingStopped": True,
        "coverageReportTruncated": False, "queueCount": value["queueCount"],
        "gapReasons": ["unsupportedContent"] if stage == "queue" else [], "recoveryReviewState": value}


class SignedReviewBoundaryTests(unittest.TestCase):
    def rollout_fixture(self, root):
        home = root / "home"; home.mkdir(mode=0o700)
        directory = home / "sessions/2026/10/12"; directory.mkdir(parents=True, mode=0o700)
        selected, child = descriptor()["threadID"], "22222222-2222-4222-8222-222222222222"
        root_metadata = {"id": selected, "cwd": str(root / "work"), "cli_version": VERSION,
            "originator": "spillcheck-fake-review-probe", "history_mode": "paginated", "source": "vscode"}
        child_metadata = dict(root_metadata, id=child, source={"subagent": "review"}, parent_thread_id=selected)
        paths = [directory / ("rollout-2026-10-12T12-00-0%d-" % index + item + ".jsonl")
            for index, item in enumerate((selected, child))]
        def write(path, metadata, body=b"opaque fake source bytes; not parsed as content\n"):
            path.write_bytes(json.dumps({"type": "session_meta", "payload": metadata}).encode() + b"\n" + body)
            path.chmod(0o600)
        for path, metadata in zip(paths, (root_metadata, child_metadata)): write(path, metadata)
        return home, (home.stat().st_dev, home.stat().st_ino), selected, paths, root_metadata, child_metadata, write

    def test_review_snapshot_pins_exact_root_and_linked_review_child_without_admitting_child_content(self):
        with tempfile.TemporaryDirectory() as parent:
            home, identity, selected, paths, root_meta, child_meta, write = self.rollout_fixture(Path(parent))
            snapshot = runner.source_snapshot(home, identity, selected)
            self.assertEqual(snapshot, runner.source_snapshot(home, identity, selected))
            self.assertEqual([row["role"] for row in snapshot["rollouts"]], ["selected-root", "review-child-stability-only"])
            self.assertEqual(len(snapshot["rollouts"]), 2)
            write(paths[1], child_meta, b"changed opaque body\n")
            self.assertNotEqual(snapshot, runner.source_snapshot(home, identity, selected))

    def test_review_snapshot_rejects_unrelated_or_wrong_kind_child_metadata(self):
        for key, wrong in (("parent_thread_id", "33333333-3333-4333-8333-333333333333"),
                ("source", {"subagent": "other"}), ("cwd", "/not-the-owned-work"),
                ("cli_version", "0.161.0"), ("originator", "other-producer"), ("history_mode", "other"),
                ("id", descriptor()["threadID"]), ("forked_from_id", descriptor()["threadID"])):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as parent:
                home, identity, selected, paths, root_meta, child_meta, write = self.rollout_fixture(Path(parent))
                child_meta[key] = wrong; write(paths[1], child_meta)
                with self.assertRaises(runner.shared.GateFailure): runner.source_snapshot(home, identity, selected)
        with tempfile.TemporaryDirectory() as parent:
            home, identity, selected, paths, root_meta, child_meta, write = self.rollout_fixture(Path(parent))
            root_meta["parent_thread_id"] = child_meta["id"]; write(paths[0], root_meta)
            with self.assertRaises(runner.shared.GateFailure): runner.source_snapshot(home, identity, selected)

    def test_review_snapshot_rejects_missing_extra_linked_or_public_files(self):
        for fault in ("missing", "extra", "symlink", "hardlink", "public", "auth", "auth-symlink", "identity"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as parent:
                root = Path(parent)
                home, identity, selected, paths, root_meta, child_meta, write = self.rollout_fixture(root)
                if fault == "missing": paths[1].unlink()
                elif fault == "extra": write(paths[1].with_name("extra.jsonl"), child_meta)
                elif fault == "symlink":
                    paths[1].unlink(); paths[1].symlink_to(paths[0])
                elif fault == "hardlink": os.link(paths[1], root / "extra-link")
                elif fault == "public": paths[1].chmod(0o644)
                elif fault == "auth": (home / "auth.json").write_text("fake")
                elif fault == "auth-symlink": (home / "auth.json").symlink_to(home / "absent")
                elif fault == "identity": identity = (identity[0], identity[1] + 1)
                with self.assertRaises((runner.shared.GateFailure, runner.shared.preflight.Invalid)):
                    runner.source_snapshot(home, identity, selected)

    def test_review_snapshot_rejects_duplicate_metadata_keys_and_unbounded_header(self):
        for first in (b'{"type":"session_meta","type":"session_meta","payload":{}}\n', b"x" * (256 * 1024 + 1)):
            with tempfile.TemporaryDirectory() as parent:
                home, identity, selected, paths, root_meta, child_meta, write = self.rollout_fixture(Path(parent))
                paths[1].write_bytes(first)
                with self.assertRaises((runner.shared.GateFailure, runner.producer.ProbeFailure)):
                    runner.source_snapshot(home, identity, selected)

    def test_discovery_accepts_only_measured_saved_ids_even_when_both_live_ids_differ(self):
        value, projected, lifetime, call = self.discover_fixture()
        self.assertEqual(value, descriptor())
        self.assertTrue(lifetime["descriptorReaderStopped"])
        self.assertFalse(projected["liveInputItemIDEqualsPersistedItemID"])
        self.assertFalse(projected["liveItemIDEqualsPersistedItemID"])
        self.assertNotIn("inputID", projected)
        self.assertIn("--skip-build", call.args[0])
        self.assertEqual(call.args[0][-1], "CodexReviewLiveTests.exactOwnedReviewIsReadTwiceThroughProductionClient")
        self.assertFalse(any(key.startswith("SPILLCHECK_") and not key.startswith("SPILLCHECK_REVIEW_PROBE_")
            for key in call.kwargs["environment"]))

    def test_discovery_rejects_missing_original_proof_or_false_identity_observation(self):
        for key in runner.producer.PASSIVE_CHECKS | runner.producer.INPUT_CHECKS | {"persistedOriginalDescriptorExported"}:
            report = discovery_report(); report[key] = False
            with self.assertRaises(runner.shared.GateFailure, msg=key): self.discover_fixture(report=report)
        for key in ("liveInputItemIDEqualsPersistedItemID", "liveItemIDEqualsPersistedItemID"):
            report = discovery_report(); report[key] = True
            with self.assertRaises(runner.shared.GateFailure, msg=key): self.discover_fixture(report=report)
        for key, wrong in (("inputID", "live-input-differs"), ("outputID", "live-output-differs"),
                ("threadID", "22222222-2222-4222-8222-222222222222"), ("turnID", "other-turn"),
                ("inputSHA256", "c" * 64), ("outputBytes", 201)):
            changed = descriptor(); changed[key] = wrong
            with self.assertRaises(runner.shared.GateFailure, msg=key): self.discover_fixture(descriptor_value=changed)

    def test_discovery_uncertain_test_or_reader_lifetime_stays_false_even_with_export(self):
        for key in ("leaderExited", "ownedGroupAbsent", "groupKillPermissionDenied"):
            cleanup = {"leaderExited": True, "ownedGroupAbsent": True, "groupKillPermissionDenied": False}
            cleanup[key] = not cleanup[key]
            lifetime = {"producerStopped": True, "descriptorReaderStopped": True}
            with self.assertRaises(runner.shared.GateFailure, msg=key): self.discover_fixture(cleanup=cleanup, lifetime=lifetime)
            self.assertFalse(lifetime["descriptorReaderStopped"])
        lifetime = {"producerStopped": True, "descriptorReaderStopped": True}
        report = discovery_report(); report["readerShutdownCompletedWithinDeadline"] = False
        with self.assertRaises(runner.shared.GateFailure): self.discover_fixture(report=report, lifetime=lifetime)
        self.assertFalse(lifetime["descriptorReaderStopped"])

    def test_discovery_refuses_authentication_and_auth_symlinks_before_reader_launch(self):
        for auth in ("file", "symlink"):
            with tempfile.TemporaryDirectory() as parent:
                root = Path(parent); home = root / "home"; home.mkdir()
                if auth == "file": (home / "auth.json").write_text("fake")
                else: (home / "auth.json").symlink_to(home / "absent")
                with patch.object(runner.recovery, "bounded") as child:
                    with self.assertRaises(runner.shared.GateFailure):
                        runner.discover_descriptor(Path("/reader"), home, root, root / "control", observation(),
                            root / "build", {"producerStopped": True, "descriptorReaderStopped": True})
                    child.assert_not_called()

    def discover_fixture(self, *, report=None, descriptor_value=None, cleanup=None, lifetime=None):
        report = discovery_report() if report is None else report
        descriptor_value = descriptor() if descriptor_value is None else descriptor_value
        cleanup = cleanup or {"leaderExited": True, "ownedGroupAbsent": True, "groupKillPermissionDenied": False}
        lifetime = {"producerStopped": True, "descriptorReaderStopped": True} if lifetime is None else lifetime
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(); control = root / "control"; control.mkdir()
            def witness(*args, **kwargs):
                runner.shared.write_json(control / "passive-report.json", report)
                runner.shared.write_new(root / "review-descriptor.json", runner.descriptor_bytes(descriptor_value))
                kwargs["cleanup_report"].update(cleanup)
                return 0, b"", 1
            with patch.object(runner.recovery, "bounded", side_effect=witness) as child:
                result, projected = runner.discover_descriptor(Path("/reader"), home, root, control,
                    observation(), root / "build", lifetime)
                return result, projected, lifetime, child.call_args

    def test_descriptor_exact_original_ids_and_bytes(self):
        value = descriptor()
        self.assertEqual(json.loads(runner.descriptor_bytes(value)), value)
        for key, invalid in (("inputID", value["outputID"]), ("outputID", ""), ("inputBytes", True),
                ("outputBytes", 0), ("inputSHA256", "not-a-digest"), ("producerVersion", "0.161.0"), ("schemaVersion", True)):
            changed = dict(value); changed[key] = invalid
            with self.assertRaises(runner.shared.GateFailure, msg=key): runner.descriptor_bytes(changed)
        value["unexpectedSource"] = "not-owned"
        with self.assertRaises(runner.shared.GateFailure): runner.descriptor_bytes(value)

    def test_workers_cannot_request_owner_authority_or_wrong_stage(self):
        root = Path("/private/tmp/spillcheck-signed-review-test")
        for index, stage in enumerate(runner.STAGES, 1):
            command = runner.worker_command(Path("/candidate"), root, "worker" + str(index), home=root / "home",
                descriptor=root / "review-descriptor.json", reader=Path("/reader"), version=VERSION, stage=stage)
            self.assertIn("--acceptance-recovery-review", command)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertFalse(any("cleanup-new-vault" in x or "vault-owner" in x for x in command))
        with self.assertRaises(runner.shared.GateFailure):
            runner.worker_command(Path("/candidate"), root, "worker1", home=root / "home",
                descriptor=root / "review-descriptor.json", reader=Path("/reader"), version=VERSION, stage="replay")

    def test_stage_gate_requires_every_original_binding_and_recovery_check(self):
        for stage in runner.STAGES:
            self.assertTrue(runner.stage_gate(stage_report(stage), stage, descriptor()))
            for key in runner.recovery.STAGE_CHECKS[stage]:
                value = stage_report(stage); value["recoveryReviewState"]["checks"][key] = False
                self.assertFalse(runner.stage_gate(value, stage, descriptor()), (stage, key))
            for key in runner.recovery.COMMON_CHECKS - {"scannerArtifactsVerified", "storeClosed", "ciphertextVerified"}:
                value = stage_report(stage); del value["recoveryReviewState"][key]
                self.assertFalse(runner.stage_gate(value, stage, descriptor()), (stage, key))

    def test_stage_gate_rejects_synthetic_keys_broader_claims_unowned_enumeration_and_nonfull_receipts(self):
        for stage in runner.STAGES:
            for key, bad in (("cryptoScope", "disposable-deterministic-test-keys"), ("threadListCalls", 1),
                    ("itemReadCalls", True), ("readerVersion", "0.161.0"), ("applicationRouteEstablished", True),
                    ("inputTextSHA256", "c" * 64), ("outputTextBytes", 201), ("bundledScannerSelected", False)):
                value = stage_report(stage); value["recoveryReviewState"][key] = bad
                self.assertFalse(runner.stage_gate(value, stage, descriptor()), (stage, key))
        for key, bad in (("analysisReceiptCount", 1), ("occurrenceCount", 4), ("gapCount", 1), ("detectorScanCalls", 1)):
            value = stage_report("replay"); value["recoveryReviewState"][key] = bad
            self.assertFalse(runner.stage_gate(value, "replay", descriptor()), key)
        value = stage_report("queue"); value["recoveryReviewState"]["turnReadCalls"] = 0
        self.assertFalse(runner.stage_gate(value, "queue", descriptor()))

    def test_uncertain_worker_reader_prevents_cleanup_even_after_normal_app_exit(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent)
            report = {"acceptancePhase": "shutdown-complete", "recoveryReviewState": {"readerStarted": True, "readerShutdown": True}}
            def write(value):
                path = root / "worker1-report.json"
                path.write_text(json.dumps(value)); path.chmod(0o600)
            write(report)
            self.assertTrue(runner.worker_readers_stopped(root, 1))
            report["recoveryReviewState"]["readerShutdown"] = False
            write(report)
            self.assertFalse(runner.worker_readers_stopped(root, 1))
            write({"acceptancePhase": "shutdown-complete"})
            self.assertFalse(runner.worker_readers_stopped(root, 1))
            self.assertFalse(runner.worker_readers_stopped(root, 2))

    def test_ciphertext_check_rejects_plaintext_and_symlink(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); store = root / "protected-store"; store.mkdir()
            scanner = root / "review-evidence/scanner"; scanner.mkdir(parents=True)
            data = store / "vault"; data.write_bytes(b"encrypted bytes")
            self.assertTrue(runner.ciphertext_files(root))
            data.write_text(runner.recovery.FAKE_TOKEN)
            with self.assertRaises(runner.shared.GateFailure): runner.ciphertext_files(root)
            data.unlink(); data.symlink_to(root / "missing")
            with self.assertRaises(runner.shared.GateFailure): runner.ciphertext_files(root)

    def test_complete_gate_requires_cleanup_and_exact_true(self):
        checks = {key: True for key in runner.REQUIRED_CHECKS}
        self.assertTrue(runner.completed_checks(checks))
        for key in checks:
            invalid = dict(checks); del invalid[key]
            self.assertFalse(runner.completed_checks(invalid), key)
            invalid[key] = 1
            self.assertFalse(runner.completed_checks(invalid), key)

    def test_owner_failure_never_reads_authentication_or_launches_provider(self):
        self.failure_lifecycle(owner_fails=True)

    def test_unconfirmed_producer_blocks_authentication_removal_and_creator_cleanup(self):
        self.failure_lifecycle(owner_fails=False)

    def test_unconfirmed_descriptor_reader_blocks_creator_cleanup_even_after_producer_stops(self):
        self.failure_lifecycle(owner_fails=False, discovery_fails=True)

    def failure_lifecycle(self, owner_fails, discovery_fails=False):
        with tempfile.TemporaryDirectory() as parent:
            parent = Path(parent); root = parent / "owned"; root.mkdir(mode=0o700)
            app = parent / "app"; app.mkdir(); reader = parent / "reader"; reader.touch()
            manifest = parent / "manifest"; manifest.write_text("{}")
            class Artifacts:
                directory = root
                report = None
                passed = False
                def __enter__(self): return self
                def __exit__(self, *args): self.passed = bool(self.report and self.report.get("passed"))
            artifacts = Artifacts()
            owner = Mock(); owner.counts = {}; owner.process.poll.return_value = None
            if owner_fails: owner.wait_report.side_effect = RuntimeError("fresh owner unavailable")
            args = SimpleNamespace(app=app, executable=reader, candidate_manifest=manifest,
                expected_bundle_sha256="a" * 64, expected_version=VERSION, model="gpt-6-astra",
                auth_file=parent / "never-read-auth", output=parent / "report.json", private_control=parent / "control.json",
                scratch_path=parent / "compiled-tests")
            def version(*args, **kwargs):
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return VERSION
            def produce(*args):
                args[-2].update(providerLaunchCount=1, producerStopped=discovery_fails)
                if discovery_fails: return observation(), {}
                raise RuntimeError("producer group unconfirmed")
            def discovery(*args):
                args[-1]["descriptorReaderStopped"] = False
                raise RuntimeError("descriptor reader group unconfirmed")
            with ExitStack() as stack:
                def stub(obj, name, **kwargs): return stack.enter_context(patch.object(obj, name, **kwargs))
                stub(runner.shared, "AcceptanceArtifacts", return_value=artifacts)
                stub(runner.shared.preflight, "hash_file", return_value="a" * 64)
                stub(runner.shared.preflight, "read_manifest", return_value={"bundleSHA256": "a" * 64})
                stub(runner.shared.preflight, "check", return_value={"consistent": True})
                stub(runner, "runner_hashes", return_value={})
                stub(runner.recovery, "artifact_hashes", return_value={"fake-test-artifact": "d" * 64})
                stub(runner, "discover_descriptor", side_effect=discovery)
                stub(runner.shared.live, "observe_version", side_effect=version)
                stub(runner.setup, "ReportProcess", return_value=owner)
                stub(runner.lifecycle, "process_handoff")
                stub(runner.inventory, "cleanup_workers", return_value=([], []))
                finish = stub(runner.inventory, "finish_creator", return_value=({}, False, True, False))
                auth = stub(runner.shared, "private_bytes", return_value=b'{"fake":"never-used-for-provider"}')
                provider = stub(runner.producer, "produce", side_effect=produce)
                self.assertEqual(runner.run(args), 1)
                self.assertFalse(artifacts.report["passed"])
                if owner_fails:
                    auth.assert_not_called(); provider.assert_not_called()
                    self.assertFalse((root / "home/auth.json").exists())
                else:
                    self.assertEqual((root / "home/auth.json").exists(), not discovery_fails)
                    self.assertFalse(finish.call_args.kwargs["authorized"])
                    self.assertEqual(artifacts.report["temporaryAuthenticationRemoved"], discovery_fails)


if __name__ == "__main__": unittest.main()
