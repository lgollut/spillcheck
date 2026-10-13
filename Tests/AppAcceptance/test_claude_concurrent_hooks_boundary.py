import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("concurrent_hooks_boundary", Path(__file__).with_name("run-app-claude-concurrent-hooks.py"))
H = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(H)
REAL_RUN = subprocess.run


def app_report(state, completed=H.HOSTS):
    markers = H.live.fixture.EXPECTED_MARKERS
    return {"storageReady": True, "collectionConfigured": True, "coverageReportTruncated": False,
        "gapReasons": [], "transportRejectionCountsByStageAndReason": {}, "queueCount": 0,
        "claudeCommittedNativeParentChildPairCountByProducer": H.counts_for(state, completed),
        "claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
        "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
        "claudeTypedCommittedMarkersByRole": {role: {name: 1 for name in markers
            if name.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
        "claudeCommittedContentTypesByRole": {role: sorted(set(markers.values())) for role in ("parent", "child")},
        "syntheticSessionCount": 3, "observedAgentVersions": sorted(H.counts_for(state, H.HOSTS)),
        "valueCount": 1, "occurrenceCount": 90, "alertCount": 0, "syntheticOccurrenceCount": 90}


class ConcurrentHooksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.workspace = self.root / "inherited"
        self.workspace.mkdir(mode=0o700)
        REAL_RUN(["/usr/bin/git", "init", "--quiet", "--template=", str(self.workspace)],
            env=H.claude_desktop.git_environment(), check=True)
        (self.workspace / ".claude").mkdir(mode=0o700)
        self.original = {"unowned": "fake-existing-setting"}
        H.signal(self.workspace / ".claude", "settings.local.json", self.original)
        self.executable = self.root / "claude"
        self.executable.write_bytes(b"fake executable never launched")
        self.executable.chmod(0o700)
        self.directory = self.root / "run"
        self.args = argparse.Namespace(directory=self.directory, workspace=self.workspace,
            app=self.root / "Spillcheck.app", configuration_executable=self.root / "configure",
            candidate_manifest=self.root / "candidate.json", expected_bundle_sha256="a" * 64,
            cli_executable=self.executable, cli_version="2.1.296", desktop_version="2.1.295",
            desktop_host_version="fake-desktop", t3_host_version="fake-t3")

    def tearDown(self):
        self.temporary.cleanup()

    def editor(self, command, **kwargs):
        if command[0] == "/usr/bin/git":
            return REAL_RUN(command, **kwargs)
        if command[:2] == ["/usr/bin/pgrep", "-x"]:
            return argparse.Namespace(returncode=1)
        def option(name):
            return command[command.index(name) + 1]
        settings = Path(option("--settings"))
        before = json.loads(settings.read_text()) if settings.exists() else {}
        identity = option("--registration-id")
        value = H.claude_desktop.without_registration(before, identity)
        if "--remove-hook" not in command:
            for event in H.gate.EVENTS:
                value.setdefault("hooks", {}).setdefault(event, []).append({"hooks": [{"type": "command",
                    "command": option("--helper"), "args": ["--socket", option("--socket"), "--agent", "claude-code",
                        "--interface", "standalone-cli", "--profile-id", option("--profile")],
                    "timeout": 2, "statusMessage": "Spillcheck hook " + identity}]})
        settings.write_text(json.dumps(value))
        settings.chmod(0o600)
        return argparse.Namespace(returncode=0)

    def prepared(self):
        with mock.patch.object(H.live, "candidate_snapshot", return_value={"bound": True}), \
                mock.patch.object(H.subprocess, "run", side_effect=self.editor):
            result = H.prepare(self.args)
        self.assertTrue(result["prepared"])
        return H.state_for(self.directory)

    def test_prepare_only_owned_local_hooks_one_socket_no_provider(self):
        state = self.prepared()
        args = []
        for host in H.HOSTS:
            settings = H.t3.settings_snapshot(Path(state["lanes"][host]["workspace"]))[0]
            self.assertTrue(H.owned_hooks_exact(settings, self.directory, state, host))
            config = H.gate.read_json(self.directory / host / "gate-config-private.json")[0]
            args.append(config["helperArgs"])
        self.assertEqual(args, [H.helper_args(self.directory)] * 3)
        self.assertFalse((self.directory / "store").exists())
        self.assertFalse((self.workspace / ".mcp.json").exists())
        self.assertEqual(H.claude_desktop.without_registration(H.t3.settings_snapshot(self.workspace)[0],
            state["lanes"]["t3"]["registrationID"]), self.original)

    def test_executable_hash_streams_beyond_transcript_cap(self):
        size = 2 * 1024 * 1024 + 37
        with self.executable.open("wb") as file:
            file.truncate(size)
        expected = hashlib.sha256()
        for count in (1024 * 1024, 1024 * 1024, 37):
            expected.update(bytes(count))
        original_read = H.os.read
        reads = []
        def bounded_read(fd, count):
            reads.append(count)
            return original_read(fd, count)
        with mock.patch.object(H.os, "read", side_effect=bounded_read):
            self.assertEqual(H.executable_sha256(self.executable), expected.hexdigest())
        self.assertTrue(all(count <= 1024 * 1024 for count in reads))
        with self.assertRaises(H.selected.NativeEvidenceFailure):
            H.selected._read(self.executable, H.MAX_EXECUTABLE_BYTES)

    def test_executable_hash_rejects_fifo_symlink_nonexec_and_oversize(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo, 0o700)
        with self.assertRaises(ValueError):
            H.executable_sha256(fifo)
        link = self.root / "link"
        link.symlink_to(self.executable)
        with self.assertRaises(ValueError):
            H.executable_sha256(link)
        self.executable.chmod(0o600)
        with self.assertRaises(ValueError):
            H.executable_sha256(self.executable)
        self.executable.chmod(0o700)
        with self.executable.open("wb") as file:
            file.truncate(H.MAX_EXECUTABLE_BYTES + 1)
        with self.assertRaises(ValueError):
            H.executable_sha256(self.executable)

    def test_executable_replacement_during_hash_rejected(self):
        original_read = H.os.read
        replaced = False
        def replace_after_read(fd, count):
            nonlocal replaced
            data = original_read(fd, count)
            if not replaced:
                replacement = self.root / "replacement"
                replacement.write_bytes(b"new executable")
                replacement.chmod(0o700)
                replacement.replace(self.executable)
                replaced = True
            return data
        with mock.patch.object(H.os, "read", side_effect=replace_after_read), self.assertRaises(ValueError):
            H.executable_sha256(self.executable)

    def test_prepare_binary_failure_has_closed_stage_before_mutation(self):
        self.executable.chmod(0o600)
        with mock.patch.object(H.live, "candidate_snapshot", return_value={"bound": True}):
            result = H.prepare(self.args)
        self.assertFalse(result["prepared"])
        self.assertEqual(result["failureStage"], "preparation-executable")
        self.assertFalse(self.directory.exists())
        self.assertEqual(H.t3.settings_snapshot(self.workspace)[0], self.original)

    def test_unreleased_bounded_wait_is_normal_progress(self):
        for operation in ("wait-ready", "wait-final"):
            self.assertEqual(H.operation_exit_code(operation, {"released": False, "waitBudgetExhausted": False}), 0)
            self.assertEqual(H.operation_exit_code(operation, {"released": True, "waitBudgetExhausted": False}), 0)
            self.assertEqual(H.operation_exit_code(operation, {"released": False, "waitBudgetExhausted": True}), 1)
        self.assertEqual(H.operation_exit_code("prepare", {"prepared": False}), 1)

    def test_independent_processes_share_budget_and_heartbeat_clock(self):
        state = self.prepared()
        host = "desktop"
        session = str(H.uuid.uuid4())
        place = self.directory / host
        work = state["lanes"][host]["workspace"]
        H.signal(place, "runtime-identity-private.json", {"schemaVersion": 1, "nativeSessionID": session,
            "workingDirectory": work, "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID"})
        code = """import importlib.util, json, os, pathlib, sys, time
spec = importlib.util.spec_from_file_location('fresh_clock_probe', sys.argv[1])
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
os.chdir(sys.argv[3]); os.environ['CLAUDE_CODE_SESSION_ID'] = sys.argv[4]
time.sleep(float(sys.argv[5]))
ticks = iter([0.0, 41.0])
sample = runner.shared_clock()
result = runner.wait_release(pathlib.Path(sys.argv[2]), 'desktop', clock=lambda: next(ticks), sleep=lambda _: None)
budget = runner.gate.read_json(pathlib.Path(sys.argv[2]) / 'desktop/ready-wait-budget-private.json')[0]
print(json.dumps({'sample': sample, 'result': result, 'budget': budget}))
"""
        def run(delay):
            result = REAL_RUN([sys.executable, "-c", code, str(H.HERE), str(self.directory), work, session, str(delay)],
                capture_output=True, timeout=15, check=True)
            return json.loads(result.stdout)
        first = run(0.3)
        second = run(0)
        self.assertLessEqual(first["sample"], first["budget"]["startedMonotonic"])
        self.assertLessEqual(first["budget"]["startedMonotonic"], second["sample"])
        self.assertLess(second["sample"] - first["sample"], 15)
        self.assertEqual(first["budget"], second["budget"])
        self.assertEqual(first["budget"]["clock"], "CLOCK_MONOTONIC")
        self.assertEqual(first["result"], {"released": False, "waitBudgetExhausted": False})
        self.assertEqual(second["result"], first["result"])

    def test_legacy_cross_process_budget_is_rejected(self):
        state = self.prepared()
        session = str(H.uuid.uuid4())
        runtime = {"nativeSessionID": session, "workingDirectory": str(Path.cwd().resolve())}
        H.signal(self.directory / "desktop", "ready-wait-budget-private.json", {"startedMonotonic": 0.1})
        with mock.patch.object(H, "state_for", return_value=state), \
                mock.patch.object(H, "bound_runtime", return_value=(runtime, "fake")), \
                mock.patch.dict(os.environ, {"CLAUDE_CODE_SESSION_ID": session}), self.assertRaises(ValueError):
            H.wait_release(self.directory, "desktop")

    def test_missing_shared_clock_fails_before_preparation_mutation(self):
        with mock.patch.object(H.time, "clock_gettime", None):
            result = H.prepare(self.args)
        self.assertFalse(result["prepared"])
        self.assertEqual(result["failureStage"], "preparation-clock")
        self.assertFalse(self.directory.exists())

    def test_premature_completion_and_abort_fail_fast(self):
        self.prepared()
        H.signal(self.directory / "cli", "producer-finished.json", {"completed": False})
        with self.assertRaises(H.ProducerFailure) as premature:
            H.require_producers_active(self.directory)
        self.assertEqual(premature.exception.code, "producer-finished-before-release")
        with self.assertRaises(H.ProducerFailure) as failed:
            H.require_producers_active(self.directory, ("cli",))
        self.assertEqual(failed.exception.code, "producer-failed")
        H.signal(self.directory, "observer-aborted.json", {"aborted": True})
        with self.assertRaises(H.ProducerFailure) as aborted:
            H.require_producers_active(self.directory, H.HOSTS)
        self.assertEqual(aborted.exception.code, "observer-aborted")

    def test_three_gates_forward_only_own_original_packet(self):
        state = self.prepared()
        packets = {}
        for host in H.HOSTS:
            lane, place = state["lanes"][host], self.directory / host
            session = str(H.uuid.uuid4())
            H.signal(place, "runtime-identity-private.json", {"schemaVersion": 1, "nativeSessionID": session,
                "workingDirectory": lane["workspace"], "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID"})
            digest = H.gate.read_json(place / "runtime-identity-private.json")[1]
            source = str(H.gate.native_source(lane["workspace"], session))
            H.signal(place, "gate-admission-private.json", {"session": session, "workspace": lane["workspace"],
                "source": source, "runtimeIdentitySHA256": digest, "registrationID": lane["registrationID"]})
            H.signal(place, "ready.json", {"collectorReady": True, "emptyBaseline": True, "registrationID": lane["registrationID"]})
            packets[host] = json.dumps({"hook_event_name": "Stop", "session_id": session,
                "cwd": lane["workspace"], "transcript_path": source}, indent=1).encode()
        for destination in H.HOSTS:
            for source in H.HOSTS:
                runner = mock.Mock(return_value=argparse.Namespace(returncode=0, stdout=b"{}"))
                H.gate.forward(self.directory / destination, packets[source], H.helper_args(self.directory), run=runner)
                self.assertEqual(runner.call_count, int(destination == source))
                if destination == source:
                    self.assertEqual(runner.call_args.kwargs["input"], packets[source])
            event = json.loads(packets[destination])
            for change in ({"transcript_path": "/unrelated/private.jsonl"}, {"hook_event_name": "SpillcheckTranscriptPoll"},
                    {"agent_transcript_path": "/unrelated/child.jsonl"}):
                runner = mock.Mock()
                H.gate.forward(self.directory / destination, json.dumps(dict(event, **change)).encode(),
                    H.helper_args(self.directory), run=runner)
                runner.assert_not_called()

    def test_collector_is_one_root_unprimed_without_history(self):
        state = self.prepared()
        command = H.collector_command(self.directory, state)
        self.assertEqual(command.count("--claude-source-root"), 1)
        self.assertEqual(command[command.index("--claude-source-root") + 1], str(Path.home() / ".claude/projects"))
        self.assertIn("--acceptance-no-profile-catchup", command)
        for flag in ("--claude-active-source", "--claude-session", "--acceptance-recovery-worker"):
            self.assertNotIn(flag, command)

    def test_prompts_have_runtime_wait_and_final_wait(self):
        self.prepared()
        for host in H.HOSTS:
            prompt = (self.directory / host / "PROMPT.txt").read_text()
            self.assertIn("wait-ready", prompt)
            self.assertIn("wait-final", prompt)
            self.assertIn("Do not create a worktree", prompt)
            self.assertIn("LEAKRET_M3_CHILD_PROMPT", prompt)

    def test_cleanup_preserves_current_unowned_settings_and_mode(self):
        state = self.prepared()
        path = self.workspace / ".claude/settings.local.json"
        value = json.loads(path.read_text())
        value["laterUnowned"] = "preserve me"
        path.write_text(json.dumps(value))
        path.chmod(0o640)
        with mock.patch.object(H.subprocess, "run", side_effect=self.editor):
            report = H.cleanup(self.directory, state)
        self.assertTrue(report["cleaned"])
        self.assertEqual(json.loads(path.read_text()), dict(self.original, laterUnowned="preserve me"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        for host in ("cli", "desktop"):
            self.assertFalse((self.directory / host / "work/.mcp.json").exists())

    def test_cleanup_changed_mcp_preserved_and_other_hooks_removed(self):
        state = self.prepared()
        changed = self.directory / "desktop/work/.mcp.json"
        changed.write_text('{"unowned":"new"}')
        with mock.patch.object(H.subprocess, "run", side_effect=self.editor):
            result = H.cleanup(self.directory, state)
        self.assertFalse(result["cleaned"])
        self.assertTrue(changed.exists())
        self.assertTrue(all(item["hooksRemoved"] for item in result["lanes"].values()))

    def test_prepare_failure_rolls_back_earlier_owned_hooks(self):
        count = 0
        def fail_second(command, **kwargs):
            nonlocal count
            if command[0] != "/usr/bin/git" and "--remove-hook" not in command:
                count += 1
                if count == 2:
                    raise OSError("injected")
            return self.editor(command, **kwargs)
        with mock.patch.object(H.live, "candidate_snapshot", return_value={"bound": True}), \
                mock.patch.object(H.subprocess, "run", side_effect=fail_second):
            result = H.prepare(self.args)
        self.assertFalse(result["prepared"])
        self.assertTrue(result["configurationCleanup"]["cleaned"])
        self.assertEqual(H.t3.settings_snapshot(self.workspace)[0], self.original)

    def test_failed_drain_removes_signals_and_all_owned_configuration(self):
        state = self.prepared()
        for host in H.HOSTS:
            H.signal(self.directory / host, "ready.json", {"fake": True})
        with mock.patch.object(H.t3, "close_admission", side_effect=RuntimeError("injected")), \
                mock.patch.object(H.subprocess, "run", side_effect=self.editor):
            result = H.cleanup(self.directory, state)
        self.assertFalse(result["cleaned"])
        self.assertTrue(all(item["hooksRemoved"] for item in result["lanes"].values()))
        self.assertFalse(any((self.directory / host / "ready.json").exists() for host in H.HOSTS))

    def test_malformed_hook_structures_rejected(self):
        state = self.prepared()
        for settings in ({"hooks": []}, {"hooks": {"Stop": [None]}}, {"hooks": {"Stop": [{"hooks": [None]}]}}):
            self.assertFalse(H.owned_hooks_exact(settings, self.directory, state, "cli"))

    def test_exact_pair_progression_does_not_union_wrong_versions(self):
        state = self.prepared()
        report = app_report(state, ("desktop",))
        self.assertTrue(H.exact_pairs(report, state, ("desktop",)))
        self.assertFalse(H.exact_pairs(report, state, ("cli",)))
        report["claudeCommittedNativeParentChildPairCountByProducer"] = {"2.1.296": 3}
        self.assertFalse(H.exact_pairs(report, state, H.HOSTS))

    def test_boolean_pair_count_rejected(self):
        state = self.prepared()
        report = app_report(state, ("desktop",))
        report["claudeCommittedNativeParentChildPairCountByProducer"] = {"2.1.295": True}
        self.assertFalse(H.exact_pairs(report, state, ("desktop",)))

    def final_arguments(self):
        state = self.prepared()
        native = {"passed": True, "allThreePairsComplete": True, "admittedUniverseValid": True, "nativeCanonicalSessionCount": 3}
        stages = [{"host": host, "passed": True,
            "expectedCommittedPairsByProducer": H.counts_for(state, H.FINAL_ORDER[:index + 1])}
            for index, host in enumerate(H.FINAL_ORDER)]
        return state, native, stages

    def test_complete_final_gate(self):
        state, native, stages = self.final_arguments()
        self.assertTrue(H.final_gate(app_report(state), state, native, True, stages, True))

    def test_late_gap_rejection_queue_and_truncation_fail_final(self):
        state, native, stages = self.final_arguments()
        for key, value in (("gapReasons", ["sourceUnavailable"]),
                ("transportRejectionCountsByStageAndReason", {"test": 1}), ("queueCount", 1), ("coverageReportTruncated", True)):
            report = app_report(state)
            report[key] = value
            self.assertFalse(H.final_gate(report, state, native, True, stages, True), key)

    def test_extra_pair_or_missing_host_session_fails_final(self):
        state, native, stages = self.final_arguments()
        report = app_report(state)
        report["claudeCommittedNativeParentChildPairCountByProducer"]["2.1.296"] = 3
        self.assertFalse(H.final_gate(report, state, native, True, stages, True))
        report = app_report(state)
        report["syntheticSessionCount"] = 2
        self.assertFalse(H.final_gate(report, state, native, True, stages, True))

    def test_native_universe_and_concurrency_are_required(self):
        state, native, stages = self.final_arguments()
        self.assertFalse(H.final_gate(app_report(state), state, native, False, stages, True))
        native["admittedUniverseValid"] = False
        self.assertFalse(H.final_gate(app_report(state), state, native, True, stages, True))

    def test_distinct_child_native_session_requires_matching_committed_count(self):
        state, native, stages = self.final_arguments()
        native["nativeCanonicalSessionCount"] = 4
        report = app_report(state)
        self.assertFalse(H.final_gate(report, state, native, True, stages, True))
        report["syntheticSessionCount"] = 4
        self.assertTrue(H.final_gate(report, state, native, True, stages, True))

    def test_frozen_completion_receipts_cannot_be_replaced(self):
        self.prepared()
        initial = {key: "fake-" + key for key in H.t3.TASK_KEYS}
        names = [f"{host}/producer-finished.json" for host in H.HOSTS] + ["cli/process-start-private.json",
            "t3/task-start-private.json", "t3/external-finish-private.json", "desktop/external-finish-private.json"]
        for name in names:
            path = self.directory / name
            H.signal(path.parent, path.name, initial if name == "t3/task-start-private.json" else {"fake": True})
        before = H.completion_snapshot(self.directory, initial)
        with mock.patch.object(H, "completion_evidence", return_value=True):
            self.assertTrue(H.completion_unchanged(self.directory, {}, initial, before))
            (self.directory / "desktop/external-finish-private.json").write_text('{"fake":false}')
            self.assertFalse(H.completion_unchanged(self.directory, {}, initial, before))
        (self.directory / "t3/task-start-private.json").write_text(json.dumps(dict(initial, taskId="replacement")))
        with self.assertRaises(ValueError):
            H.completion_snapshot(self.directory, initial)

    def test_same_public_native_counts_cannot_hide_changed_source_suffix(self):
        self.prepared()
        H.signal(self.directory, "source-bindings-private.json", {"lanes": []})
        digest = H.gate.read_json(self.directory / "preparation-private.json")[1]
        frozen = {("fake-parent", "fake-session"): (300, "old-digest")}
        with mock.patch.object(H, "inspect_concurrent_sources", return_value=([], {"same": True}, frozen)):
            self.assertTrue(H.native_sources_unchanged(self.directory, [], {"same": True}, frozen, digest))
        replaced = {("fake-parent", "fake-session"): (300, "changed-digest")}
        with mock.patch.object(H, "inspect_concurrent_sources", return_value=([], {"same": True}, replaced)):
            self.assertFalse(H.native_sources_unchanged(self.directory, [], {"same": True}, frozen, digest))

    def test_external_receipt_formatting_uses_committed_digest(self):
        state = self.prepared()
        H.signal(self.directory / "desktop", "runtime-identity-private.json", {"schemaVersion": 1,
            "nativeSessionID": str(H.uuid.uuid4()), "workingDirectory": state["lanes"]["desktop"]["workspace"],
            "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID"})
        value = {"sourceHost": "official-claude-desktop", "originalLocalWorkspace": True,
            "normalHookReviewCompleted": True, "finalResponseObserved": True,
            "producerVersion": "2.1.295", "hostVersion": "fake-desktop"}
        receipt = self.root / "external.json"
        receipt.write_text(json.dumps(value, separators=(",", ":")))
        receipt.chmod(0o600)
        self.assertTrue(H.record_external(self.directory, "desktop", receipt)["recorded"])
        result = H.gate.read_json(self.directory / "desktop/producer-finished.json")[0]
        self.assertEqual(result["externalReceiptSHA256"], H.gate.read_json(self.directory / "desktop/external-finish-private.json")[1])
        self.assertNotEqual(result["externalReceiptSHA256"], result["originalExternalReceiptSHA256"])

    def test_cleanup_signal_failure_still_removes_all_owned_configuration(self):
        state = self.prepared()
        original = H.signal
        def fail_closed(place, name, value):
            if name == "collection-closed.json":
                raise OSError("injected")
            return original(place, name, value)
        with mock.patch.object(H, "signal", side_effect=fail_closed), \
                mock.patch.object(H.subprocess, "run", side_effect=self.editor):
            result = H.cleanup(self.directory, state)
        self.assertFalse(result["cleaned"])
        self.assertTrue(all(item["hooksRemoved"] for item in result["lanes"].values()))

    def test_stale_or_wrong_runtime_heartbeat_rejected(self):
        self.prepared()
        lanes = [{"host": host, "runtimeIdentitySHA256": host * 4} for host in H.HOSTS]
        for lane in lanes:
            place = self.directory / lane["host"]
            H.signal(place, "at-final-barrier.json", {"runtimeIdentitySHA256": lane["runtimeIdentitySHA256"]})
            H.pulse(place, {"runtimeIdentitySHA256": lane["runtimeIdentitySHA256"], "clock": "CLOCK_MONOTONIC", "monotonic": 100, "pid": os.getpid()})
        self.assertTrue(H.all_producers_waiting(self.directory, lanes, now=101))
        self.assertFalse(H.all_producers_waiting(self.directory, lanes, now=104))
        H.pulse(self.directory / "cli", {"runtimeIdentitySHA256": "wrong", "clock": "CLOCK_MONOTONIC", "monotonic": 100, "pid": os.getpid()})
        self.assertFalse(H.all_producers_waiting(self.directory, lanes, now=101))

    def test_unavailable_process_inventory_never_launches(self):
        state = self.prepared()
        task = self.root / "task.json"
        H.signal(task.parent, task.name, {key: "fake-" + key for key in H.t3.TASK_KEYS})
        args = argparse.Namespace(directory=self.directory, output=self.root / "result.json", duration=60, task_record=task)
        def inventory_error(command, **kwargs):
            if command[:2] == ["/usr/bin/pgrep", "-x"]:
                return argparse.Namespace(returncode=2)
            return self.editor(command, **kwargs)
        with mock.patch.object(H, "state_for", return_value=state), \
                mock.patch.object(H, "register_sources", return_value=[]), \
                mock.patch.object(H.live, "candidate_snapshot", return_value={"bound": True}), \
                mock.patch.object(H.subprocess, "run", side_effect=inventory_error), \
                mock.patch.object(H.subprocess, "Popen") as launch:
            result = H.observe(args)
        self.assertFalse(result["passed"])
        launch.assert_not_called()
        self.assertEqual(result["failureStage"], "binding")
        self.assertIn("frozen-proof", result["unmetGates"])
        self.assertTrue(result["configurationCleanup"]["cleaned"])

    def test_stop_failure_does_not_skip_configuration_cleanup_or_report(self):
        state = self.prepared()
        task = self.root / "task.json"
        H.signal(task.parent, task.name, {key: "fake-" + key for key in H.t3.TASK_KEYS})
        args = argparse.Namespace(directory=self.directory, output=self.root / "result.json", duration=60, task_record=task)
        process = mock.Mock(returncode=None)
        process.wait.side_effect = RuntimeError("injected wait failure")
        with mock.patch.object(H, "state_for", return_value=state), \
                mock.patch.object(H, "register_sources", return_value=[]), \
                mock.patch.object(H.live, "candidate_snapshot", return_value={"bound": True}), \
                mock.patch.object(H.subprocess, "run", side_effect=self.editor), \
                mock.patch.object(H.subprocess, "Popen", return_value=process), \
                mock.patch.object(H.live, "wait_for_report", side_effect=ValueError("no baseline")), \
                mock.patch.object(H.desktop, "stop_group", side_effect=RuntimeError("injected stop failure")):
            result = H.observe(args)
        self.assertFalse(result["passed"])
        self.assertEqual(result["failureStage"], "empty-readiness")
        self.assertTrue(result["configurationCleanup"]["cleaned"])
        self.assertTrue(args.output.is_file())
        self.assertFalse(result["termination"]["normalWaitCompleted"])


if __name__ == "__main__":
    unittest.main()
