import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

SPEC = importlib.util.spec_from_file_location("codex_mcp_probe", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
THREAD = "00000000-0000-4000-8000-000000000001"
TURN = "00000000-0000-4000-8000-000000000002"
OTHER = "00000000-0000-4000-8000-000000000003"


def thread_result():
    return {"model": "gpt-6-astra", "cwd": "/owned/work", "thread": {"id": THREAD,
        "cwd": "/owned/work", "cliVersion": probe.VERSION, "parentThreadId": None,
        "forkedFromId": None, "ephemeral": False}}


def item_event(kind="mcpToolCall", **changes):
    item = {"type": kind, "id": "mcp-tool-native-42", "server": probe.fixture.SERVER,
            "tool": probe.fixture.TOOL, "status": "completed", "arguments": {}, "error": None,
            "result": {"content": probe.fixture.RESULT["content"],
                       "structuredContent": probe.fixture.RESULT["structuredContent"], "_meta": None}}
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


class MCPBoundaryTests(unittest.TestCase):
    def test_strict_json_and_canonical_identity(self):
        for raw in (b'{"id":1,"id":2}', b'{"result":{"a":1,"a":2}}', b'{"x":NaN}', b'[]'):
            with self.subTest(raw=raw), self.assertRaises(probe.ProbeFailure): probe.decode(raw)
        self.assertTrue(probe.native_id(THREAD))
        for value in (None, 1, "../x", "", "AAAAAAAA-0000-4000-8000-000000000001"):
            self.assertFalse(probe.native_id(value))

    def test_fixture_returns_distinct_protocol_and_business_fields(self):
        result = probe.fixture.reply({"method": "tools/call", "params": {
            "name": probe.fixture.TOOL, "arguments": {}}})
        self.assertIs(result["isError"], False)
        self.assertIs(result["structuredContent"]["isError"], True)
        self.assertEqual(result["structuredContent"]["type"], "image")
        self.assertEqual(result["structuredContent"]["content"][0]["type"], "encrypted_content")
        self.assertNotIn(result["structuredContent"]["caption"], result["content"][0]["text"])
        def strings(value, pointer):
            if isinstance(value, str): return {pointer: value}
            result = {}
            values = value.items() if isinstance(value, dict) else enumerate(value) if isinstance(value, list) else []
            for key, child in values:
                result.update(strings(child, pointer + "/" + str(key).replace("~", "~0").replace("/", "~1")))
            return result
        expected = strings(result["structuredContent"], "/result/structuredContent")
        expected["/result/content/0/text"] = result["content"][0]["text"]
        self.assertEqual(sorted(expected), probe.EXPECTED_POINTERS)

    def test_server_refuses_other_tools_arguments_and_methods(self):
        for request in ({"method": "tools/call", "params": {"name": "other", "arguments": {}}},
                        {"method": "tools/call", "params": {"name": probe.fixture.TOOL, "arguments": {"x": 1}}},
                        {"method": "resources/read"}):
            with self.assertRaises(ValueError): probe.fixture.reply(request)

    def test_normal_native_mcp_has_exact_owned_identity_and_no_public_ids(self):
        value = observed(); value.event(item_event()); finished(value)
        report = value.complete()
        self.assertTrue(report["nativeMCPCompleted"])
        self.assertEqual(report["completedMCPCount"], 1)
        for forbidden in (THREAD, TURN, "mcp-tool-native-42", "BUSINESS_IMAGE"):
            self.assertNotIn(forbidden, json.dumps(report))

    def test_wrong_identity_tool_duplicate_and_missing_result_fail(self):
        for field in ("threadId", "turnId"):
            event = item_event(); event["params"][field] = OTHER
            with self.assertRaises(probe.ProbeFailure): observed().event(event)
        for change in ({"tool": "other"}, {"server": "other"}, {"status": "failed"},
                       {"arguments": {"secret": "not authorized"}}, {"result": None},
                       {"result": {"content": probe.fixture.RESULT["content"], "structuredContent": None}}):
            with self.subTest(change=change), self.assertRaises(probe.ProbeFailure): observed().event(item_event(**change))
        value = observed(); value.event(item_event())
        with self.assertRaises(probe.ProbeFailure): value.event(item_event())
        value = observed(); finished(value)
        with self.assertRaises(probe.ProbeFailure): value.complete()

    def test_unexpected_tools_and_server_approval_requests_fail(self):
        for kind in ("commandExecution", "webSearch", "dynamicToolCall", "collabAgentToolCall", "plan", "unknown"):
            with self.assertRaises(probe.ProbeFailure): observed().event(item_event(kind))
        with self.assertRaises(probe.ProbeFailure):
            observed().event({"id": 3, "method": "item/tool/requestUserInput", "params": {}})

    def test_text_echo_or_provider_fallback_cannot_satisfy_structured_result(self):
        for changed in (None, {"content": [{"type": "text", "text": json.dumps(probe.fixture.RESULT)}]},
                        {"content": probe.fixture.RESULT["content"] * 2,
                         "structuredContent": probe.fixture.RESULT["structuredContent"]}):
            self.assertFalse(probe.expected_result(changed))
        value = observed(); value.event(item_event("agentMessage")); finished(value)
        with self.assertRaises(probe.ProbeFailure): value.complete()

    def test_optional_transport_metadata_preserves_exact_business_contract(self):
        request = {"method": "tools/call", "params": {"name": probe.fixture.TOOL, "arguments": {},
                   "_meta": {"openai/readOnly": True, "traceparent": "synthetic-trace"}}}
        self.assertEqual(probe.fixture.reply(request), probe.fixture.RESULT)
        for change in ({"_meta": "not-object"}, {"arguments": {"new": 1}}, {"unexpected": True}):
            bad = copy.deepcopy(request); bad["params"].update(change)
            with self.assertRaises(ValueError): probe.fixture.reply(bad)

    def test_fixture_records_closed_request_shape_without_metadata_values(self):
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": probe.fixture.TOOL, "arguments": {}, "_meta": {"private-field": "NEVER_EXPORT_42"}}}
        with tempfile.TemporaryDirectory() as directory:
            stream = MagicMock(); stream.buffer = io.BytesIO(json.dumps(request).encode() + b"\n")
            with patch.object(probe.fixture.sys, "argv", ["fixture.py", directory]), \
                 patch.object(probe.fixture.sys, "stdin", stream), patch.object(probe.fixture.sys, "stdout", io.StringIO()):
                self.assertEqual(probe.fixture.main(), 0)
            report = probe.fixture_diagnostic(Path(directory))
            self.assertEqual(report["methodCounts"], {"tools/call": 1})
            self.assertTrue(report["callShape"]["metaPresent"] and report["callShape"]["metaObject"])
            self.assertEqual(report["calls"], 1)
            self.assertNotIn("NEVER_EXPORT", json.dumps(report)); self.assertNotIn("private-field", json.dumps(report))

    def test_native_failure_diagnostic_never_exports_error_or_unknown_values(self):
        item = item_event()["params"]["item"]
        item.update(status="UNKNOWN_PRIVATE", error={"message": "NEVER_EXPORT_42"}, result=None)
        report = probe.native_result_diagnostic(item)
        self.assertEqual(report["status"], "other")
        self.assertTrue(report["errorPresent"]); self.assertFalse(report["resultObject"])
        self.assertNotIn("NEVER_EXPORT", json.dumps(report)); self.assertNotIn("UNKNOWN_PRIVATE", json.dumps(report))
        value = observed()
        with self.assertRaises(probe.ProbeFailure): value.event(item_event(error={"message": "NEVER_EXPORT_42"}))
        self.assertTrue(value.mcp_diagnostic["errorPresent"])

    def test_configuration_contains_only_owned_fixed_server(self):
        raw = probe.fixture_configuration("gpt-6-astra", Path("/owned/fake fixture.py"), Path("/owned/control"))
        self.assertIn(b'web_search = "disabled"', raw)
        self.assertEqual(raw.count(b'[mcp_servers.'), 1)
        self.assertIn(json.dumps(["/owned/fake fixture.py", "/owned/control"]).encode(), raw)
        self.assertNotIn(b"auth", raw)


    def test_server_stop_requires_bound_pid_and_absence(self):
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp)
            lifetime = {"producerStopped": True, "providerLaunchCount": 0}
            self.assertTrue(probe.confirm_mcp_stopped(control, lifetime))
            lifetime["providerLaunchCount"] = 1
            self.assertFalse(probe.confirm_mcp_stopped(control, lifetime))
            probe.write_json(control / "producer-process.json", {"pid": 123, "root": "/owned"})
            probe.write_json(control / "mcp-process.json", {"pid": 124, "parentPID": 123, "processGroup": 124})
            with patch.object(probe.os, "kill", side_effect=ProcessLookupError), \
                 patch.object(probe.os, "killpg", side_effect=ProcessLookupError):
                self.assertTrue(probe.confirm_mcp_stopped(control, lifetime))
            with patch.object(probe.os, "kill", return_value=None), patch.object(probe.os, "killpg", return_value=None):
                self.assertFalse(probe.confirm_mcp_stopped(control, lifetime, wait_seconds=0))
            with patch.object(probe.os, "kill", side_effect=PermissionError):
                with self.assertRaises(PermissionError): probe.confirm_mcp_stopped(control, lifetime)

    def test_independent_server_group_must_be_absent_even_after_leader_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp)
            probe.write_json(control / "producer-process.json", {"pid": 123, "root": "/owned"})
            probe.write_json(control / "mcp-process.json", {"pid": 124, "parentPID": 123, "processGroup": 124})
            lifetime = {"producerStopped": True, "providerLaunchCount": 1}
            with patch.object(probe.os, "kill", side_effect=ProcessLookupError), patch.object(probe.os, "killpg", return_value=None):
                self.assertFalse(probe.confirm_mcp_stopped(control, lifetime, wait_seconds=0))
            with patch.object(probe.os, "kill", side_effect=ProcessLookupError), patch.object(probe.os, "killpg", side_effect=PermissionError):
                with self.assertRaises(PermissionError): probe.confirm_mcp_stopped(control, lifetime)
            with patch.object(probe.os, "kill", side_effect=[None, ProcessLookupError]) as pid, \
                 patch.object(probe.os, "killpg", side_effect=[None, ProcessLookupError]) as group, \
                 patch.object(probe.time, "sleep") as pause:
                self.assertTrue(probe.confirm_mcp_stopped(control, lifetime))
                self.assertEqual(pid.call_count, 2); self.assertEqual(group.call_count, 2)
                pause.assert_called_once_with(.05)
                self.assertTrue(all(call.args[1] == 0 for call in pid.call_args_list + group.call_args_list))

    def test_same_call_receipt_required_and_other_process_group_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp)
            probe.write_json(control / "producer-process.json", {"pid": 123, "root": "/owned"})
            probe.write_json(control / "mcp-process.json", {"pid": 124, "parentPID": 123, "processGroup": 124})
            lifetime = {"producerStopped": True, "providerLaunchCount": 1}
            with patch.object(probe.os, "kill", side_effect=ProcessLookupError), \
                 patch.object(probe.os, "killpg", side_effect=ProcessLookupError):
                with self.assertRaises(FileNotFoundError): probe.confirm_mcp_stopped(control, lifetime, True)
                probe.write_json(control / "mcp-invocation.json", {"schemaVersion": 1, "calls": 1,
                    "server": probe.fixture.SERVER, "tool": probe.fixture.TOOL, "argumentsEmpty": True,
                    "result": probe.fixture.RESULT})
                self.assertTrue(probe.confirm_mcp_stopped(control, lifetime, True))
            (control / "mcp-process.json").unlink()
            probe.write_json(control / "mcp-process.json", {"pid": 124, "parentPID": 123, "processGroup": 777})
            with self.assertRaises(probe.ProbeFailure): probe.confirm_mcp_stopped(control, lifetime)

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
                    "versionProcessStopped": True, "mcpServerStopped": True}, original_path=original, original_hash=probe.digest(b"original"),
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
                "versionProcessStopped": True, "mcpServerStopped": True}, original_path=Path(parent) / "missing", original_hash=None,
                root=root, home=home, root_identity=(ri.st_dev, ri.st_ino), home_identity=(hi.st_dev, hi.st_ino))
            self.assertFalse(report["authRemoved"] or report["ownedRootRemoved"])
            self.assertEqual((home / "auth.json").read_bytes(), b"fake")


if __name__ == "__main__":
    unittest.main()
