import base64
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

spec = importlib.util.spec_from_file_location("native_content_signed_runner", Path(__file__).with_name("run-app-codex-native-content.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
NATIVE = "11111111-1111-4111-8111-111111111111"
VERSION = "0.162.1"


def digest(number):
    return base64.b64encode(bytes([number]) * 32).decode()


def empty(kind="mcp"):
    state = {"measured": True, "truncated": False, "initialStoreEmpty": True,
        "fixtureKind": kind, "nativeKindEvidence": "same-response-native-content-descriptor",
        "parserContract": runner.PARSER,
        "detectorVersion": runner.DETECTOR, "cleanInventory": True, "allObservedTargetSourcesCommitted": False,
        "readerVersions": [], "producerVersions": [], "payloadRowCount": 0, "nativeTargetVerified": False}
    state.update({key: [] for key in (*runner.STATE_DIGESTS, *runner.TARGET_DIGESTS, *runner.INITIAL_DIGESTS)})
    state.update({key: 0 for key in ("receiptCount", "sourceCount", "sessionCount", "observedTargetSourceCount",
        "committedTargetSourceCount", "batchCount", "targetSegmentCount", "targetTextBytes", "nativeReadCount", "conversationLabelCount")})
    if kind == "local-image":
        state.update(expectedExcludedGapCount=0, excludedGapEventCount=0,
            expectedExcludedGapDigests=[], onlyExpectedExcludedMedia=True)
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "recoveryCodexPollingStopped": True, "coverageReportTruncated": False,
        "queueCount": 0, "recoveryQueueClaimedCount": 0, "recoveryCaptureIdentityMeasurementAvailable": True,
        "recoveryPendingCaptureDigests": [], "recoveryConsumedCaptureDigests": [],
        "recoverySuccessfullyProcessedCaptureDigests": [], "recoveryReceiptDigests": [],
        "recoveryOccurrenceDigests": [], "recoveryAlertDigests": [], "gapReasons": [], "valueCount": 0,
        "occurrenceCount": 0, "recoveryNativeContentEnabled": True, "recoveryNativeContentState": state}


def baseline(kind="mcp"):
    report = empty(kind)
    value = report["recoveryNativeContentState"]
    value.update(receiptCount=3, sourceCount=3, sessionCount=1, observedTargetSourceCount=1, committedTargetSourceCount=1,
        batchCount=1, targetSegmentCount=len(descriptor(kind)["segments"]),
        targetTextBytes=sum(v["textBytes"] for v in descriptor(kind)["segments"]), nativeReadCount=2, conversationLabelCount=1, nativeTargetVerified=True,
        readerVersions=[VERSION], producerVersions=[VERSION], allObservedTargetSourcesCommitted=True,
        receiptDigests=[digest(i) for i in range(10, 13)], sourceKindDigests=[digest(i) for i in range(20, 23)],
        sourceTimeDigests=[digest(i) for i in range(30, 33)], conversationLabelDigests=[digest(34)], targetSourceDigests=[digest(40)],
        targetResultDigests=[digest(41)], targetReceiptDigests=[digest(10)])
    if kind == "local-image":
        value.update(expectedExcludedGapCount=1, excludedGapEventCount=1, expectedExcludedGapDigests=[digest(80)])
    report.update(recoveryReceiptDigests=[digest(i) for i in range(50, 53)],
        recoveryConsumedCaptureDigests=[digest(60)], recoverySuccessfullyProcessedCaptureDigests=[digest(60)])
    return report


def cold(kind="mcp"):
    report = baseline(kind)
    value = report["recoveryNativeContentState"]
    value.update(initialStoreEmpty=False, initialReceiptDigests=list(value["receiptDigests"]),
        initialSourceKindDigests=list(value["sourceKindDigests"]), initialSourceTimeDigests=list(value["sourceTimeDigests"]), initialConversationLabelDigests=list(value["conversationLabelDigests"]), observedTargetSourceCount=0, committedTargetSourceCount=0,
        batchCount=0, nativeReadCount=0, targetSegmentCount=0, targetTextBytes=0, nativeTargetVerified=False,
        readerVersions=[], producerVersions=[], allObservedTargetSourcesCommitted=False)
    for key in runner.TARGET_DIGESTS:
        value[key] = []
    # Capture receipts persist in storage; successful-completion observations belong
    # to the worker process and start empty after a cold launch.
    report.update(recoverySuccessfullyProcessedCaptureDigests=[])
    report["recoveryNativeContentReplay"] = {"controlConsumed": False, "queued": False}
    return report


def replayed(kind="mcp"):
    report = baseline(kind)
    value = report["recoveryNativeContentState"]
    value.update(initialStoreEmpty=False, initialReceiptDigests=list(value["receiptDigests"]),
        initialSourceKindDigests=list(value["sourceKindDigests"]), initialSourceTimeDigests=list(value["sourceTimeDigests"]), initialConversationLabelDigests=list(value["conversationLabelDigests"]))
    report.update(recoveryConsumedCaptureDigests=[digest(60), digest(61)], recoverySuccessfullyProcessedCaptureDigests=[digest(61)])
    report["recoveryNativeContentReplay"] = {"controlConsumed": True, "queued": True, "auditDigest": digest(62),
        "captureDigest": digest(61), "batchCount": 1, "cleanBatches": True, "expectedSourceCount": 3,
        "observedSourceCount": 3, "allExpectedSourcesObserved": True, "completeProgress": True,
        "bytesRead": 5000, "completionObserved": True, "workCompleted": True, "successfulReadMatched": True,
        "nativeTargetReadAfterControl": True}
    return report


TURN = "22222222-2222-4222-8222-222222222222"


def descriptor(kind="mcp"):
    value = {"schemaVersion": 1, "fixtureKind": kind, "threadID": NATIVE, "turnID": TURN,
        "itemID": "original-item", "producerVersion": VERSION,
        "hookRunID": "native-hook-run" if kind == "hook-prompt" else "",
        "segments": [{"pointer": "/text", "textSHA256": "a" * 64, "textBytes": 107}]
            if kind == "plan" else runner.expected_segments(kind)}
    if kind == "local-image":
        value["imageSHA256"] = runner.media.digest(runner.media.png_fixture())
    return value


def media_descriptor():
    return {"schemaVersion": 1, "threadID": NATIVE, "turnID": TURN,
        "itemID": "original-item", "producerVersion": VERSION,
        "textSHA256": runner.media.digest(runner.media.PROMPT.encode()),
        "textBytes": len(runner.media.PROMPT.encode()), "imageSHA256": runner.media.digest(runner.media.png_fixture())}


class NativeContentBoundaryTests(unittest.TestCase):
    def test_hook_descriptor_uses_original_native_export_after_two_reads_and_shutdown(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(mode=0o700)
            control = root / "control"; control.mkdir(mode=0o700)
            value = descriptor("hook-prompt"); value["turnID"] = "rollout-original-turn"
            passive = {key: True for key in runner.hook.PASSIVE_CHECKS}
            passive.update(status="native-hook-prompt-read-and-replayed", parserContract=runner.PARSER,
                readerVersion=VERSION, producerVersion=VERSION, gapReasons=[], gapDiagnostics=[],
                nativeTurnEqualsStopCallbackTurn=False, threadReadCalls=2, itemReadCalls=2, turnReadCalls=2,
                threadListCalls=0, resumeCalls=0, hookPromptItemCount=1, hookPromptSourceCount=1, segmentCount=1,
                segmentPointers=["/fragments/0/text"], textBytes=len(runner.hook.fixture.REASON.encode()),
                textSHA256=runner.mcp.digest(runner.hook.fixture.REASON.encode()))
            def read_owned(command, **kwargs):
                self.assertIn("--skip-build", command)
                self.assertEqual(kwargs["environment"]["SPILLCHECK_HOOK_PROBE_DESCRIPTOR"], str(root / "native-content-descriptor.json"))
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                runner.mcp.write_json(control / "passive-report.json", passive)
                runner.mcp.exclusive(root / "native-content-descriptor.json", runner.descriptor_bytes(value))
                return 0, b"discarded", b""
            with patch.object(runner.shared.live, "bounded", side_effect=read_owned), \
                    patch.object(runner.hook, "callback_rows", return_value=[]), \
                    patch.object(runner.hook, "callbacks_stopped", return_value=True):
                actual, report = runner.discover_hook_descriptor(Path("/codex"), home, root, control,
                    {"threadID": NATIVE, "callbackTurnID": TURN}, Path("/scratch"), runner.producer_lifetime())
            self.assertEqual(actual, value)
            self.assertNotEqual(actual["turnID"], TURN)
            self.assertTrue(report["actualSecondRead"])

    def test_hook_discovery_refuses_authentication_or_unknown_process_lifetime(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(mode=0o700)
            (home / "auth.json").write_text("fake-only")
            with patch.object(runner.shared.live, "bounded") as bounded:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.discover_hook_descriptor(Path("/codex"), home, root, root / "control",
                        {"threadID": NATIVE}, Path("/scratch"), runner.producer_lifetime())
            bounded.assert_not_called()
            (home / "auth.json").unlink()
            life = runner.producer_lifetime(); life["childrenStopped"] = False
            with patch.object(runner.shared.live, "bounded") as bounded:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.discover_hook_descriptor(Path("/codex"), home, root, root / "control",
                        {"threadID": NATIVE}, Path("/scratch"), life)
            bounded.assert_not_called()

    def test_failed_discovery_reader_blocks_creator_cleanup(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(mode=0o700)
            def fail(*args, **kwargs):
                kwargs["cleanup_report"].update(leaderExited=False, groupKillPermissionDenied=False)
                raise RuntimeError("controlled reader failure")
            life = runner.producer_lifetime()
            with patch.object(runner.shared.live, "bounded", side_effect=fail), \
                    patch.object(runner.hook, "callback_rows", return_value=[]), \
                    patch.object(runner.hook, "callbacks_stopped", return_value=True):
                with self.assertRaises(RuntimeError):
                    runner.discover_hook_descriptor(Path("/codex"), home, root, root / "control",
                        {"threadID": NATIVE}, Path("/scratch"), life)
            self.assertFalse(life["descriptorReaderStopped"])
            self.assertFalse(runner.all_source_processes_stopped(life))

    def test_owner_failure_happens_before_authentication_or_provider(self):
        self.exercise_lifecycle_failure(owner_fails=True)

    def test_unconfirmed_child_retains_authentication_and_disallows_creator_cleanup(self):
        self.exercise_lifecycle_failure(owner_fails=False)

    def exercise_lifecycle_failure(self, *, owner_fails):
        # Exercise run/finally ordering with no subprocess or system key operation.
        with tempfile.TemporaryDirectory() as parent:
            parent = Path(parent); root = parent / "owned"; root.mkdir(mode=0o700)
            app = parent / "app"; app.mkdir(); reader = parent / "codex"; reader.touch()
            manifest = parent / "manifest.json"; manifest.write_text("{}")
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
                expected_bundle_sha256="a" * 64, expected_version=VERSION, model="gpt-6-astra", fixture="mcp",
                auth_file=parent / "never-read-auth", output=parent / "report.json",
                private_control=parent / "control.json", scratch_path=parent / "scratch")
            def version(*args, **kwargs):
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return VERSION
            def producer(*args):
                life = args[-2]; life.update(providerLaunchCount=1, producerStopped=True, childrenStopped=False)
                raise RuntimeError("independent child still present")
            def refresh(kind, root, control, life):
                life["childrenStopped"] = life["providerLaunchCount"] == 0
                return life["childrenStopped"]
            with ExitStack() as stack:
                def stub(obj, name, **kwargs): return stack.enter_context(patch.object(obj, name, **kwargs))
                stub(runner.shared, "AcceptanceArtifacts", return_value=artifacts)
                stub(runner.shared.preflight, "hash_file", return_value="a" * 64)
                stub(runner.shared.preflight, "read_manifest", return_value={"bundleSHA256": "a" * 64})
                stub(runner.shared.preflight, "check", return_value={"consistent": True})
                stub(runner, "runner_hashes", return_value={})
                stub(runner.shared.live, "observe_version", side_effect=version)
                stub(runner.setup, "ReportProcess", return_value=owner)
                stub(runner.lifecycle, "process_handoff")
                stub(runner.inventory, "cleanup_workers", return_value=([], []))
                finish = stub(runner.inventory, "finish_creator", return_value=({}, False, True, False))
                auth = stub(runner.shared, "private_bytes", return_value=b'{"fake":"never-used-for-provider"}')
                produce = stub(runner, "run_producer", side_effect=producer)
                stub(runner, "refresh_children", side_effect=refresh)
                self.assertEqual(runner.run(args), 1)
                self.assertFalse(artifacts.report["passed"])
                if owner_fails:
                    auth.assert_not_called(); produce.assert_not_called()
                    self.assertEqual(artifacts.report["providerLaunchCount"], 0)
                    self.assertFalse((root / "home/auth.json").exists())
                else:
                    self.assertTrue((root / "home/auth.json").exists())
                    self.assertFalse(finish.call_args.kwargs["authorized"])
                    self.assertFalse(artifacts.report["checks"]["independentProducerChildrenStopped"])
                    self.assertFalse(artifacts.report["temporaryAuthenticationRemoved"])
    def test_routes_are_fixture_bound_private_cli_workers_without_cleanup_authority(self):
        for kind in runner.PROFILES:
            for name in ("worker1", "worker2"):
                cmd = runner.worker_command(Path("/app"), Path("/owned"), name, home=Path("/owned/home"),
                    descriptor=Path("/owned/native-content-descriptor.json"), reader=Path("/codex"),
                    version=VERSION, fixture=kind)
                self.assertEqual(cmd[cmd.index("--codex-profile") + 1], runner.PROFILES[kind])
                self.assertEqual(cmd[cmd.index("--codex-authorized-host") + 1], "standalone-cli")
                self.assertEqual(cmd.count("--codex-authorized-host"), 1)
                self.assertIn("--acceptance-no-profile-catchup", cmd)
                self.assertEqual("--acceptance-allow-history-request" in cmd, name == "worker1")
                self.assertFalse(any("cleanup-new-vault" in arg or "vault-owner" in arg or "install-profile" in arg for arg in cmd))
                for forbidden in ("--codex-active-thread", "--codex-t3-version", "--acceptance-recovery-plan"):
                    self.assertNotIn(forbidden, cmd)
        for home, file in (("/personal/home", "/owned/native-content-descriptor.json"),
                           ("/owned/home", "/outside/native-content-descriptor.json")):
            with self.assertRaises(runner.shared.GateFailure):
                runner.worker_command(Path("/app"), Path("/owned"), "worker1", home=Path(home),
                    descriptor=Path(file), reader=Path("/codex"), version=VERSION, fixture="mcp")

    def test_descriptors_bind_complete_fixed_segments_not_just_text_markers(self):
        for kind in ("mcp", "hook-prompt"):
            value = descriptor(kind)
            self.assertEqual(runner.validate_descriptor(value, kind), value)
            self.assertEqual(len(value["segments"]), 11 if kind == "mcp" else 1)
            if kind == "hook-prompt": self.assertEqual(value["segments"][0]["textBytes"], 191)
            for field, bad in (("schemaVersion", True), ("threadID", "unowned"), ("turnID", ""),
                ("itemID", "item\n"), ("producerVersion", "0.1"), ("segments", []), ("fixtureKind", "other")):
                changed = copy.deepcopy(value); changed[field] = bad
                with self.subTest(kind=kind, field=field), self.assertRaises(runner.shared.GateFailure):
                    runner.validate_descriptor(changed, kind)
            for key, bad in (("pointer", "/assistant/echo"), ("textSHA256", "b" * 64), ("textBytes", 1)):
                changed = copy.deepcopy(value); changed["segments"][0][key] = bad
                with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(changed, kind)
            changed = copy.deepcopy(value); changed["segments"].append(copy.deepcopy(value["segments"][0]))
            with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(changed, kind)
        wrong = descriptor("mcp"); wrong["hookRunID"] = "hook"
        with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(wrong, "mcp")
        wrong = descriptor("hook-prompt"); wrong["hookRunID"] = ""
        with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(wrong, "hook-prompt")

    def test_plan_descriptor_binds_completed_producer_identity_and_independent_bytes(self):
        observed = SimpleNamespace(thread=NATIVE, turn=TURN, plan={"itemID": "original-item",
            "textSHA256": "a" * 64, "textBytes": 107})
        public = {"nativePlanCompleted": True, "normalProducerShutdown": True, "completedPlanCount": 1,
            "unexpectedToolRequests": 0, "planTextSHA256": "a" * 64, "planTextBytes": 107}
        args = ("plan", Path("/codex"), Path("/owned/home"), Path("/owned/work"), Path("/owned"), "fake-model")
        with patch.object(runner.plan, "produce", return_value=(observed, public)) as produce:
            value, actual = runner.run_producer(*args, runner.producer_lifetime(), Path("/owned/control"))
        self.assertEqual(value, descriptor("plan")); self.assertEqual(actual, public)
        produce.assert_called_once()
        for key, bad in (("nativePlanCompleted", False), ("normalProducerShutdown", False),
                ("completedPlanCount", 2), ("completedPlanCount", True), ("unexpectedToolRequests", 1),
                ("planTextSHA256", "b" * 64), ("planTextBytes", 108)):
            changed = dict(public); changed[key] = bad
            with self.subTest(key=key), self.assertRaises(runner.shared.GateFailure):
                runner.plan_descriptor(observed, changed)
        # The Plan text is chosen by the provider, so it has no fixed fixture hash.
        observed.plan.update(textSHA256="b" * 64, textBytes=16384)
        public.update(planTextSHA256="b" * 64, planTextBytes=16384)
        self.assertEqual(runner.plan_descriptor(observed, public)["segments"][0]["textBytes"], 16384)
        for key, bad in (("thread", "not-native"), ("turn", "../source")):
            changed = copy.deepcopy(observed); setattr(changed, key, bad)
            with self.assertRaises(runner.shared.GateFailure): runner.plan_descriptor(changed, public)
        for bad in ("id with space", "plan-🧪", "", "x" * 257):
            changed = copy.deepcopy(observed); changed.plan["itemID"] = bad
            with self.assertRaises(runner.shared.GateFailure): runner.plan_descriptor(changed, public)
        for key, bad in (("pointer", "/assistant/echo"), ("textSHA256", "invalid"), ("textSHA256", "A" * 64),
                ("textBytes", 0), ("textBytes", 16385), ("textBytes", True)):
            changed = descriptor("plan"); changed["segments"][0][key] = bad
            with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(changed, "plan")
        for key, bad in (("segments", []), ("segments", descriptor("plan")["segments"] * 2),
                ("hookRunID", "unexpected-hook")):
            changed = descriptor("plan"); changed[key] = bad
            with self.assertRaises(runner.shared.GateFailure): runner.validate_descriptor(changed, "plan")

    def test_plan_shutdown_uncertainty_prevents_authentication_and_creator_cleanup(self):
        life = runner.producer_lifetime()
        def fail(*args):
            args[-2].update(providerLaunchCount=1, producerStopped=False)
            raise runner.plan.ProbeFailure("native-plan-incomplete")
        with patch.object(runner.plan, "produce", side_effect=fail) as produce:
            with self.assertRaises(runner.plan.ProbeFailure):
                runner.run_producer("plan", Path("/codex"), Path("/owned/home"), Path("/owned/work"),
                    Path("/owned"), "fake-model", life, Path("/owned/control"))
        produce.assert_called_once()
        self.assertEqual(life["providerLaunchCount"], 1)
        self.assertFalse(runner.all_source_processes_stopped(life))
        life["producerStopped"] = True
        self.assertTrue(runner.refresh_children("plan", Path("/owned"), Path("/owned/control"), life))
        self.assertTrue(runner.all_source_processes_stopped(life))

    def test_plan_cli_preserves_required_arguments_through_shared_lifecycle(self):
        compatibility = runner.load("native_plan_compatibility", Path(__file__).with_name("run-app-codex-plan.py"))
        argv = []
        for name in ("app", "candidate-manifest", "executable", "auth-file", "output", "private-control"):
            argv += ["--" + name, "/owned/" + name]
        argv += ["--expected-bundle-sha256", "a" * 64, "--expected-version", VERSION, "--model", "fake-model"]
        with patch.object(compatibility.runner, "run", return_value=0) as run:
            self.assertEqual(compatibility.main(argv), 0)
        args = run.call_args.args[0]
        self.assertEqual(args.fixture, "plan")
        self.assertEqual(args.output, Path("/owned/output"))
        self.assertEqual(args.expected_version, VERSION)

    def test_native_descriptor_encoding_is_canonical_and_bounded(self):
        for kind in runner.PROFILES:
            value = descriptor(kind); raw = runner.descriptor_bytes(value)
            self.assertEqual(raw, json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
            self.assertFalse(raw.endswith(b"\n")); self.assertLess(len(raw), 8192)
            value["unexpected"] = "not accepted"
            with self.assertRaises(runner.shared.GateFailure): runner.descriptor_bytes(value)

    def test_mcp_producer_requires_actual_completed_result_and_independent_child_stop(self):
        observed = SimpleNamespace(thread=NATIVE, turn=TURN, mcp={"itemID": "original-item"})
        public = {"nativeMCPCompleted": True, "normalProducerShutdown": True, "completedMCPCount": 1,
            "unexpectedToolRequests": 0, "protocolTextAndOpaqueBusinessResultMatched": True}
        args = ("mcp", Path("/codex"), Path("/owned/home"), Path("/owned/work"), Path("/owned"), "gpt-6-astra")
        with patch.object(runner.mcp, "produce", return_value=(observed, public)), \
                patch.object(runner.mcp, "confirm_mcp_stopped", return_value=True) as child:
            value, _ = runner.run_producer(*args, runner.producer_lifetime(), Path("/owned/control"))
            self.assertEqual(value, descriptor())
            self.assertTrue(any(call.kwargs.get("require_invocation") is True for call in child.call_args_list))
        with patch.object(runner.mcp, "produce", return_value=(observed, public)), \
                patch.object(runner.mcp, "confirm_mcp_stopped", return_value=False):
            life = runner.producer_lifetime()
            with self.assertRaises(runner.shared.GateFailure):
                runner.run_producer(*args, life, Path("/owned/control"))
            self.assertFalse(runner.all_source_processes_stopped(life))
        bad = dict(public); bad["protocolTextAndOpaqueBusinessResultMatched"] = False
        with patch.object(runner.mcp, "produce", return_value=(observed, bad)), \
                patch.object(runner.mcp, "confirm_mcp_stopped", return_value=True):
            with self.assertRaises(runner.shared.GateFailure):
                runner.run_producer(*args, runner.producer_lifetime(), Path("/owned/control"))

    def test_failed_producer_cannot_report_children_stopped(self):
        life = runner.producer_lifetime(); life["producerStopped"] = False
        with patch.object(runner.mcp, "confirm_mcp_stopped") as check:
            self.assertFalse(runner.refresh_children("mcp", Path("/owned"), Path("/owned/control"), life))
        check.assert_not_called(); self.assertFalse(runner.all_source_processes_stopped(life))
        for field in ("producerStopped", "childrenStopped", "descriptorReaderStopped"):
            life = runner.producer_lifetime(); life[field] = False
            self.assertFalse(runner.all_source_processes_stopped(life), field)

    def test_callback_uncertainty_blocks_authentication_and_creator_cleanup_gate(self):
        for returned in (False, RuntimeError("invalid recorded process")):
            life = runner.producer_lifetime()
            with patch.object(runner.hook, "callback_rows", return_value=[{}]), \
                    patch.object(runner.hook, "callbacks_stopped", side_effect=returned if isinstance(returned, Exception) else None,
                                 return_value=False):
                self.assertFalse(runner.refresh_children("hook-prompt", Path("/owned"), Path("/owned/control"), life))
                self.assertFalse(runner.all_source_processes_stopped(life))

    def test_fresh_worker_requires_selected_fixture_and_no_prior_evidence(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.fresh(empty(kind), kind))
            self.assertFalse(runner.fresh(empty(kind), "other"))
            for key in (*runner.STATE_DIGESTS, *runner.TARGET_DIGESTS, *runner.INITIAL_DIGESTS):
                value = empty(kind); value["recoveryNativeContentState"][key] = [digest(9)]
                self.assertFalse(runner.fresh(value, kind), key)
            for key, bad in (("nativeReadCount", 1), ("nativeTargetVerified", True), ("initialStoreEmpty", False)):
                value = empty(kind); value["recoveryNativeContentState"][key] = bad
                self.assertFalse(runner.fresh(value, kind))

    def test_scanned_requires_all_native_segments_and_full_current_receipt(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.scanned(baseline(kind), VERSION, descriptor(kind)))
            for key, bad in (("detectorVersion", runner.DETECTOR + "+partial"), ("parserContract", "old"),
                ("targetSegmentCount", 0), ("targetTextBytes", 1), ("nativeReadCount", 0), ("nativeTargetVerified", False),
                ("allObservedTargetSourcesCommitted", False), ("targetReceiptDigests", []),
                ("targetReceiptDigests", [digest(99)]),
                ("nativeKindEvidence", "text-echo"), ("cleanInventory", False), ("payloadRowCount", 1),
                ("readerVersions", ["old"]), ("producerVersions", ["old"]), ("sessionCount", 2), ("truncated", True)):
                value = baseline(kind); value["recoveryNativeContentState"][key] = bad
                self.assertFalse(runner.scanned(value, VERSION, descriptor(kind)), (kind, key))
            other = "mcp" if kind == "hook-prompt" else "hook-prompt"
            self.assertFalse(runner.scanned(baseline(kind), VERSION, descriptor(other)))

    def test_cold_restart_must_restore_state_before_native_reads(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.cold_restored(baseline(kind), cold(kind)))
            for key, bad in (("nativeReadCount", 1), ("batchCount", 1), ("nativeTargetVerified", True),
                ("targetSourceDigests", [digest(40)]), ("initialReceiptDigests", []),
                ("initialSourceTimeDigests", []), ("initialConversationLabelDigests", [])):
                value = cold(kind); value["recoveryNativeContentState"][key] = bad
                self.assertFalse(runner.cold_restored(baseline(kind), value), key)

    def test_cold_restart_preserves_consumed_receipts_but_has_no_process_local_completions(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.cold_restored(baseline(kind), cold(kind)))
            for invalid in ([], [digest(61)], [digest(60), digest(61)], [digest(60), digest(60)], ["bad"], None):
                value = cold(kind); value["recoveryConsumedCaptureDigests"] = invalid
                self.assertFalse(runner.cold_restored(baseline(kind), value), (kind, invalid))
            for invalid in ([], [digest(60), digest(60)], ["bad"], None):
                before, after = baseline(kind), cold(kind)
                before["recoveryConsumedCaptureDigests"] = after["recoveryConsumedCaptureDigests"] = invalid
                self.assertFalse(runner.cold_restored(before, after), (kind, invalid))
            value = cold(kind); del value["recoveryConsumedCaptureDigests"]
            self.assertFalse(runner.cold_restored(baseline(kind), value), kind)
            for completed in ([digest(60)], [digest(61)]):
                value = cold(kind); value["recoverySuccessfullyProcessedCaptureDigests"] = completed
                self.assertFalse(runner.cold_restored(baseline(kind), value), (kind, completed))

    def test_replay_preserves_prior_consumption_and_requires_exactly_one_new_completion(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.replayed(baseline(kind), cold(kind), replayed(kind), VERSION, descriptor(kind)))
            for consumed in ([digest(61)], [digest(60)], [digest(60), digest(62)], [digest(60), digest(61), digest(62)]):
                value = replayed(kind); value["recoveryConsumedCaptureDigests"] = consumed
                self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)), (kind, consumed))
            value = replayed(kind)
            value["recoverySuccessfullyProcessedCaptureDigests"] = [digest(60), digest(61)]
            self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)), kind)

    def test_replay_requires_new_capture_actual_native_read_and_complete_audit(self):
        for kind in runner.PROFILES:
            self.assertTrue(runner.replayed(baseline(kind), cold(kind), replayed(kind), VERSION, descriptor(kind)))
            for key in ("controlConsumed", "queued", "cleanBatches", "allExpectedSourcesObserved", "completeProgress",
                    "completionObserved", "workCompleted", "successfulReadMatched", "nativeTargetReadAfterControl"):
                value = replayed(kind); value["recoveryNativeContentReplay"][key] = False
                self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)), key)
            for key, bad in (("bytesRead", 0), ("batchCount", True), ("expectedSourceCount", 2),
                             ("observedSourceCount", 2), ("auditDigest", digest(61))):
                value = replayed(kind); value["recoveryNativeContentReplay"][key] = bad
                self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)), key)
            value = replayed(kind); value["recoverySuccessfullyProcessedCaptureDigests"] = []
            self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)))

    def test_replay_rejects_receipt_source_and_inventory_mutations(self):
        for kind in runner.PROFILES:
            for key in (*runner.STATE_DIGESTS, *runner.TARGET_DIGESTS):
                value = replayed(kind); value["recoveryNativeContentState"][key][0] = digest(99)
                self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)), key)
            value = replayed(kind); value["recoveryManifestDigest"] = digest(99)
            self.assertFalse(runner.replayed(baseline(kind), cold(kind), value, VERSION, descriptor(kind)))

    def test_complete_check_set_cannot_omit_cleanup_or_accept_truthy_values(self):
        good = {key: True for key in runner.REQUIRED_CHECKS}
        self.assertTrue(runner.completed_checks(good))
        for key in good:
            value = dict(good); value.pop(key)
            self.assertFalse(runner.completed_checks(value), key)
            value = dict(good); value[key] = 1
            self.assertFalse(runner.completed_checks(value), key)


    def test_descriptor_binds_native_identity_exact_utf8_and_fake_image(self):
        value = media_descriptor()
        self.assertEqual(runner.media_descriptor(value), descriptor("local-image"))
        for field, bad in (("schemaVersion", True), ("threadID", "unowned"), ("turnID", ""),
            ("itemID", "item\n"), ("producerVersion", "0.1"), ("textSHA256", "b" * 64),
            ("textBytes", True), ("textBytes", 1), ("imageSHA256", "a" * 64)):
            changed = dict(value); changed[field] = bad
            with self.subTest(field=field), self.assertRaises(runner.shared.GateFailure):
                runner.media_descriptor(changed)
        value["unexpected"] = "not accepted"
        with self.assertRaises(runner.shared.GateFailure): runner.media_descriptor(value)

    def test_image_removal_only_accepts_exact_fixture(self):
        with tempfile.TemporaryDirectory() as parent:
            work = Path(parent); image = work / "fixture.png"
            image.write_bytes(runner.media.png_fixture()); image.chmod(0o600)
            self.assertTrue(runner.remove_image(work)); self.assertFalse(image.exists())
            image.write_bytes(b"different"); image.chmod(0o600)
            with self.assertRaises(runner.shared.GateFailure): runner.remove_image(work)
            self.assertTrue(image.exists())

    def test_discovery_requires_auth_and_image_absence_and_stopped_producer(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(); work = root / "work"; work.mkdir()
            for file in (home / "auth.json", work / "fixture.png"):
                file.write_bytes(b"fake")
                with patch.object(runner.shared.live, "bounded") as bounded:
                    with self.assertRaises(runner.shared.GateFailure):
                        runner.discover_media_descriptor(Path("/codex"), home, root, root / "control", {}, root, runner.producer_lifetime())
                    bounded.assert_not_called()
                file.unlink()
            life = runner.producer_lifetime(); life["producerStopped"] = False
            with patch.object(runner.shared.live, "bounded") as bounded:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.discover_media_descriptor(Path("/codex"), home, root, root / "control", {}, root, life)
                bounded.assert_not_called()

    def test_descriptor_discovery_binds_persisted_identity_not_live_notification_id(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent); home = root / "home"; home.mkdir(mode=0o700)
            control = root / "control"; control.mkdir(mode=0o700)
            value = media_descriptor(); passive = {key: True for key in runner.media.PASSIVE_CHECKS}
            passive.update(runner.media.COUNTS); passive.update({key: False for key in runner.media.LIMITS})
            passive.update(status="native-local-image-read-and-replayed", parserContract=runner.PARSER,
                readerVersion=VERSION, producerVersion=VERSION, textSHA256=value["textSHA256"], textBytes=value["textBytes"],
                suppliedImageSHA256=value["imageSHA256"], gapReasons=["unsupportedContent"],
                gapDiagnostics=["excludedBinaryContent"], liveItemIDMatchesNative=False, timestampBasis="matching-turn-interval")
            def read_owned(command, **kwargs):
                self.assertIn("CodexLocalMediaLiveTests", command)
                self.assertEqual(kwargs["environment"]["SPILLCHECK_LOCAL_MEDIA_PROBE_DESCRIPTOR"], str(root / "local-media-descriptor.json"))
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                runner.media.write_json(control / "passive-report.json", passive)
                runner.media.base.exclusive(root / "local-media-descriptor.json", json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
                return 0, b"discarded", b""
            with patch.object(runner.shared.live, "bounded", side_effect=read_owned):
                actual, report = runner.discover_media_descriptor(Path("/codex"), home, root, control,
                    {"threadID": NATIVE, "turnID": TURN, "liveItemID": "different-live-id"}, root, runner.producer_lifetime())
            self.assertEqual(actual, descriptor("local-image")); self.assertFalse(report["liveItemIDMatchesNative"])

    def test_exact_excluded_gap_is_required_and_persists_through_replay(self):
        self.assertTrue(runner.replayed(baseline("local-image"), cold("local-image"), replayed("local-image"), VERSION, descriptor("local-image")))
        for key, bad in (("onlyExpectedExcludedMedia", False), ("expectedExcludedGapCount", 0),
            ("excludedGapEventCount", 0), ("excludedGapEventCount", 129), ("expectedExcludedGapDigests", []),
            ("expectedExcludedGapDigests", [digest(99)])):
            value = replayed("local-image"); value["recoveryNativeContentState"][key] = bad
            self.assertFalse(runner.replayed(baseline("local-image"), cold("local-image"), value, VERSION, descriptor("local-image")), key)
        value = replayed("local-image"); value["gapReasons"] = ["sourceUnavailable"]
        self.assertFalse(runner.replayed(baseline("local-image"), cold("local-image"), value, VERSION, descriptor("local-image")))
        value = replayed("local-image"); value["recoveryNativeContentState"]["excludedGapEventCount"] = 2
        self.assertTrue(runner.replayed(baseline("local-image"), cold("local-image"), value, VERSION, descriptor("local-image")))

    def test_media_required_checks_include_image_removal_and_persisted_exclusion(self):
        checks = {key: True for key in runner.REQUIRED_CHECKS | runner.MEDIA_CHECKS}
        self.assertTrue(runner.completed_checks(checks, "local-image"))
        for key in runner.MEDIA_CHECKS:
            changed = dict(checks); del changed[key]
            self.assertFalse(runner.completed_checks(changed, "local-image"))
        value = empty("local-image")
        value["recoveryNativeContentState"].update(expectedExcludedGapCount=1,
            excludedGapEventCount=1, expectedExcludedGapDigests=[digest(80)])
        self.assertFalse(runner.fresh(value, "local-image"))
