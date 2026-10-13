"""T3 coordinator boundaries with only temporary fake files and mocked processes."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest
from unittest import mock
import uuid


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


R = load("t3_hook_runner_tests", "run-app-claude-t3-hooks.py")
D = load("desktop_hook_test_evidence", "test_claude_desktop_hooks_boundary.py")
G = R.gate
VERSION = D.VERSION


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.work = self.root / "workspace"
        self.work.mkdir(mode=0o700)
        (self.work / ".git").mkdir()
        self.directory = self.root / "owned"
        self.app = self.root / "Spillcheck.app"
        self.initial = {"permissions": {"allow": ["Bash(fake command)"]}, "custom": {"keep": True}}
        (self.work / ".claude").mkdir(mode=0o700)
        self.settings = self.work / ".claude/settings.local.json"
        self.write(self.settings, self.initial, 0o640)
        self.args = argparse.Namespace(directory=self.directory, workspace=self.work, app=self.app,
            configuration_executable=self.root / "config-helper", candidate_manifest=self.root / "candidate.json",
            expected_bundle_sha256="a" * 64, producer_version=VERSION, host_version="fake-t3-host")
        self.calls = []
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.native_session = str(uuid.uuid4())
        self.task = {"taskId": "owned-task", "childThreadId": "owned-thread", "childRunId": "owned-run",
                     "providerInstanceId": "claudeAgent", "model": "fake-test-model"}
        self.stack.enter_context(mock.patch.object(R.claude_desktop, "require_owned_project_root", return_value=self.work))
        self.stack.enter_context(mock.patch.object(R.live, "candidate_snapshot", return_value={"candidate": "fixed"}))
        self.stack.enter_context(mock.patch.object(R.subprocess, "run", side_effect=self.run_command))

    @staticmethod
    def write(path, value, mode=0o600):
        path.write_text(json.dumps(value))
        path.chmod(mode)

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        if command[:3] == ["/usr/bin/pgrep", "-x", "Spillcheck"]:
            return subprocess.CompletedProcess(command, 1, b"", b"")
        self.assertIn("--claude-configure-hook", command)
        state = R.state_for(self.directory)
        current = json.loads(self.settings.read_text()) if self.settings.exists() else {}
        if "--remove-hook" in command:
            current = R.claude_desktop.without_registration(current, state["registrationID"])
        else:
            for event in G.EVENTS:
                current.setdefault("hooks", {}).setdefault(event, []).append({"hooks": [{
                    "type": "command", "command": str(self.directory / "owned-hook"),
                    "args": R.helper_args(self.directory), "timeout": 2,
                    "statusMessage": "Spillcheck hook " + state["registrationID"]}]})
        self.write(self.settings, current)
        return subprocess.CompletedProcess(command, 0, b"", b"")

    def prepared(self):
        self.assertTrue(R.prepare(self.args)["prepared"])
        return R.state_for(self.directory)

    def bound(self):
        state = self.prepared()
        with mock.patch.object(Path, "cwd", return_value=self.work), \
                mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": self.native_session}):
            self.assertTrue(R.bind(self.directory)["runtimeIdentityRecorded"])
        return state

    def admitted(self):
        state = self.bound()
        source = G.native_source(str(self.work), self.native_session)
        accepted = {"session": self.native_session, "source": str(source), "workspace": str(self.work),
            "registrationID": state["registrationID"],
            "runtimeIdentitySHA256": G.read_json(self.directory / "runtime-identity-private.json")[1]}
        R.exclusive_json(self.directory / "gate-admission-private.json", accepted)
        R.exclusive_json(self.directory / "ready.json", {"collectorReady": True, "emptyBaseline": True,
            "registrationID": state["registrationID"]})
        return state, accepted

    def event(self, accepted, **changes):
        return dict({"session_id": self.native_session, "transcript_path": accepted["source"],
            "cwd": str(self.work), "hook_event_name": "PostToolUse", "tool_response": "only fake text"}, **changes)


class SettingsAndRuntimeTests(Fixture):
    def test_unowned_environment_secret_is_preserved_without_diagnostic_copy(self):
        fake = "FAKE_ONLY_UNOWNED_ENV_SECRET_DO_NOT_RETAIN_128d8f"
        initial = dict(self.initial, env={"FAKE_API_CREDENTIAL": fake})
        self.write(self.settings, initial, 0o640)
        state = self.prepared()
        self.assertEqual(json.loads(self.settings.read_text())["env"]["FAKE_API_CREDENTIAL"], fake)
        for path in self.directory.rglob("*"):
            if path.is_file():
                self.assertNotIn(fake.encode(), path.read_bytes(), str(path))
        self.assertFalse((self.directory / "initial-settings-private.json").exists())
        self.assertFalse((self.directory / "installed-settings-private.json").exists())
        self.assertTrue(R.cleanup_configuration(self.directory, state)["cleaned"])
        self.assertEqual(json.loads(self.settings.read_text()), initial)
        for path in self.directory.rglob("*"):
            if path.is_file():
                self.assertNotIn(fake.encode(), path.read_bytes(), str(path))

    def test_prepare_and_cleanup_preserve_current_unowned_settings_and_mode(self):
        state = self.prepared()
        self.assertTrue(R.owned_hooks_exact(json.loads(self.settings.read_text()), state, self.directory))
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o640)
        current = json.loads(self.settings.read_text())
        current["permissions"]["allow"].append("Bash(new user choice)")
        self.write(self.settings, current, 0o640)
        report = R.cleanup_configuration(self.directory, state)
        self.assertTrue(report["cleaned"])
        expected = dict(self.initial, permissions={"allow": ["Bash(fake command)", "Bash(new user choice)"]})
        self.assertEqual(json.loads(self.settings.read_text()), expected)
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o640)
        self.assertTrue(all("--claude-configure-hook" in command for command in self.calls))

    def test_failed_prepare_removes_new_empty_owned_settings_directory(self):
        self.settings.unlink()
        self.settings.parent.rmdir()
        with mock.patch.object(R.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"")):
            report = R.prepare(self.args)
        self.assertFalse(report["prepared"])
        self.assertTrue(report["configurationCleanup"]["cleaned"])
        self.assertFalse(self.settings.parent.exists())

    def test_partial_install_failure_removes_only_owned_handler(self):
        original = self.run_command
        def fail_after_write(command, **kwargs):
            result = original(command, **kwargs)
            return subprocess.CompletedProcess(command, 1 if "--remove-hook" not in command else 0, b"", b"")
        with mock.patch.object(R.subprocess, "run", side_effect=fail_after_write):
            report = R.prepare(self.args)
        self.assertFalse(report["prepared"])
        self.assertTrue(report["configurationCleanup"]["cleaned"])
        self.assertEqual(json.loads(self.settings.read_text()), self.initial)
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o640)

    def test_cleanup_preserves_replacement_settings_directory(self):
        self.settings.unlink()
        self.settings.parent.rmdir()
        state = self.prepared()
        old = self.work / ".claude-old"
        self.settings.parent.rename(old)
        self.settings.parent.mkdir(mode=0o700)
        report = R.cleanup_configuration(self.directory, state)
        self.assertTrue(report["cleaned"])
        self.assertTrue(self.settings.parent.is_dir())

    def test_cleanup_never_deletes_new_unowned_settings_after_empty_snapshot(self):
        self.settings.unlink()
        state = self.prepared()
        original_restore = R.restore_mode
        def concurrent_user_write(path, mode):
            original_restore(path, mode)
            self.write(path, {"env": {"FAKE_NEW_UNOWNED": "preserve"}}, mode)
        with mock.patch.object(R, "restore_mode", side_effect=concurrent_user_write):
            self.assertTrue(R.cleanup_configuration(self.directory, state)["cleaned"])
        self.assertEqual(json.loads(self.settings.read_text()), {"env": {"FAKE_NEW_UNOWNED": "preserve"}})

    def test_missing_or_foreign_runtime_cannot_bind(self):
        self.prepared()
        with mock.patch.object(Path, "cwd", return_value=self.work), mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": ""}):
            with self.assertRaises(ValueError):
                R.bind(self.directory)
        with mock.patch.object(Path, "cwd", return_value=self.root), mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": self.native_session}):
            with self.assertRaises(ValueError):
                R.bind(self.directory)
        self.assertFalse((self.directory / "runtime-identity-private.json").exists())

    def test_runtime_only_records_own_identity_without_source_selection(self):
        self.bound()
        runtime = G.read_json(self.directory / "runtime-identity-private.json")[0]
        self.assertEqual(set(runtime), {"schemaVersion", "nativeSessionID", "identitySource", "workingDirectory"})
        self.assertFalse((self.directory / "manifest.json").exists())
        command = R.collector_command(self.directory, R.state_for(self.directory), self.root / "native")
        for forbidden in ("--claude-active-source", "--claude-session", "--acceptance-allow-history-request"):
            self.assertNotIn(forbidden, command)
        self.assertIn("--acceptance-no-profile-catchup", command)
        self.assertEqual(command[command.index("--claude-interface") + 1], "t3")
        self.assertEqual({command[i + 1] for i, value in enumerate(command) if value == "--claude-authorized-host"}, {"t3", "standalone-cli"})

    def test_owned_matcher_change_cannot_claim_original_registration(self):
        state = self.prepared()
        current = json.loads(self.settings.read_text())
        current["hooks"]["PostToolUse"][0]["matcher"] = "different"
        self.assertFalse(R.owned_hooks_exact(current, state, self.directory))

    def test_wait_budget_is_global_and_requires_same_bound_runtime(self):
        self.bound()
        R.exclusive_json(self.directory / "wait-budget-private.json", {"startedMonotonic": 1})
        with mock.patch.object(Path, "cwd", return_value=self.work), mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": self.native_session}):
            self.assertEqual(R.wait_ready(self.directory, clock=lambda: 362, sleep=lambda _: None),
                {"collectorReady": False, "waitBudgetExhausted": True})
        with mock.patch.object(Path, "cwd", return_value=self.work), mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": str(uuid.uuid4())}):
            with self.assertRaises(ValueError):
                R.wait_ready(self.directory, clock=lambda: 362, sleep=lambda _: None)

    def test_readiness_needs_exact_gate_and_runtime_binding(self):
        state, accepted = self.admitted()
        with mock.patch.object(Path, "cwd", return_value=self.work), mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": self.native_session}):
            self.assertTrue(R.wait_ready(self.directory, clock=lambda: 5, sleep=lambda _: None)["collectorReady"])
        self.write(self.directory / "ready.json", {"collectorReady": True})
        with self.assertRaises(ValueError):
            G.admission(self.directory)

    def test_exclusive_control_publication_never_replaces_existing_bytes(self):
        path = self.root / "control.json"
        R.exclusive_json(path, {"first": True})
        original = path.read_bytes()
        with self.assertRaises(FileExistsError):
            R.exclusive_json(path, {"second": True})
        self.assertEqual(path.read_bytes(), original)

    def test_settings_symlink_is_rejected_before_mutation(self):
        self.settings.unlink()
        elsewhere = self.root / "elsewhere.json"
        self.write(elsewhere, self.initial)
        self.settings.symlink_to(elsewhere)
        with self.assertRaises(OSError):
            R.prepare(self.args)
        self.assertEqual(self.calls, [])


class OriginalHookGateTests(Fixture):
    def test_forwards_original_bytes_only_via_production_helper_arguments(self):
        _, accepted = self.admitted()
        raw = (json.dumps(self.event(accepted), indent=2) + " \n").encode()
        run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, b"original helper stdout", b"ignored private stderr"))
        result = G.forward(self.directory, raw, R.helper_args(self.directory), run=run)
        self.assertEqual(result, (0, b"original helper stdout"))
        self.assertEqual(run.call_args.kwargs["input"], raw)
        self.assertEqual(run.call_args.args[0], [str(self.app / "Contents/Helpers/spillcheck-hook"), *R.helper_args(self.directory)])
        evidence = R.hook_evidence(self.directory)
        self.assertEqual(evidence["originalHookCallbacksForwarded"], 1)
        journal = (self.directory / "hook-counts-private.jsonl").read_bytes()
        self.assertNotIn(b"only fake text", journal)
        self.assertNotIn(self.native_session.encode(), journal)

    def test_unadmitted_and_unrelated_callbacks_are_silent_and_unretained(self):
        self.bound()
        run = mock.Mock()
        self.assertEqual(G.forward(self.directory, b"not retained", [], run=run), (0, b""))
        state = R.state_for(self.directory)
        self.write(self.directory / "ready.json", {"invalid": True})
        self.write(self.directory / "gate-admission-private.json", {"invalid": True})
        self.assertEqual(G.forward(self.directory, json.dumps({"session_id": "another"}).encode(), [], run=run), (0, b""))
        run.assert_not_called()
        self.assertFalse((self.directory / "hook-counts-private.jsonl").exists())

    def test_exact_session_workspace_path_and_native_child_boundary(self):
        _, accepted = self.admitted()
        for changes in ({"session_id": str(uuid.uuid4())}, {"transcript_path": "/other/session.jsonl"},
                {"cwd": "/other"}, {"hook_event_name": "invented"},
                {"agent_transcript_path": str(Path(accepted["source"]).parent / "sibling/subagents/agent-x.jsonl")},
                {"agent_transcript_path": str(Path(accepted["source"]).parent / self.native_session / "subagents/../agent-x.jsonl")}):
            with self.subTest(changes=changes):
                self.assertFalse(G.selected_event(self.event(accepted, **changes), accepted))
        child = str(Path(accepted["source"]).parent / self.native_session / "subagents/agent-native.jsonl")
        self.assertTrue(G.selected_event(self.event(accepted, hook_event_name="SubagentStop", agent_transcript_path=child), accepted))
        self.assertFalse(G.selected_event(self.event(accepted, session_id="distinct-native-child", transcript_path=child), accepted))

    def test_changed_arguments_cannot_forward_selected_callback(self):
        _, accepted = self.admitted()
        run = mock.Mock()
        with self.assertRaises(ValueError):
            G.forward(self.directory, json.dumps(self.event(accepted)).encode(), ["--profile-id", "other"], run=run)
        run.assert_not_called()

    def test_duplicate_identity_fields_are_not_interpreted_or_forwarded(self):
        _, accepted = self.admitted()
        run = mock.Mock()
        self.assertEqual(G.forward(self.directory, b'{"session_id":"a","session_id":"b"}', R.helper_args(self.directory), run=run), (0, b""))
        run.assert_not_called()

    def test_helper_failure_is_counted_without_private_output(self):
        _, accepted = self.admitted()
        run = mock.Mock(side_effect=subprocess.TimeoutExpired("fake", 0.8, output=b"private"))
        with self.assertRaises(subprocess.TimeoutExpired):
            G.forward(self.directory, json.dumps(self.event(accepted)).encode(), R.helper_args(self.directory), run=run)
        self.assertFalse(R.hook_evidence(self.directory)["passed"])
        self.assertNotIn(b"private", (self.directory / "hook-counts-private.jsonl").read_bytes())

    def test_gate_integrity_detects_wrapper_or_config_change(self):
        self.prepared()
        self.assertTrue(R.gate_integrity(self.directory))
        with (self.directory / "owned-hook").open("ab") as file:
            file.write(b"# changed\n")
        self.assertFalse(R.gate_integrity(self.directory))

    def test_admission_cannot_substitute_a_source_outside_runtime_identity(self):
        _, accepted = self.admitted()
        self.write(self.directory / "gate-admission-private.json", dict(accepted, source="/unrelated/session.jsonl"))
        with self.assertRaises(ValueError):
            G.admission(self.directory)
        run = mock.Mock()
        self.assertEqual(G.forward(self.directory, json.dumps(self.event(accepted)).encode(), R.helper_args(self.directory), run=run), (0, b""))
        run.assert_not_called()

    def test_callback_and_inherited_helper_descriptor_drain_before_gate_closes(self):
        _, accepted = self.admitted()
        entered, release, drained = threading.Event(), threading.Event(), threading.Event()
        errors = []
        def helper(command, **kwargs):
            fd, = kwargs["pass_fds"]
            self.assertEqual(os.fstat(fd).st_ino, (self.directory / "callback.lock").stat().st_ino)
            entered.set()
            if not release.wait(2):
                raise AssertionError("fake helper was not released")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        def callback():
            try:
                G.forward(self.directory, json.dumps(self.event(accepted)).encode(), R.helper_args(self.directory), run=helper)
            except BaseException as error:
                errors.append(error)
        def close():
            try:
                R.close_admission(self.directory)
                drained.set()
            except BaseException as error:
                errors.append(error)
        worker = threading.Thread(target=callback)
        worker.start()
        self.assertTrue(entered.wait(1))
        closer = threading.Thread(target=close)
        closer.start()
        self.assertFalse(drained.wait(0.03))
        self.assertTrue((self.directory / "ready.json").exists())
        release.set()
        worker.join(2)
        closer.join(2)
        self.assertEqual(errors, [])
        self.assertTrue(drained.is_set())
        self.assertFalse((self.directory / "ready.json").exists())
        self.assertTrue(R.hook_evidence(self.directory)["passed"])

    def test_duplicate_lock_fd_keeps_callback_admitted_until_helper_exits(self):
        self.admitted()
        with G.callback_lock(self.directory) as fd:
            inherited = os.dup(fd)
        try:
            with self.assertRaises(TimeoutError):
                with G.callback_lock(self.directory, exclusive=True, timeout=0.02):
                    self.fail("inherited helper descriptor was not drained")
        finally:
            os.close(inherited)
        R.close_admission(self.directory)

    def test_replaced_lock_cannot_admit_or_claim_drained_callbacks(self):
        _, accepted = self.admitted()
        (self.directory / "callback.lock").rename(self.directory / "previous.lock")
        R.exclusive_bytes(self.directory / "callback.lock", b"")
        run = mock.Mock()
        self.assertEqual(G.forward(self.directory, json.dumps(self.event(accepted)).encode(), R.helper_args(self.directory), run=run), (0, b""))
        run.assert_not_called()
        with self.assertRaises(ValueError):
            R.close_admission(self.directory)


class TaskReceiptTests(Fixture):
    def test_terminal_receipt_requires_same_task_and_no_later_runs(self):
        path = self.root / "task.json"
        terminal = dict(self.task, status="completed", workState="result_available", hasPendingChildRuns=False)
        self.write(path, terminal)
        self.assertEqual(R.task_receipt(path, completed=True, initial=self.task)[0], self.task)
        for changes in ({"childThreadId": "different"}, {"hasPendingChildRuns": True},
                        {"status": "running"}, {"workState": "waiting_for_children"}):
            self.write(path, dict(terminal, **changes))
            with self.assertRaises(ValueError):
                R.task_receipt(path, completed=True, initial=self.task)

    def test_completion_is_bound_to_retained_terminal_receipt(self):
        self.admitted()
        R.exclusive_json(self.directory / "task-start-private.json", self.task)
        path = self.root / "terminal.json"
        self.write(path, dict(self.task, status="completed", workState="result_available", hasPendingChildRuns=False))
        self.assertTrue(R.finish(self.directory, path)["signaled"])
        self.assertEqual(R.completion_evidence(self.directory, self.task)["outcome"], "complete")
        self.write(self.directory / "task-finish-private.json", dict(self.task, status="completed", workState="result_available", hasPendingChildRuns=True))
        with self.assertRaises(ValueError):
            R.completion_evidence(self.directory, self.task)


class NativeBindingTests(Fixture):
    def native_prefix(self, **changes):
        source = G.native_source(str(self.work), self.native_session)
        source.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        row = dict({"type": "user", "sessionId": self.native_session, "cwd": str(self.work), "version": VERSION,
            "uuid": str(uuid.uuid4()), "timestamp": "2026-10-12T00:00:00Z", "parentUuid": None,
            "message": {"role": "user", "content": "LEAKRET_M3_PROMPT " + R.live.fixture.SECRET}}, **changes)
        source.write_text(json.dumps(row) + "\n")
        source.chmod(0o600)
        return source

    def test_runtime_source_derivation_verifies_original_native_prefix_without_source_injection(self):
        state = self.bound()
        with mock.patch.object(Path, "home", return_value=self.root):
            source = self.native_prefix()
            original = source.read_bytes()
            manifest, binding = R.register_source(self.directory, state)
        self.assertEqual(manifest["originalTranscriptPath"], str(source))
        self.assertTrue(binding["runtimeIdentitySourcePrefixBindingPassed"])
        self.assertFalse(binding["hostOriginIndependentlyVerified"])
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse((self.directory / "gate-admission-private.json").exists())
        self.assertFalse((self.directory / "store").exists())

    def test_foreign_native_identity_workspace_or_producer_cannot_bind(self):
        state = self.bound()
        with mock.patch.object(Path, "home", return_value=self.root):
            for changes in ({"sessionId": str(uuid.uuid4())}, {"cwd": str(self.root)}, {"version": "other"}):
                with self.subTest(changes=changes):
                    self.native_prefix(**changes)
                    with self.assertRaises(ValueError):
                        R.register_source(self.directory, state)
                    (self.directory / "manifest.json").unlink()
                    self.assertFalse((self.directory / "ready.json").exists())

    def test_symlink_native_source_is_not_opened(self):
        state = self.bound()
        with mock.patch.object(Path, "home", return_value=self.root):
            source = self.native_prefix()
            outside = self.root / "different-source.jsonl"
            source.rename(outside)
            source.symlink_to(outside)
            with self.assertRaises((OSError, ValueError, R.selected.NativeEvidenceFailure)):
                R.register_source(self.directory, state)
        self.assertFalse((self.directory / "gate-admission-private.json").exists())


class ObservationTests(Fixture):
    def run_observation(self, *, late_gap=False, failure=None):
        state = self.bound()
        self.task_path = self.root / "task-start.json"
        self.write(self.task_path, dict(self.task, status="running"))
        source = G.native_source(str(self.work), self.native_session)
        manifest = {"originalTranscriptPath": str(source), "nativeSessionId": self.native_session,
            "runtimeIdentitySHA256": G.read_json(self.directory / "runtime-identity-private.json")[1]}
        result, native = D.complete_evidence()
        result.update(valueCount=1, occurrenceCount=28, alertCount=1, syntheticOccurrenceCount=28,
            syntheticSessionCount=2, newVaultCleanupPassed=True)
        empty = dict(result, valueCount=0, occurrenceCount=0, alertCount=0, syntheticOccurrenceCount=0, syntheticSessionCount=0)
        before = dict(native, typedMarkers=["PROMPT"])
        growing = dict(native, typedMarkers=[marker for marker in native["typedMarkers"] if marker != "FINAL"])
        process = mock.Mock(returncode=None)
        process.poll.return_value = None
        def wait(**kwargs):
            self.assertFalse((self.directory / "ready.json").exists())
            self.assertFalse((self.directory / "gate-admission-private.json").exists())
            process.returncode = 0
            if failure == "wait":
                raise subprocess.TimeoutExpired("fake", 35)
            return 0
        process.wait.side_effect = wait
        def launch(*args, **kwargs):
            (self.directory / "store").mkdir()
            return process
        def finish_after_first_iteration(_):
            accepted = G.admission(self.directory)[1]
            G.forward(self.directory, json.dumps(self.event(accepted)).encode(), R.helper_args(self.directory),
                run=mock.Mock(return_value=subprocess.CompletedProcess([], 0, b"", b"")))
            terminal = self.root / "terminal.json"
            self.write(terminal, dict(self.task, status="completed", workState="result_available", hasPendingChildRuns=False))
            R.finish(self.directory, terminal)
        def current_report(_):
            return dict(result, gapReasons=["sourceUnavailable"]) if late_gap and process.returncode == 0 else result
        real_exclusive = R.exclusive_json
        def write(path, value):
            if failure == "finish" and path.name == "collector-finish":
                raise PermissionError("fake denied finish")
            return real_exclusive(path, value)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(R, "register_source", return_value=(manifest, {"bound": True})))
            stack.enter_context(mock.patch.object(R.selected, "registration_snapshot", return_value=(manifest, {"bound": True})))
            stack.enter_context(mock.patch.object(R.selected, "native_checkpoint", side_effect=[([], before, {"baseline": True}), ([], growing, {}), ([], native, {})]))
            stack.enter_context(mock.patch.object(R.selected, "source_appended_since", return_value=True))
            stack.enter_context(mock.patch.object(R.live, "wait_for_report", return_value=empty))
            stack.enter_context(mock.patch.object(R.live, "settled_report", return_value=result))
            stack.enter_context(mock.patch.object(R.live, "read_report", side_effect=current_report))
            stack.enter_context(mock.patch.object(R.subprocess, "Popen", side_effect=launch))
            stack.enter_context(mock.patch.object(R.desktop, "stop_group", return_value={"term_permission_denied": False, "kill_permission_denied": False}))
            stack.enter_context(mock.patch.object(R.time, "sleep", side_effect=finish_after_first_iteration))
            stack.enter_context(mock.patch.object(R, "exclusive_json", side_effect=write))
            if failure == "drain":
                stack.enter_context(mock.patch.object(R, "close_admission", side_effect=TimeoutError("fake pending callback")))
            report = R.observe(argparse.Namespace(directory=self.directory, output=self.root / "report.json", task_record=self.task_path, duration=60))
        return report

    def test_empty_collector_receives_original_hook_and_requires_final_checks(self):
        report = self.run_observation()
        self.assertTrue(report["passed"], report)
        self.assertFalse(report["activeSourcePrimed"])
        self.assertFalse(report["hostOriginIndependentlyVerified"])
        self.assertEqual(report["hookTransportInterface"], "standalone-cli")
        self.assertTrue(report["externalTaskReceiptsUnchanged"])
        self.assertEqual(json.loads(self.settings.read_text()), self.initial)

    def test_shutdown_gap_cannot_reuse_clean_live_proof(self):
        report = self.run_observation(late_gap=True)
        self.assertTrue(report["ordinaryHookProof"]["passed"])
        self.assertFalse(report["passed"])
        self.assertFalse(report["finalOrdinaryHookGatePassed"])

    def test_finish_signal_failure_still_closes_gate_stops_app_and_removes_hooks(self):
        report = self.run_observation(failure="finish")
        self.assertFalse(report["passed"])
        self.assertTrue(report["termination"]["processGroupStopped"])
        self.assertTrue(report["cleaned"])
        self.assertFalse((self.directory / "ready.json").exists())

    def test_wait_failure_still_stops_group_and_removes_owned_configuration(self):
        report = self.run_observation(failure="wait")
        self.assertFalse(report["passed"])
        self.assertTrue(report["termination"]["processGroupStopped"])
        self.assertTrue(report["cleaned"])

    def test_failed_callback_drain_cannot_pass_but_still_closes_signals_and_hooks(self):
        report = self.run_observation(failure="drain")
        self.assertFalse(report["passed"])
        self.assertFalse(report["termination"]["callbacksDrainedBeforeShutdown"])
        self.assertTrue(report["termination"]["processGroupStopped"])
        self.assertTrue(report["hookCleanup"]["removed"])
        self.assertTrue(report["gateSignalsRemoved"])
        self.assertFalse(report["cleaned"])

    def test_pgrep_inventory_failure_never_launches_app_and_cleans_hooks(self):
        self.bound()
        path = self.root / "task.json"
        self.write(path, self.task)
        manifest = {"originalTranscriptPath": str(G.native_source(str(self.work), self.native_session)),
            "nativeSessionId": self.native_session, "runtimeIdentitySHA256": "fake"}
        original_run = self.run_command
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 2, b"", b"") if command[0] == "/usr/bin/pgrep" else original_run(command, **kwargs)
        with mock.patch.object(R, "register_source", return_value=(manifest, {"bound": True})), \
                mock.patch.object(R.subprocess, "run", side_effect=run), mock.patch.object(R.subprocess, "Popen") as launch:
            report = R.observe(argparse.Namespace(directory=self.directory, output=self.root / "report.json", task_record=path, duration=60))
        launch.assert_not_called()
        self.assertFalse(report["passed"])
        self.assertTrue(report["cleaned"])


if __name__ == "__main__":
    unittest.main()
