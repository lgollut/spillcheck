import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("review_probe", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
THREAD = "00000000-0000-4000-8000-000000000001"
TURN = "00000000-0000-4000-8000-000000000002"
OTHER = "00000000-0000-4000-8000-000000000003"
TEXT = probe.MARKER + ": harmless review.\nUnicode café."


def thread_result():
    return {"model": "gpt-6-astra", "cwd": "/owned/work", "thread": {"id": THREAD,
        "cwd": "/owned/work", "cliVersion": probe.VERSION, "parentThreadId": None,
        "forkedFromId": None, "ephemeral": False}}


def event(kind="agentMessage", **changes):
    item = {"type": kind, "id": "msg-live", "text": TEXT, "phase": None}
    if kind == "exitedReviewMode":
        item = {"type": kind, "id": "exit-live", "review": TEXT}
    elif kind == "enteredReviewMode":
        item = {"type": kind, "id": "enter-live", "review": probe.INSTRUCTIONS}
    elif kind == "userMessage":
        item = {"type": kind, "id": "input-live", "content": [{"type": "text", "text": probe.INSTRUCTIONS}]}
    item.update(changes)
    return {"method": "item/completed", "params": {"threadId": THREAD, "turnId": TURN, "item": item}}


def observed():
    value = probe.Observation()
    value.bind_thread(thread_result(), "gpt-6-astra", Path("/owned/work"))
    value.bind_turn({"turn": {"id": TURN}, "reviewThreadId": THREAD})
    return value


def finish(value, *, with_input=True):
    if with_input:
        value.event(event("enteredReviewMode")); value.event(event("userMessage"))
    value.event({"method": "turn/completed", "params": {"threadId": THREAD,
        "turn": {"id": TURN, "status": "completed", "error": None}}})


def passive():
    value = {key: True for key in probe.PASSIVE_CHECKS}
    value.update({key: True for key in probe.INPUT_CHECKS})
    value.update({key: False for key in probe.PASSIVE_LIMITS})
    value.update(status="native-review-read-and-replayed", parserContract=probe.PARSER,
        readerVersion=probe.VERSION, producerVersion=probe.VERSION, reviewItemCount=1,
        reviewSourceCount=1, threadReadCalls=2, itemReadCalls=2, turnReadCalls=2,
        threadListCalls=0, resumeCalls=0, forkCalls=0, presentationSourceCount=0,
        presentationItemCount=2, otherItemKindCount=0, gapReasons=[], gapDiagnostics=[],
        selectionBasis="unique-owned-turn-null-phase-live-bytes", liveItemIDEqualsPersistedItemID=False,
        timeEvidence="matching-turn-interval", reviewTextBytes=len(TEXT.encode()),
        reviewTextSHA256=probe.digest(TEXT.encode()), inputItemCount=1, inputSourceCount=1,
        totalOriginalSourceCount=2, inputTextSHA256=probe.digest(probe.INSTRUCTIONS.encode()),
        inputTextBytes=len(probe.INSTRUCTIONS.encode()), inputTimeEvidence="matching-turn-interval",
        inputGapReasons=[], inputGapDiagnostics=[], inputTurnRelation="same-review-turn", inputTurnMatchesReviewTurn=True)
    return value


class ReviewBoundaryTests(unittest.TestCase):
    def test_closed_input_diagnostics_exclude_native_content_and_invalid_types(self):
        value = {"inputDiagnostic": {"nativeTurnMatchesReview": False, "inputTextBytes": 561,
            "inputTextSHA256": "a" * 64, "rawText": TEXT, "nativeTurn": TURN,
            "userItemCount": True, "enteredItemCount": -1, "inputBytesMatch": "true"},
            "rawText": TEXT}
        self.assertEqual(probe.public_passive(value), {"inputDiagnostic": {
            "nativeTurnMatchesReview": False, "inputTextBytes": 561, "inputTextSHA256": "a" * 64}})
        for bad in [TEXT, "a" * 63, "A" * 64, None]:
            self.assertEqual(probe.public_passive({"inputDiagnostic": {"inputTextSHA256": bad}}),
                             {"inputDiagnostic": {}})
        self.assertEqual(probe.public_passive({"inputDiagnostic": TEXT}), {})

    def test_inline_self_contained_request_has_no_repository_target(self):
        value = probe.review_parameters(THREAD)
        self.assertEqual(value, {"threadId": THREAD, "delivery": "inline",
            "target": {"type": "custom", "instructions": probe.INSTRUCTIONS}})
        self.assertIn("Do not use tools", probe.INSTRUCTIONS)
        self.assertEqual(probe.INSTRUCTIONS.count(probe.MARKER), 1)

    def test_live_review_requires_original_null_phase_and_identical_rendered_bytes(self):
        value = observed()
        value.event(event("exitedReviewMode")); value.event(event()); finish(value)
        result = value.complete()
        self.assertTrue(result["nativeReviewCompleted"])
        self.assertTrue(result["liveReviewAndMessageBytesMatch"])
        self.assertEqual(result["textBytes"], len(TEXT.encode()))
        for private in [THREAD, TURN, "msg-live", TEXT, probe.MARKER]:
            self.assertNotIn(private, json.dumps(result))

    def test_live_selection_is_not_an_echo_or_presentation_only(self):
        for phase in ["final_answer", "commentary", "partial_answer"]:
            value = observed(); value.event(event("exitedReviewMode")); value.event(event(phase=phase)); finish(value)
            with self.subTest(phase=phase), self.assertRaises(probe.ProbeFailure): value.complete()
        value = observed(); value.event(event("exitedReviewMode")); finish(value)
        with self.assertRaises(probe.ProbeFailure): value.complete()

    def test_phase_must_be_explicit_null_not_missing_or_unknown(self):
        for phase in ["missing", "unknown", 0, {}, []]:
            item = event()
            if phase == "missing": del item["params"]["item"]["phase"]
            else: item["params"]["item"]["phase"] = phase
            with self.subTest(phase=phase), self.assertRaises(probe.ProbeFailure): observed().event(item)

    def test_unique_bounded_review_bytes_required(self):
        for text in [None, "", "unrelated", probe.MARKER * 2, probe.MARKER + "a" * 16384]:
            with self.subTest(text=str(text)[:30]), self.assertRaises(probe.ProbeFailure):
                observed().event(event(text=text))
        value = observed(); value.event(event())
        with self.assertRaises(probe.ProbeFailure): value.event(event(id="other-null"))
        value = observed(); value.event(event("exitedReviewMode"))
        with self.assertRaises(probe.ProbeFailure): value.event(event("exitedReviewMode"))

    def test_changed_review_bytes_cannot_pass(self):
        value = observed(); value.event(event("exitedReviewMode"))
        value.event(event(text=TEXT + " changed")); finish(value)
        with self.assertRaises(probe.ProbeFailure): value.complete()

    def test_early_events_are_bound_after_exact_owned_responses(self):
        value = probe.Observation(); value.event(event("exitedReviewMode")); value.event(event())
        value.bind_thread(thread_result(), "gpt-6-astra", Path("/owned/work"))
        value.bind_turn({"turn": {"id": TURN}, "reviewThreadId": THREAD}); finish(value)
        self.assertTrue(value.complete()["nativeReviewCompleted"])
        for key in ["threadId", "turnId"]:
            row = event(); row["params"][key] = OTHER
            with self.subTest(key=key), self.assertRaises(probe.ProbeFailure): observed().event(row)

    def test_detached_or_forked_review_cannot_change_authority(self):
        value = probe.Observation(); value.bind_thread(thread_result(), "gpt-6-astra", Path("/owned/work"))
        with self.assertRaises(probe.ProbeFailure): value.bind_turn({"turn": {"id": TURN}, "reviewThreadId": OTHER})
        for key, change in [("cliVersion", "0.160.1"), ("parentThreadId", OTHER), ("forkedFromId", OTHER),
                            ("ephemeral", True), ("cwd", "/personal")]:
            row = thread_result(); row["thread"][key] = change
            with self.subTest(key=key), self.assertRaises(probe.ProbeFailure):
                probe.Observation().bind_thread(row, "gpt-6-astra", Path("/owned/work"))

    def test_forwarded_turn_start_does_not_admit_other_turn_content_or_completion(self):
        value = observed()
        start = {"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": OTHER}}}
        value.event(start)
        self.assertEqual(value.turn, TURN)
        self.assertFalse(value.done)
        self.assertEqual(value.unbound_turn_starts, 1)
        foreign = event(); foreign["params"]["turnId"] = OTHER
        with self.assertRaises(probe.ProbeFailure): value.event(foreign)
        with self.assertRaises(probe.ProbeFailure): value.event({"method": "turn/completed", "params": {
            "threadId": THREAD, "turn": {"id": OTHER, "status": "completed", "error": None}}})
        for _ in range(3): value.event(start)
        with self.assertRaises(probe.ProbeFailure): value.event(start)
        start["params"]["threadId"] = OTHER
        with self.assertRaises(probe.ProbeFailure): observed().event(start)

    def test_ignored_start_does_not_replace_exact_original_review(self):
        value = observed()
        value.event({"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": OTHER}}})
        value.event(event("exitedReviewMode")); value.event(event()); finish(value)
        result = value.complete()
        self.assertEqual(result["unboundTurnStartsIgnored"], 1)
        self.assertFalse(result["unboundTurnSourceAdmission"])
        self.assertTrue(result["nativeReviewCompleted"])

    def test_unexpected_tools_requests_and_failed_turns_fail(self):
        for kind in ["commandExecution", "webSearch", "mcpToolCall", "collabAgentToolCall", "functionCallOutput"]:
            with self.subTest(kind=kind), self.assertRaises(probe.ProbeFailure): observed().event(event(kind))
        with self.assertRaises(probe.ProbeFailure): observed().event({"id": 1, "method": "tool/call", "params": {}})
        with self.assertRaises(probe.ProbeFailure): observed().event({"method": "turn/completed", "params": {
            "threadId": THREAD, "turn": {"id": TURN, "status": "failed", "error": None}}})

    def test_passive_gate_requires_time_two_reads_and_original_bytes(self):
        message = probe.text_evidence(TEXT); report = passive()
        self.assertTrue(probe.passive_gate(report, message, probe.text_evidence(probe.INSTRUCTIONS)))
        changes = {key: False for key in probe.PASSIVE_CHECKS}
        changes.update({key: False for key in probe.INPUT_CHECKS})
        changes.update({key: True for key in probe.PASSIVE_LIMITS})
        changes.update(reviewSourceCount=0, reviewItemCount=True, turnReadCalls=1, itemReadCalls=True,
            threadListCalls=False, reviewTextBytes=True, reviewTextSHA256="0" * 64,
            parserContract="codex-content-contract-v10", producerVersion="0.160.1", gapReasons=["unsupportedFormat"],
            gapDiagnostics=["requiredSourceOmitted"], presentationSourceCount=1, forkCalls=1,
            timeEvidence="observation-time", selectionBasis="live-item-id", liveItemIDEqualsPersistedItemID=1,
            inputTextSHA256="0" * 64, inputTextBytes=1, inputItemCount=True, inputSourceCount=0,
            totalOriginalSourceCount=1, inputGapReasons=["malformedSource"], inputGapDiagnostics=["invalidFieldType"],
            inputTimeEvidence="observation-time")
        for key, value in changes.items():
            bad = dict(report); bad[key] = value
            with self.subTest(key=key): self.assertFalse(probe.passive_gate(bad, message, probe.text_evidence(probe.INSTRUCTIONS)))

    def test_persisted_identity_need_not_equal_live_identity(self):
        report = passive(); report["liveItemIDEqualsPersistedItemID"] = False
        self.assertTrue(probe.passive_gate(report, probe.text_evidence(TEXT), probe.text_evidence(probe.INSTRUCTIONS)))
        report["nativeItemIdentityStable"] = False
        self.assertFalse(probe.passive_gate(report, probe.text_evidence(TEXT), probe.text_evidence(probe.INSTRUCTIONS)))

    def test_root_relationship_preserves_factual_input_turn_difference(self):
        report = passive()
        report.update(inputTurnRelation="native-review-root", inputTurnMatchesReviewTurn=False,
                      inputTimeEvidence="item-started")
        self.assertTrue(probe.passive_gate(report, probe.text_evidence(TEXT), probe.text_evidence(probe.INSTRUCTIONS)))
        for relation, same in [("native-review-root", True), ("same-review-turn", False),
                               ("text-matches", False), (None, False), ("native-review-root", 0),
                               ("same-review-turn", 1)]:
            bad = dict(report, inputTurnRelation=relation, inputTurnMatchesReviewTurn=same)
            with self.subTest(relation=relation, same=same):
                self.assertFalse(probe.passive_gate(bad, probe.text_evidence(TEXT), probe.text_evidence(probe.INSTRUCTIONS)))
        for key in ["inputTurnRelationshipVerified", "inputTurnRelationshipStable"]:
            for value in [False, None, 1, "true"]:
                bad = dict(report); bad[key] = value
                with self.subTest(key=key, value=value):
                    self.assertFalse(probe.passive_gate(bad, probe.text_evidence(TEXT), probe.text_evidence(probe.INSTRUCTIONS)))

    def test_root_diagnostics_export_only_closed_booleans_and_counts(self):
        diagnostic = {"inputTurnRelationshipVerified": True, "inputRootMatchesReview": True,
                      "reviewRootMatchesReview": True, "inputRootValid": True,
                      "turnRecordIDsValidAndUnique": True, "inputTurnRecordCount": 1,
                      "reviewTurnRecordCount": 1}
        self.assertEqual(probe.public_passive({"inputDiagnostic": dict(diagnostic, rootTurnId=TURN,
                         inputTurnId=OTHER, rawText=TEXT)}), {"inputDiagnostic": diagnostic})
        self.assertEqual(probe.public_passive({"inputDiagnostic": {"inputRootValid": "true",
                         "inputTurnRecordCount": True, "reviewTurnRecordCount": -1}}), {"inputDiagnostic": {}})
        self.assertEqual(probe.public_passive({"inputTurnRelation": TURN, "inputTurnMatchesReviewTurn": OTHER}), {})
        self.assertEqual(probe.public_passive({"inputTurnRelation": "native-review-root",
                         "inputTurnMatchesReviewTurn": False}), {"inputTurnRelation": "native-review-root",
                         "inputTurnMatchesReviewTurn": False})

    def test_original_input_requires_actual_message_and_entered_review_bytes(self):
        value = observed(); value.event(event("exitedReviewMode")); value.event(event())
        finish(value, with_input=False)
        with self.assertRaises(probe.ProbeFailure): value.complete()
        for kind, changes in [("enteredReviewMode", {"review": "hint only"}),
                              ("userMessage", {"content": []}),
                              ("userMessage", {"content": [{"type": "text", "text": TEXT}]}),
                              ("userMessage", {"content": [{"type": "image", "text": probe.INSTRUCTIONS}]}),
                              ("userMessage", {"content": [{"type": "text", "text": probe.INSTRUCTIONS}] * 2})]:
            with self.subTest(kind=kind, changes=changes), self.assertRaises(probe.ProbeFailure):
                observed().event(event(kind, **changes))

    def test_duplicate_or_foreign_turn_input_cannot_substitute_original(self):
        value = observed(); value.event(event("userMessage"))
        with self.assertRaises(probe.ProbeFailure): value.event(event("userMessage", id="second-input"))
        foreign = event("userMessage"); foreign["params"]["turnId"] = OTHER
        with self.assertRaises(probe.ProbeFailure): observed().event(foreign)

    def test_producer_spawn_failure_and_cleanup_denial(self):
        lifetime = {"producerStopped": True, "providerLaunchCount": 0}
        selector = MagicMock()
        with patch.object(probe.selectors, "DefaultSelector", return_value=selector), \
             patch.object(probe.subprocess, "Popen", side_effect=OSError):
            with self.assertRaises(OSError): probe.produce(Path("/fake"), "model", Path("/owned"),
                Path("/owned/home"), Path("/owned/work"), lifetime, Path("/control"))
        self.assertTrue(lifetime["producerStopped"]); selector.close.assert_called_once()
        child = MagicMock(); child.poll.return_value = 1
        with patch.object(probe.subprocess, "Popen", return_value=child), \
             patch.object(probe, "write_json", side_effect=OSError), \
             patch.object(probe.processes, "stop_group", return_value={"term_permission_denied": False,
                 "kill_permission_denied": True}):
            with self.assertRaises(OSError): probe.produce(Path("/fake"), "model", Path("/owned"),
                Path("/owned/home"), Path("/owned/work"), lifetime, Path("/control"))
        self.assertFalse(lifetime["producerStopped"])

    def exercise_run(self, mode):
        with tempfile.TemporaryDirectory() as parent:
            base = Path(parent); executable = base / "codex"; probe.exclusive(executable, b"fake-executable")
            auth = base / "auth.json"; probe.exclusive(auth, b"fake-authentication")
            root = base / "spillcheck-native-review-owned"; root.mkdir(mode=0o700)
            args = SimpleNamespace(model="gpt-6-astra", report=base / "report.json", private_control=base / "control",
                executable=executable, auth_file=auth, scratch_path=base / "scratch")
            def version(*args, **kwargs):
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                if mode == "version": raise probe.ProbeFailure("version-failed")
                return probe.VERSION
            def produce(executable, model, owned, home, work, lifetime, control):
                self.assertEqual((home / "auth.json").read_bytes(), b"fake-authentication")
                self.assertIn("shell_tool = false", (home / "config.toml").read_text())
                lifetime.update(providerLaunchCount=1, producerStopped=mode != "uncertain")
                raise probe.ProbeFailure("producer-failed")
            with patch.object(probe.tempfile, "mkdtemp", return_value=str(root)), \
                 patch.object(probe, "input_hashes", return_value={"fixed": "digest"}), \
                 patch.object(probe.live, "observe_version", side_effect=version), \
                 patch.object(probe, "produce", side_effect=produce) as producer, \
                 patch.object(probe.live, "bounded") as reader, patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(probe.run(args), 1)
                reader.assert_not_called()
                if mode == "version": producer.assert_not_called()
            report = json.loads(args.report.read_text())
            self.assertFalse(report["passed"])
            self.assertEqual(auth.read_bytes(), b"fake-authentication")
            if mode == "uncertain":
                self.assertTrue(report["privateCleanupPending"])
                self.assertEqual((root / "home/auth.json").read_bytes(), b"fake-authentication")
                self.assertTrue((args.private_control / "cleanup-handoff.json").exists())
            else:
                self.assertFalse(root.exists())
                self.assertTrue(report["authRemoved"])

    def test_run_version_failure_never_starts_provider(self): self.exercise_run("version")
    def test_run_producer_failure_still_removes_owned_auth(self): self.exercise_run("producer")
    def test_run_uncertain_producer_retains_exact_cleanup_handoff(self): self.exercise_run("uncertain")


if __name__ == "__main__":
    unittest.main()
