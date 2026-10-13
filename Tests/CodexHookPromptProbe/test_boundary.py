import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

SPEC = importlib.util.spec_from_file_location("hook_prompt_probe", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
THREAD = "00000000-0000-4000-8000-000000000001"
TURN = "00000000-0000-4000-8000-000000000002"


def callback():
    return {"hook_event_name": "Stop", "session_id": THREAD, "turn_id": TURN,
            "cwd": "/owned/work", "stop_hook_active": False,
            "last_assistant_message": probe.fixture.BEFORE}


class HookPromptBoundaryTests(unittest.TestCase):
    def test_reason_is_absent_human_prompts(self):
        prompts = probe.prompts(Path("/owned/work/fixture.py"))
        self.assertNotIn(probe.fixture.REASON, "\n".join(prompts))
        self.assertNotIn(probe.fixture.REASON_MARKER, "\n".join(prompts))
        self.assertIn("identity", prompts[0])
        self.assertNotIn("\r", probe.fixture.REASON)
        self.assertIn("é🙂\n", probe.fixture.REASON)

    def test_owned_callback_shape_is_strict(self):
        self.assertTrue(probe.fixture.valid_callback(callback(), THREAD, Path("/owned/work")))
        for key, value in (("session_id", TURN), ("cwd", "/other/work"),
                           ("hook_event_name", "SubagentStop"), ("stop_hook_active", 0),
                           ("turn_id", ""), ("agent_id", "child")):
            row = callback(); row[key] = value
            self.assertFalse(probe.fixture.valid_callback(row, THREAD, Path("/owned/work")))

    def test_stop_decision_is_one_shot_and_active_continuation_never_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(probe.fixture.decision(callback(), root, armed=False), ("unarmed", {}))
            self.assertEqual(probe.fixture.decision(callback(), root, armed=True),
                ("blocked", {"decision": "block", "reason": probe.fixture.REASON}))
            self.assertEqual(probe.fixture.decision(callback(), root, armed=True), ("already-blocked", {}))
            row = callback(); row["stop_hook_active"] = True
            row["last_assistant_message"] = probe.fixture.AFTER
            self.assertEqual(probe.fixture.decision(row, root, armed=True), ("continued", {}))

    def test_wrong_assistant_final_does_not_consume_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); row = callback(); row["last_assistant_message"] = "other"
            self.assertEqual(probe.fixture.decision(row, root, armed=True), ("unexpected-final", {}))
            self.assertFalse((root / "blocked-once").exists())

    def test_one_hook_review_needs_current_ui_and_exact_count(self):
        labels = probe.labels(b"1 hook is new or changed. 1. Review hooks 2. Trust all and continue 3. Continue without trusting")
        self.assertTrue(labels["oneHook"] and labels["reviewMenu"])
        self.assertFalse(probe.labels(b"8 hooks are new or changed.")["oneHook"])
        self.assertEqual(probe.review_action(labels, []), "review")
        self.assertIsNone(probe.review_action(labels, ["review"]))
        self.assertEqual(probe.review_action(probe.labels(b"t trust all Enter review Esc close"), ["review"]), "trust")
        self.assertIsNone(probe.review_action(probe.labels(b"Enter details Esc close"), ["review"]))

    def test_folder_trust_is_observed_once_and_never_conflicts(self):
        labels = probe.labels(b"Trust this folder?")
        self.assertEqual(probe.review_action(labels, []), "folder")
        self.assertIsNone(probe.review_action(labels, ["folder"]))
        labels["reviewMenu"] = True
        self.assertIsNone(probe.review_action(labels, []))

    def test_observed_review_key_waits_past_pinned_input_quarantine(self):
        scheduler = probe.ReviewScheduler()
        state = probe.labels(b"1 hook is new or changed. 1. Review hooks 2. Trust all and continue 3. Continue without trusting")
        self.assertIsNone(scheduler.ready(state, [], 10))
        self.assertIsNone(scheduler.ready(state, [], 11))
        self.assertEqual(scheduler.ready(state, [], 11.2), "review")
        self.assertIsNone(scheduler.ready(state, ["review"], 11.3))

    def test_missing_or_changed_ui_restarts_stability_window(self):
        scheduler = probe.ReviewScheduler()
        state = probe.labels(b"t trust all Enter review Esc close")
        self.assertIsNone(scheduler.ready(state, ["review"], 1))
        self.assertIsNone(scheduler.ready(probe.labels(b""), ["review"], 1.9))
        self.assertIsNone(scheduler.ready(state, ["review"], 2))
        self.assertIsNone(scheduler.ready(state, ["review"], 3))
        self.assertEqual(scheduler.ready(state, ["review"], 3.2), "trust")
        self.assertIsNone(scheduler.ready(state, ["review", "trust"], 4.5))

    def test_review_stage_deadlines_are_bounded_and_distinct(self):
        self.assertEqual(probe.review_stage([]), ("startup-hook-menu", 40))
        self.assertEqual(probe.review_stage(["review"]), ("hook-browser-review", 20))
        self.assertEqual(probe.review_stage(["review", "trust"]), ("hook-trust-acknowledgement", 20))

    def test_progress_retains_only_closed_stage_and_ui_metadata(self):
        terminal = MagicMock(actions=["review"], current=b"PRIVATE BODY AND UUID", total=321)
        with tempfile.TemporaryDirectory() as directory:
            value = probe.progress(Path(directory), "hook-browser-review", terminal, probe.time.monotonic(), 0)
            text = (Path(directory) / "progress-00.json").read_text()
            self.assertNotIn("PRIVATE BODY", text)
            self.assertEqual(value["terminalBytesObserved"], 321)
            self.assertEqual(value["stage"], "hook-browser-review")

    def test_callback_processes_allow_distinct_groups_but_require_absence(self):
        rows = [{"pid": 1234, "pgid": 1234, "parentPID": 999, "outcome": "continued"}]
        with patch.object(probe.os, "kill", side_effect=ProcessLookupError), \
             patch.object(probe.os, "killpg", side_effect=ProcessLookupError):
            self.assertTrue(probe.callbacks_stopped(rows, timeout=0))
        for failure in (None, PermissionError):
            with patch.object(probe.os, "kill", side_effect=failure), \
                 patch.object(probe.os, "killpg", side_effect=ProcessLookupError):
                self.assertFalse(probe.callbacks_stopped(rows, timeout=0))

    def test_shared_group_is_allowed_only_when_that_group_is_gone(self):
        row = [{"pid": 1234, "pgid": 999, "parentPID": 999}]
        with patch.object(probe.os, "kill", side_effect=ProcessLookupError), \
             patch.object(probe.os, "killpg", return_value=None):
            self.assertFalse(probe.callbacks_stopped(row, timeout=0))

    def test_callback_gate_requires_bound_identity_and_both_actual_stops(self):
        rows = [{"pid": 1234 + i, "pgid": 888, "parentPID": 999,
                 "sessionID": THREAD, "turnID": TURN, "cwd": "/owned/work", "valid": True,
                 "outcome": outcome, "stopHookActive": outcome == "continued"}
                for i, outcome in enumerate(("identity-complete", "blocked", "continued"))]
        self.assertTrue(probe.callback_gate(rows, THREAD, Path("/owned/work")))
        for changes in ([rows[0], rows[1]], rows + [copy.deepcopy(rows[1])],
                        [dict(rows[0], sessionID=TURN), *rows[1:]],
                        [*rows[:2], dict(rows[2], stopHookActive=False)]):
            self.assertFalse(probe.callback_gate(changes, THREAD, Path("/owned/work")))

    def test_strict_private_identity_rejects_foreign_home_or_source(self):
        row = {"threadID": THREAD, "cwd": "/owned/work", "home": "/owned/home",
               "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID", "sourceEnumerationPerformed": False}
        self.assertTrue(probe.identity_gate(row, Path("/owned")))
        for key, value in (("home", "/personal"), ("threadID", "bad"),
                           ("sourceEnumerationPerformed", True), ("nativeIdentitySource", "guessed")):
            bad = dict(row); bad[key] = value
            self.assertFalse(probe.identity_gate(bad, Path("/owned")))

    def test_passive_scope_requires_two_reads_native_kind_and_exact_bytes(self):
        good = {**{key: True for key in probe.PASSIVE_CHECKS}, "status": "native-hook-prompt-read-and-replayed",
                "parserContract": probe.PARSER, "readerVersion": probe.VERSION, "producerVersion": probe.VERSION,
                "threadReadCalls": 2, "itemReadCalls": 2, "turnReadCalls": 2, "threadListCalls": 0, "resumeCalls": 0,
                "hookPromptItemCount": 1, "hookPromptSourceCount": 1, "segmentCount": 1,
                "segmentPointers": ["/fragments/0/text"], "textBytes": len(probe.fixture.REASON.encode()),
                "textSHA256": probe.common.digest(probe.fixture.REASON.encode()), "gapReasons": [], "gapDiagnostics": [],
                "nativeTurnEqualsStopCallbackTurn": False}
        self.assertTrue(probe.passive_gate(good))
        for key, value in (("nativeHookPromptVerified", False), ("itemReadCalls", 1),
                           ("textSHA256", "a" * 64), ("segmentPointers", ["/text"]),
                           ("reasonAbsentHumanInput", False)):
            bad = dict(good); bad[key] = value
            self.assertFalse(probe.passive_gate(bad))

    def test_public_passive_drops_unrecognized_private_content(self):
        self.assertEqual(probe.public_passive({"nativeThreadID": THREAD, "raw": "not public", "readerVersion": "0.162.1"}),
                         {"readerVersion": "0.162.1"})

    def test_final_callback_recheck_overrides_stale_success_after_reader_failure(self):
        lifetime = {"producerStopped": True, "readerStopped": True, "callbacksStopped": True}
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "callback_rows", return_value=[{"pid": 222, "pgid": 333}]) as rows, \
             patch.object(probe, "callbacks_stopped", return_value=False):
            report = {}; root = Path(directory)
            probe.refresh_callback_cleanup(root, lifetime, report, root)
            self.assertFalse(lifetime["callbacksStopped"])
            rows.assert_called_once_with(root, completed=False)
            self.assertEqual(report["callbacks"]["outcomeCounts"]["incomplete"], 1)

    def test_terminal_teardown_stops_group_before_closing_pty_even_when_close_fails(self):
        terminal = probe.Terminal.__new__(probe.Terminal)
        terminal.process = MagicMock(); terminal.process.poll.return_value = 0
        terminal.master = 123; terminal.lifetime = {"producerStopped": False}; order = []
        def stop(_):
            order.append("stop")
            return {"term_permission_denied": False, "kill_permission_denied": False}
        def close(_):
            order.append("close"); raise OSError("fake")
        with patch.object(probe.common.processes, "stop_group", side_effect=stop), \
             patch.object(probe.os, "close", side_effect=close):
            with self.assertRaises(OSError): terminal.stop()
        self.assertEqual(order, ["stop", "close"])
        self.assertTrue(terminal.lifetime["producerStopped"])

    def test_terminal_has_overall_deadline(self):
        terminal = probe.Terminal.__new__(probe.Terminal); terminal.deadline = 0
        with self.assertRaisesRegex(probe.ProbeFailure, "producer-timeout"): terminal.pump()

    def test_callback_ancestry_is_bounded_and_stops_at_owned_parent(self):
        self.assertEqual(probe.fixture.ancestors(999, 999), [999])
        with patch.object(probe.fixture.subprocess, "run", return_value=MagicMock(stdout=b"888\n")) as command:
            self.assertEqual(probe.fixture.ancestors(999, 888), [999, 888])
            command.assert_called_once()
        with patch.object(probe.fixture.subprocess, "run", return_value=MagicMock(stdout=b"999\n")):
            with self.assertRaises(ValueError): probe.fixture.ancestors(999, 888)

    def test_callback_diagnostics_keep_shapes_not_private_values(self):
        row = callback(); shape = probe.fixture.callback_shape(row, THREAD, Path("/owned/work"))
        summary = probe.callback_summary([{**row, "shape": shape, "valid": True, "outcome": "blocked"}])
        self.assertEqual(summary["validCount"], 1)
        self.assertEqual(summary["shapeTrueCounts"]["turnBounded"], 1)
        self.assertNotIn(THREAD, json.dumps(summary)); self.assertNotIn("/owned", json.dumps(summary))

    def test_owned_ancestry_cannot_be_guessed_from_callback_session(self):
        rows = [{"sessionID": THREAD, "turnID": TURN, "cwd": "/owned/work", "valid": True,
                 "outcome": outcome, "stopHookActive": outcome == "continued", "parentPID": 999,
                 "ancestorPIDs": [999, 777], "producerPID": 777}
                for outcome in ("identity-complete", "blocked", "continued")]
        self.assertTrue(probe.callback_gate(rows, THREAD, Path("/owned/work"), 777))
        self.assertFalse(probe.callback_gate(rows, THREAD, Path("/owned/work"), 778))
        rows[1]["ancestorPIDs"] = [1, 777]
        self.assertFalse(probe.callback_gate(rows, THREAD, Path("/owned/work"), 777))

    def test_cleanup_attempts_owned_copy_even_when_original_auth_disappears(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"; root.mkdir(); home = root / "home"; home.mkdir()
            (home / "auth.json").write_bytes(b"fake")
            ri = root.stat(); hi = home.stat(); report = {}
            lifetime = {key: True for key in ("producerStopped", "readerStopped", "versionProcessStopped", "callbacksStopped")}
            probe.cleanup(report, lifetime, Path(directory) / "missing", "old", root, home,
                          (ri.st_dev, ri.st_ino), (hi.st_dev, hi.st_ino))
            self.assertFalse(report["originalAuthUnchanged"])
            self.assertTrue(report["authRemoved"] and report["ownedRootRemoved"])

    def test_unconfirmed_callback_retains_owned_auth_and_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); home = root / "home"; home.mkdir(); (home / "auth.json").write_bytes(b"fake")
            ri = root.stat(); hi = home.stat(); report = {}
            lifetime = {"producerStopped": True, "readerStopped": True,
                        "versionProcessStopped": True, "callbacksStopped": False}
            probe.cleanup(report, lifetime, root / "missing", "old", root, home,
                          (ri.st_dev, ri.st_ino), (hi.st_dev, hi.st_ino))
            self.assertTrue((home / "auth.json").exists())
            self.assertFalse(report.get("ownedRootRemoved", False))


if __name__ == "__main__":
    unittest.main()
