import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from contextlib import ExitStack

spec = importlib.util.spec_from_file_location("desktop_beta_runner", Path(__file__).with_name("run-app-codex-desktop-beta.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def descriptor():
    return {"schemaVersion": 1, "parentID": "11111111-1111-4111-8111-111111111111",
        "childID": "22222222-2222-4222-8222-222222222222", "homePath": "/fake-owned-home",
        "projectPath": str(runner.PROJECT), "producerVersion": runner.PRODUCER,
        "hostVersion": runner.HOST, "ownershipProofSHA256": runner.proof_digest(runner.PROOF_HASHES)}


def passed(stage):
    audits, unread, admissions = (1, 1, 1) if stage == "scan" else (3, 2, 2)
    state = {"schemaVersion": 1, "stage": stage, "passed": True, "readerShutdown": True, "readerStarted": True,
        "parserContract": runner.PARSER, "readerVersion": runner.READER, "producerVersion": runner.PRODUCER,
        "hostVersion": runner.HOST, "detectorVersion": runner.DETECTOR, "upstreamScannerSHA256": runner.SCANNER_SHA,
        "rulesSHA256": runner.RULES_SHA, "cryptoScope": "signed-original-owner-device-protection",
        "ownershipProofSHA256": descriptor()["ownershipProofSHA256"], "checks": {key: True for key in runner.STAGE_CHECKS[stage]},
        "analysisReceiptCount": 16, "sourceCount": 16, "occurrenceCount": 15, "valueCount": 1, "sessionCount": 2,
        "gapCount": 1, "queueCount": 0, "detectorScanCalls": 16 if stage == "scan" else 0,
        "threadReadCalls": 2, "itemReadCalls": 2, "turnReadCalls": 0, "threadListCalls": 0,
        "nativeBytesRead": 13000, "productionSessionCount": 2,
        "initialAdmissionCount": admissions, "createdAuditCount": admissions,
        "successfulAdmissionCount": admissions, "consumedAdmissionCount": admissions,
        "observedOriginalSourceCount": 16, "expectedOriginalSourceCount": 16,
        "canonicalGapEmissionCount": 1, "durableOmissionCount": 1,
        "pipelineFailureCount": 0, "normalizerCallCount": 2, "queueClaimedCount": 0,
        "typedCommittedMarkers": {key: 1 for key in runner.MARKERS}}
    if stage == "replay":
        state.update(inventoryEqual=True, receiptsEqual=True, omissionEqual=True, freshCanonicalGapObservedWithinReplay=True)
    for key in ("applicationRouteEstablished", "liveDesktopDispatchEstablished", "sideChatCoverageEstablished",
        "nativeChildIncomingInputEstablished", "sourceOpeningEstablished", "systemNotificationDeliveryEstablished", "fullCodexAcceptance"):
        state[key] = False
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryDesktopBetaEnabled": True, "recoveryCodexPollingStopped": True, "recoveryProcessingStopped": True,
        "coverageReportTruncated": False, "gapReasons": ["budgetExhausted", "unsupportedContent"], "queueCount": 0,
        "gapCountsByOperation": {"historicalRead": {"budgetExhausted": unread, "unsupportedContent": 1}},
        "historicalProgressMeasurementAvailable": True, "scopedGapCount": unread + 1,
        "settledHistoricalAuditCount": audits, "unreadHistoricalProgressCount": unread,
        "recoveryQueueClaimedCount": 0, "recoveryEncryptedQueueBytes": 0,
        "recoveryDesktopBetaState": state}


class DesktopBetaBoundaries(unittest.TestCase):
    def test_descriptor_binds_original_fixed_scope(self):
        value = descriptor()
        raw = runner.descriptor_bytes(value)
        self.assertEqual(json.loads(raw), value)
        self.assertNotIn(b" ", raw)
        mutations = {"schemaVersion": True, "parentID": value["childID"], "producerVersion": runner.READER,
            "hostVersion": "new-host", "ownershipProofSHA256": "a" * 64,
            "projectPath": "/other/personal-project", "homePath": "relative"}
        for key, bad in mutations.items():
            with self.subTest(key=key), self.assertRaises((ValueError, RuntimeError)):
                runner.descriptor_bytes(value | {key: bad})
        with self.assertRaises((ValueError, RuntimeError)):
            runner.descriptor_bytes(value | {"copiedHistoryPath": "/arbitrary"})

    def test_all_stage_checks_are_required_and_not_truthy(self):
        for stage in runner.STAGES:
            report = passed(stage)
            self.assertTrue(runner.stage_gate(report, stage, descriptor()))
            for key in runner.STAGE_CHECKS[stage]:
                for bad in (False, 1, None):
                    changed = copy.deepcopy(report); changed["recoveryDesktopBetaState"]["checks"][key] = bad
                    with self.subTest(stage=stage, key=key, bad=bad):
                        self.assertFalse(runner.stage_gate(changed, stage, descriptor()))
            changed = copy.deepcopy(report); changed["recoveryDesktopBetaState"]["checks"]["invented"] = True
            self.assertFalse(runner.stage_gate(changed, stage, descriptor()))

    def test_accepted_child_limit_never_allows_other_gaps(self):
        for gaps in ([], ["unsupportedContent"], ["budgetExhausted"], ["sourceUnavailable"],
                     ["budgetExhausted", "unsupportedContent", "sourceUnavailable"],
                     ["budgetExhausted", "unsupportedContent", "deliveryUncertain"], ["scannerUnavailable"]):
            report = passed("scan"); report["gapReasons"] = gaps
            self.assertFalse(runner.stage_gate(report, "scan", descriptor()))
        for gap_count in (0, 2, True):
            report = passed("scan"); report["recoveryDesktopBetaState"]["gapCount"] = gap_count
            self.assertFalse(runner.stage_gate(report, "scan", descriptor()))
        for key in ("onlyCanonicalChildInputLimitation", "nativeParentChildLinkVerified"):
            report = passed("scan"); report["recoveryDesktopBetaState"]["checks"][key] = False
            self.assertFalse(runner.stage_gate(report, "scan", descriptor()))

    def test_derived_unread_summary_requires_exact_counts_for_each_stage(self):
        for stage in runner.STAGES:
            audits, unread = (1, 1) if stage == "scan" else (3, 2)
            for key, expected in (("settledHistoricalAuditCount", audits), ("unreadHistoricalProgressCount", unread),
                                  ("scopedGapCount", unread + 1)):
                for bad in (0, expected - 1, expected + 1, True, None):
                    report = passed(stage); report[key] = bad
                    with self.subTest(stage=stage, key=key, bad=bad):
                        self.assertFalse(runner.stage_gate(report, stage, descriptor()))
            for key, expected in (("budgetExhausted", unread), ("unsupportedContent", 1)):
                for bad in (0, expected + 1, True, None):
                    report = passed(stage); report["gapCountsByOperation"]["historicalRead"][key] = bad
                    self.assertFalse(runner.stage_gate(report, stage, descriptor()))
            for key in ("coverageReportTruncated", "historicalProgressMeasurementAvailable",
                        "gapCountsByOperation", "scopedGapCount", "settledHistoricalAuditCount",
                        "unreadHistoricalProgressCount", "recoveryQueueClaimedCount", "recoveryEncryptedQueueBytes"):
                report = passed(stage); del report[key]
                self.assertFalse(runner.stage_gate(report, stage, descriptor()), key)
            for key, bad in (("coverageReportTruncated", True), ("coverageReportTruncated", 0),
                             ("historicalProgressMeasurementAvailable", False), ("historicalProgressMeasurementAvailable", 1),
                             ("queueCount", 1), ("recoveryQueueClaimedCount", 1), ("recoveryEncryptedQueueBytes", 1)):
                report = passed(stage); report[key] = bad
                self.assertFalse(runner.stage_gate(report, stage, descriptor()), key)

    def test_derived_summary_never_allows_another_operation_or_reason(self):
        for stage in runner.STAGES:
            for operation in ("liveRead", "hookDelivery", "unknown"):
                report = passed(stage); report["gapCountsByOperation"][operation] = {"budgetExhausted": 1}
                self.assertFalse(runner.stage_gate(report, stage, descriptor()))
                report = passed(stage)
                report["gapCountsByOperation"][operation] = report["gapCountsByOperation"].pop("historicalRead")
                self.assertFalse(runner.stage_gate(report, stage, descriptor()))
            for reason in ("sourceUnavailable", "deliveryUncertain", "malformedSource"):
                report = passed(stage); report["gapCountsByOperation"]["historicalRead"][reason] = 1
                self.assertFalse(runner.stage_gate(report, stage, descriptor()))
            for bad in ({}, [], {"historicalRead": []}, {"historicalRead": {"budgetExhausted": 1}}):
                report = passed(stage); report["gapCountsByOperation"] = bad
                self.assertFalse(runner.stage_gate(report, stage, descriptor()))

    def test_every_original_role_marker_is_required_exactly_once(self):
        for key in runner.MARKERS:
            for bad in (0, 2, True):
                report = passed("scan"); report["recoveryDesktopBetaState"]["typedCommittedMarkers"][key] = bad
                self.assertFalse(runner.stage_gate(report, "scan", descriptor()))
            report = passed("scan"); del report["recoveryDesktopBetaState"]["typedCommittedMarkers"][key]
            self.assertFalse(runner.stage_gate(report, "scan", descriptor()))
        report = passed("scan"); report["recoveryDesktopBetaState"]["typedCommittedMarkers"]["CHILD_PROMPT"] = 1
        self.assertFalse(runner.stage_gate(report, "scan", descriptor()))

    def test_fresh_reread_and_no_detector_rescan_are_independent(self):
        for key, bad in (("nativeBytesRead", 0), ("productionSessionCount", 1), ("threadListCalls", 1),
            ("itemReadCalls", 0), ("detectorScanCalls", 1), ("analysisReceiptCount", 15), ("occurrenceCount", 16),
            ("readerShutdown", False), ("sourceCount", True), ("parserContract", "old"),
            ("upstreamScannerSHA256", "a" * 64), ("rulesSHA256", "a" * 64)):
            report = passed("replay"); report["recoveryDesktopBetaState"][key] = bad
            self.assertFalse(runner.stage_gate(report, "replay", descriptor()), key)
        report = passed("scan"); report["recoveryDesktopBetaState"]["detectorScanCalls"] = 0
        self.assertFalse(runner.stage_gate(report, "scan", descriptor()))

    def test_replay_requires_both_exact_admissions_and_every_original_read(self):
        for key in ("initialAdmissionCount", "createdAuditCount", "successfulAdmissionCount", "consumedAdmissionCount"):
            for bad in (0, 1, 3, True, None):
                report = passed("replay"); report["recoveryDesktopBetaState"][key] = bad
                self.assertFalse(runner.stage_gate(report, "replay", descriptor()), key)
        for key, bad in (("canonicalGapEmissionCount", 0), ("canonicalGapEmissionCount", 2),
                         ("durableOmissionCount", 2), ("observedOriginalSourceCount", 0),
                         ("observedOriginalSourceCount", 15), ("expectedOriginalSourceCount", 17),
                         ("pipelineFailureCount", 1), ("normalizerCallCount", 1), ("queueClaimedCount", 1)):
            report = passed("replay"); report["recoveryDesktopBetaState"][key] = bad
            self.assertFalse(runner.stage_gate(report, "replay", descriptor()), key)
        report = passed("replay")
        report.update(settledHistoricalAuditCount=2, unreadHistoricalProgressCount=1, scopedGapCount=2,
            gapCountsByOperation={"historicalRead": {"budgetExhausted": 1, "unsupportedContent": 1}})
        report["recoveryDesktopBetaState"].update(threadReadCalls=1, itemReadCalls=0, productionSessionCount=1,
            canonicalGapEmissionCount=0, observedOriginalSourceCount=0)
        self.assertFalse(runner.stage_gate(report, "replay", descriptor()))

    def test_replay_requires_exact_inventory_and_fresh_emission_independently(self):
        for key in ("inventoryEqual", "receiptsEqual", "omissionEqual", "freshCanonicalGapObservedWithinReplay"):
            for bad in (False, 1, None):
                report = passed("replay"); report["recoveryDesktopBetaState"][key] = bad
                self.assertFalse(runner.stage_gate(report, "replay", descriptor()), key)
            report = passed("replay"); del report["recoveryDesktopBetaState"][key]
            self.assertFalse(runner.stage_gate(report, "replay", descriptor()), key)

    def test_beta_pass_cannot_promote_full_support_or_live_gui(self):
        for key in ("applicationRouteEstablished", "liveDesktopDispatchEstablished", "sideChatCoverageEstablished",
            "nativeChildIncomingInputEstablished", "sourceOpeningEstablished", "systemNotificationDeliveryEstablished", "fullCodexAcceptance"):
            report = passed("scan"); report["recoveryDesktopBetaState"][key] = True
            self.assertFalse(runner.stage_gate(report, "scan", descriptor()))

    def test_worker_has_only_fixed_desktop_coordinator_no_active_source_or_auth(self):
        root = Path("/private/tmp/spillcheck-desktop-beta-fake")
        command = runner.worker_command(Path("/fake/app"), root, "worker2", descriptor=descriptor(), reader=Path("/fake/reader"), stage="replay")
        self.assertIn("--acceptance-recovery-desktop-beta", command)
        self.assertEqual(command[command.index("--codex-interface") + 1], "desktop-code")
        self.assertEqual(command[command.index("--codex-home") + 1], "/fake-owned-home")
        self.assertNotIn("--codex-active-thread", command)
        self.assertNotIn("--auth-file", command)
        with self.assertRaises((ValueError, RuntimeError)):
            runner.worker_command(Path("/fake/app"), root, "worker1", descriptor=descriptor(), reader=Path("/fake/reader"), stage="replay")

    def test_historical_proof_reader_rejects_links_and_special_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source = root / "proof.json"; source.write_bytes(b"fake-proof")
            self.assertEqual(runner.proof_bytes(source), b"fake-proof")
            link = root / "symlink"; link.symlink_to(source)
            with self.assertRaises((OSError, RuntimeError)): runner.proof_bytes(link)
            hardlink = root / "hardlink"; os.link(source, hardlink)
            with self.assertRaises((OSError, RuntimeError)): runner.proof_bytes(source)
            hardlink.unlink()
            fifo = root / "fifo"; os.mkfifo(fifo)
            with self.assertRaises((OSError, RuntimeError)): runner.proof_bytes(fifo)

    def test_owned_source_selection_requires_pinned_proofs_before_any_run(self):
        with patch.object(runner, "proof_bytes", return_value=b"substituted-personal-history"):
            with self.assertRaises((ValueError, RuntimeError)):
                runner.ownership_descriptor(Path("/fake-home"))

    def test_complete_result_requires_cleanup_and_every_boundary(self):
        checks = {key: True for key in runner.REQUIRED_CHECKS}
        self.assertTrue(runner.completed_checks(checks))
        for key in checks:
            self.assertFalse(runner.completed_checks({name: value for name, value in checks.items() if name != key}), key)
            self.assertFalse(runner.completed_checks(checks | {key: 1}), key)

    def test_missing_or_failed_reader_shutdown_prevents_creator_cleanup(self):
        root = Path("/private/tmp/fake-desktop-beta")
        self.assertTrue(runner.worker_readers_stopped(root, 0))
        for state in ({}, {"readerStarted": True, "readerShutdown": False}, {"readerShutdown": True},
                      {"readerStarted": 0, "readerShutdown": True}):
            with patch.object(runner.shared, "private_json", return_value={"recoveryDesktopBetaState": state}):
                self.assertFalse(runner.worker_readers_stopped(root, 1))
        with patch.object(runner.shared, "private_json", side_effect=OSError()):
            self.assertFalse(runner.worker_readers_stopped(root, 1))
        for started in (False, True):
            with patch.object(runner.shared, "private_json", return_value={"recoveryDesktopBetaState": {"readerStarted": started, "readerShutdown": True}}):
                self.assertTrue(runner.worker_readers_stopped(root, 1))

    def test_owner_failure_does_not_start_reader_workers_or_touch_source_home(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            parent = Path(temporary).resolve(); root = parent / "owned"; root.mkdir(mode=0o700)
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
            owner.wait_report.side_effect = RuntimeError("owner unavailable")
            def version(*args, **kwargs):
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return runner.READER
            stack.enter_context(patch.object(runner, "ownership_descriptor", return_value=descriptor()))
            stack.enter_context(patch.object(runner, "proof_hashes", return_value=runner.PROOF_HASHES))
            stack.enter_context(patch.object(runner, "runner_hashes", return_value={}))
            stack.enter_context(patch.object(runner.shared, "AcceptanceArtifacts", return_value=artifacts))
            stack.enter_context(patch.object(runner.shared.preflight, "hash_file", return_value="a" * 64))
            stack.enter_context(patch.object(runner.shared.preflight, "read_manifest", return_value={"bundleSHA256": "a" * 64}))
            stack.enter_context(patch.object(runner.shared.preflight, "check", return_value={"consistent": True}))
            stack.enter_context(patch.object(runner.shared.live, "observe_version", side_effect=version))
            processes = stack.enter_context(patch.object(runner.setup, "ReportProcess", return_value=owner))
            stack.enter_context(patch.object(runner.lifecycle, "process_handoff"))
            cleanup = stack.enter_context(patch.object(runner.inventory, "cleanup_workers", return_value=([], [])))
            creator = stack.enter_context(patch.object(runner.inventory, "finish_creator", return_value=({}, False, True, False)))
            stack.enter_context(patch.object(runner.shared, "safe_creator_cleanup", return_value=True))
            result = runner.run(SimpleNamespace(app=app, executable=reader, candidate_manifest=manifest,
                expected_bundle_sha256="a" * 64, authorized_home=parent / "never-read-original-home",
                output=parent / "report.json", private_control=parent / "control.json"))
            self.assertEqual(result, 1)
            self.assertEqual(processes.call_count, 1)
            cleanup.assert_called_once_with([], root)
            self.assertFalse(creator.call_args.kwargs["ready_observed"])
            self.assertFalse(artifacts.report["passed"])
            self.assertFalse((parent / "never-read-original-home").exists())


if __name__ == "__main__": unittest.main()
