import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("codex_plan_probe", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
THREAD = "00000000-0000-4000-8000-000000000001"
TURN = "00000000-0000-4000-8000-000000000002"
OTHER = "00000000-0000-4000-8000-000000000003"


def thread_result():
    return {"model": "gpt-6-astra", "cwd": "/owned/work", "thread": {"id": THREAD,
        "cwd": "/owned/work", "cliVersion": probe.VERSION, "parentThreadId": None,
        "forkedFromId": None, "ephemeral": False}}


def item_event(kind="plan", **changes):
    item = {"type": kind, "id": TURN + "-plan", "text": "# Fake " + probe.MARKER}
    item.update(changes)
    return {"method": "item/completed", "params": {"threadId": THREAD, "turnId": TURN, "item": item}}


def observed():
    result = probe.Observation()
    result.bind_thread(thread_result(), "gpt-6-astra", Path("/owned/work"))
    result.bind_turn({"turn": {"id": TURN}})
    return result


def finished(result):
    result.event({"method": "turn/completed", "params": {"threadId": THREAD,
        "turn": {"id": TURN, "status": "completed", "error": None}}})


class PlanBoundaryTests(unittest.TestCase):
    def test_duplicate_keys_numbers_and_oversize_fail_closed(self):
        for value in (b'{"id":1,"id":2}', b'{"item":{"text":"a","text":"b"}}', b'{"x":NaN}',
                      b'[]', b'x' * (probe.MAXIMUM + 1)):
            with self.subTest(value=value[:50]), self.assertRaises(probe.ProbeFailure):
                probe.decode(value)

    def test_canonical_native_identity_only(self):
        self.assertTrue(probe.native_id(THREAD))
        for value in (THREAD.replace("00000000", "aaaaaaaa", 1).upper(), "../source", "", None, 1):
            self.assertFalse(probe.native_id(value))

    def test_plan_parameters_have_one_fake_text_and_builtin_mode(self):
        value = probe.turn_parameters(THREAD, "gpt-6-astra")
        self.assertEqual(value["input"], [{"type": "text", "text": probe.PROMPT, "text_elements": []}])
        self.assertEqual(value["collaborationMode"], {"mode": "plan", "settings": {
            "model": "gpt-6-astra", "reasoning_effort": None, "developer_instructions": None}})
        self.assertNotIn("fake token", probe.PROMPT)

    def test_live_plan_binds_only_owned_thread_turn_and_item(self):
        value = observed(); value.event(item_event()); finished(value)
        summary = value.complete()
        self.assertTrue(summary["nativePlanCompleted"])
        self.assertEqual(summary["completedPlanCount"], 1)
        encoded = json.dumps(summary)
        self.assertNotIn(THREAD, encoded); self.assertNotIn(TURN, encoded)
        self.assertNotIn(probe.MARKER, encoded)

    def test_early_owned_events_are_validated_after_response(self):
        value = probe.Observation()
        value.event(item_event())
        value.bind_thread(thread_result(), "gpt-6-astra", Path("/owned/work"))
        value.bind_turn({"turn": {"id": TURN}})
        finished(value)
        self.assertTrue(value.complete()["nativePlanCompleted"])

    def test_other_identity_and_missing_native_plan_fail(self):
        for field in ("threadId", "turnId"):
            value = observed(); event = item_event(); event["params"][field] = OTHER
            with self.assertRaises(probe.ProbeFailure): value.event(event)
        value = observed(); value.event(item_event("agentMessage")); finished(value)
        with self.assertRaises(probe.ProbeFailure): value.complete()

    def test_no_tool_or_server_request_is_accepted(self):
        for kind in ("commandExecution", "webSearch", "mcpToolCall", "collabAgentToolCall", "unknown"):
            with self.subTest(kind=kind), self.assertRaises(probe.ProbeFailure): observed().event(item_event(kind))
        with self.assertRaises(probe.ProbeFailure):
            observed().event({"id": 17, "method": "item/commandExecution/requestApproval", "params": {}})

    def test_duplicate_or_empty_plan_and_failed_turn_rejected(self):
        value = observed(); value.event(item_event())
        with self.assertRaises(probe.ProbeFailure): value.event(item_event())
        for text in ("", "unrelated", probe.MARKER * 2, probe.MARKER + "x" * 16385, None):
            with self.subTest(text=str(text)[:20]), self.assertRaises(probe.ProbeFailure):
                observed().event(item_event(text=text))
        with self.assertRaises(probe.ProbeFailure):
            observed().event({"method": "turn/completed", "params": {"threadId": THREAD,
                "turn": {"id": TURN, "status": "failed", "error": None}}})

    def test_fork_version_model_and_path_mismatch_rejected(self):
        for key, change in (("cliVersion", "0.160.1"), ("parentThreadId", OTHER),
                            ("forkedFromId", OTHER), ("ephemeral", True), ("cwd", "/personal")):
            result = thread_result(); result["thread"][key] = change
            with self.subTest(key=key), self.assertRaises(probe.ProbeFailure):
                probe.Observation().bind_thread(result, "gpt-6-astra", Path("/owned/work"))


    def test_private_auth_symlink_and_permissions_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "auth.json"; probe.exclusive(path, b"fake")
            self.assertEqual(probe.private_bytes(path), b"fake")
            alias = Path(root) / "alias"; alias.symlink_to(path)
            with self.assertRaises(OSError): probe.private_bytes(alias)
            path.chmod(0o644)
            with self.assertRaises(probe.ProbeFailure): probe.private_bytes(path)

    def test_auth_cleanup_rejects_replaced_home_and_dangling_auth(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root) / "home"; home.mkdir(mode=0o700)
            info = home.stat(); identity = (info.st_dev, info.st_ino)
            (home / "auth.json").symlink_to(Path(root) / "absent")
            with self.assertRaises(probe.ProbeFailure): probe.cleanup_auth(home, identity)
            (home / "auth.json").unlink()
            self.assertTrue(probe.cleanup_auth(home, identity))
            with self.assertRaises(probe.ProbeFailure): probe.cleanup_auth(home, (0, 0))

    def test_spawn_failure_closes_selector_and_leaves_no_process(self):
        selector = MagicMock(); lifetime = {"producerStopped": True, "providerLaunchCount": 0}
        with patch.object(probe.selectors, "DefaultSelector", return_value=selector), \
             patch.object(probe.subprocess, "Popen", side_effect=OSError), \
             patch.object(probe.processes, "stop_group") as stop:
            with self.assertRaises(OSError):
                probe.produce(Path("/fake"), "gpt-6-astra", Path("/owned"), Path("/owned/home"),
                    Path("/owned/work"), lifetime, Path("/control"))
        selector.close.assert_called_once(); stop.assert_not_called()
        self.assertTrue(lifetime["producerStopped"]); self.assertEqual(lifetime["providerLaunchCount"], 0)

    def test_post_spawn_failure_stops_before_stream_close(self):
        events = []
        child = MagicMock(); child.pid = 123; child.poll.return_value = 1
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close.side_effect = lambda: events.append("close")
        lifetime = {"producerStopped": True, "providerLaunchCount": 0}
        def stop(_):
            events.append("stop")
            return {"term_permission_denied": False, "kill_permission_denied": False}
        with patch.object(probe.subprocess, "Popen", return_value=child), \
             patch.object(probe, "write_json", side_effect=OSError), \
             patch.object(probe.processes, "stop_group", side_effect=stop):
            with self.assertRaises(OSError):
                probe.produce(Path("/fake"), "gpt-6-astra", Path("/owned"), Path("/owned/home"),
                    Path("/owned/work"), lifetime, Path("/control"))
        self.assertEqual(events[0], "stop"); self.assertTrue(lifetime["producerStopped"])

    def test_denied_group_cleanup_remains_unconfirmed(self):
        child = MagicMock(); child.pid = 123; child.poll.return_value = 1
        lifetime = {"producerStopped": True, "providerLaunchCount": 0}
        with patch.object(probe.subprocess, "Popen", return_value=child), \
             patch.object(probe, "write_json", side_effect=OSError), \
             patch.object(probe.processes, "stop_group", return_value={
                 "term_permission_denied": False, "kill_permission_denied": True}):
            with self.assertRaises(OSError):
                probe.produce(Path("/fake"), "gpt-6-astra", Path("/owned"), Path("/owned/home"),
                    Path("/owned/work"), lifetime, Path("/control"))
        self.assertFalse(lifetime["producerStopped"])

    def test_original_auth_changes_cannot_skip_owned_credential_cleanup(self):
        for mode in ("missing", "changed", "unchanged"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as parent:
                original = Path(parent) / "original.json"
                if mode != "missing": probe.exclusive(original, b"original" if mode == "unchanged" else b"changed")
                root = Path(parent) / "owned"; root.mkdir(mode=0o700)
                home = root / "home"; home.mkdir(mode=0o700)
                probe.exclusive(home / "auth.json", b"original")
                ri, hi = root.stat(), home.stat()
                report = {"authRemoved": False, "ownedRootRemoved": False}
                probe.finish_cleanup(report, {"producerStopped": True, "readerStopped": True,
                    "versionProcessStopped": True}, original_path=original, original_hash=probe.digest(b"original"),
                    root=root, home=home, root_identity=(ri.st_dev, ri.st_ino), home_identity=(hi.st_dev, hi.st_ino))
                self.assertEqual(report["originalAuthUnchanged"], mode == "unchanged")
                self.assertTrue(report["authRemoved"] and report["ownedRootRemoved"])

    def test_unconfirmed_process_cleanup_preserves_exact_owned_handoff(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "owned"; root.mkdir(mode=0o700)
            home = root / "home"; home.mkdir(mode=0o700)
            probe.exclusive(home / "auth.json", b"fake")
            ri, hi = root.stat(), home.stat()
            report = {"authRemoved": False, "ownedRootRemoved": False}
            probe.finish_cleanup(report, {"producerStopped": False, "readerStopped": True,
                "versionProcessStopped": True}, original_path=Path(parent) / "missing", original_hash=None,
                root=root, home=home, root_identity=(ri.st_dev, ri.st_ino), home_identity=(hi.st_dev, hi.st_ino))
            self.assertFalse(report["authRemoved"] or report["ownedRootRemoved"])
            self.assertEqual((home / "auth.json").read_bytes(), b"fake")


if __name__ == "__main__":
    unittest.main()
