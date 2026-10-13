"""Synthetic acceptance gate/retention regressions; no provider or signed app is invoked."""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("codex_fixture", pathlib.Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
LATENCY_SPEC = importlib.util.spec_from_file_location("codex_latency", pathlib.Path(__file__).with_name("measure-latency.py"))
LATENCY = importlib.util.module_from_spec(LATENCY_SPEC)
LATENCY_SPEC.loader.exec_module(LATENCY)


def complete():
    return {"typedCommitted": dict.fromkeys(RUNNER.REQUIRED_MARKERS, 1),
            "typedCommittedByRole": {"parent": dict.fromkeys(RUNNER.PARENT_MARKERS, 1),
                                    "child": dict.fromkeys(RUNNER.CHILD_MARKERS, 1)},
            "nativeSourceRoles": dict.fromkeys(("primarySessionCount", "verifiedPrimarySessionCount",
                "nativeLinkedChildSessionCount", "verifiedNativeLinkedChildSessionCount"), 1),
            "sessionCount": 2}


class TypedGateTests(unittest.TestCase):
    def test_complete_exact_parent_and_child_passes(self):
        self.assertTrue(RUNNER.typed_source_gate(complete()))

    def test_old_eight_marker_gate_cannot_pass(self):
        value = complete()
        for marker in RUNNER.CHILD_MARKERS - {"CHILD_FINAL"}:
            del value["typedCommitted"][marker]
            del value["typedCommittedByRole"]["child"][marker]
        self.assertFalse(RUNNER.typed_source_gate(value))

    def test_each_child_type_is_independently_required(self):
        for marker in RUNNER.CHILD_MARKERS:
            with self.subTest(marker=marker):
                value = complete()
                del value["typedCommittedByRole"]["child"][marker]
                # Aggregate claims remain complete: they cannot substitute for per-role evidence.
                self.assertFalse(RUNNER.typed_source_gate(value))

    def test_parent_mirror_unknown_role_or_duplicate_does_not_pass(self):
        value = complete()
        value["typedCommittedByRole"]["parent"].update(value["typedCommittedByRole"]["child"])
        value["typedCommittedByRole"]["child"] = {}
        self.assertFalse(RUNNER.typed_source_gate(value))
        for count in (0, 2, True, "1"):
            value = complete()
            value["typedCommitted"]["CHILD_PROMPT"] = count
            self.assertFalse(RUNNER.typed_source_gate(value))
        value = complete()
        value["typedCommittedByRole"]["unknown"] = {}
        self.assertFalse(RUNNER.typed_source_gate(value))

    def test_exact_verified_source_pair_is_required(self):
        for key in complete()["nativeSourceRoles"]:
            for count in (0, 2, True):
                value = complete()
                value["nativeSourceRoles"][key] = count
                self.assertFalse(RUNNER.typed_source_gate(value))
        for count in (1, 3, True, "2"):
            value = complete()
            value["sessionCount"] = count
            self.assertFalse(RUNNER.typed_source_gate(value))

    def test_live_gate_requires_before_catchup_evidence(self):
        value = complete()
        self.assertFalse(RUNNER.typed_source_gate(value, before_catchup=True))
        value["typedCommittedBeforeCatchUp"] = value["typedCommitted"]
        value["typedCommittedByRoleBeforeCatchUp"] = value["typedCommittedByRole"]
        self.assertTrue(RUNNER.typed_source_gate(value, before_catchup=True))

    def test_missing_malformed_or_untyped_report_cannot_pass(self):
        for value in (None, [], {}, complete() | {"typedCommittedByRole": None},
                      complete() | {"nativeSourceRoles": None}):
            self.assertFalse(RUNNER.typed_source_gate(value))

    def test_fixture_contains_literal_child_prompt_and_all_five_types(self):
        prompt = RUNNER.fixture_prompt()
        child = json.loads(prompt.split("exact JSON string without shortening or rephrasing it: ", 1)[1].splitlines()[0])
        self.assertTrue(child.startswith("LEAKRET_M4_CHILD_PROMPT " + RUNNER.TOKEN))
        self.assertIn("fork_turns=none", prompt)
        for marker in RUNNER.CHILD_MARKERS:
            self.assertEqual(child.count("LEAKRET_M4_" + marker), 1)
        self.assertIn("exits 7", child)
        self.assertIn("Do not read files, browse, or create children", child)


class FailedSourceRetentionTests(unittest.TestCase):
    def test_only_bounded_original_rollouts_are_retained_privately(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            home = root / "home"
            sessions = home / "sessions" / "2026" / "10" / "11"
            sessions.mkdir(parents=True)
            data = b'{"type":"fake-original-native-item"}\n'
            (sessions / "rollout.jsonl").write_bytes(data)
            (home / "auth.json").write_text("fake-credential-must-not-be-retained")
            (home / "config.toml").write_text("unrelated-config")
            (sessions / "ignored.txt").write_text("not-a-rollout")
            output = root / "retained"
            result = RUNNER.retain_failed_sources(home, output)
            self.assertEqual(result["fileCount"], 1)
            self.assertEqual(result["bytes"], len(data))
            self.assertFalse(result["authenticationRetained"])
            self.assertEqual(list(output.iterdir()), [output / "source-01.jsonl"])
            self.assertEqual((output / "source-01.jsonl").read_bytes(), data)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "source-01.jsonl").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                RUNNER.retain_failed_sources(home, output)

    def test_symlink_fifo_and_file_budget_fail_without_auth_retention(self):
        for kind in ("symlink", "fifo", "oversized", "too-many"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                home = root / "home"
                sessions = home / "sessions"
                sessions.mkdir(parents=True)
                source = sessions / "rollout.jsonl"
                if kind == "symlink":
                    (home / "auth.json").write_text("fake-only-auth")
                    source.symlink_to(home / "auth.json")
                elif kind == "fifo":
                    os.mkfifo(source)
                else:
                    source.write_bytes(b"12345")
                with self.assertRaises((ValueError, OSError)):
                    RUNNER.retain_failed_sources(home, root / "retained",
                        maximum_bytes=4 if kind == "oversized" else 128,
                        maximum_files=0 if kind == "too-many" else 16)

    def test_failed_context_retains_sources_then_removes_auth(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = {"passed": False}
            destination = pathlib.Path(temporary) / "report.json"
            with RUNNER.disposable_source(report, destination) as private:
                home = pathlib.Path(private) / "home"
                (home / "sessions").mkdir(parents=True)
                (home / "auth.json").write_text("fake-auth")
                (home / "sessions" / "source.jsonl").write_text("fake-original")
            self.assertFalse(pathlib.Path(private).exists())
            self.assertEqual(report["failedSourceRetention"]["fileCount"], 1)
            self.assertEqual(list(destination.with_suffix(".failed-native-sources").iterdir())[0].read_text(), "fake-original")

    @unittest.skipIf(os.geteuid() == 0, "Root can read a mode000 directory")
    def test_unreadable_nested_directory_cannot_be_silently_skipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            home = root / "home"
            unreadable = home / "sessions" / "unreadable"
            unreadable.mkdir(parents=True)
            (unreadable / "source.jsonl").write_text("fake-original")
            unreadable.chmod(0)
            try:
                with self.assertRaisesRegex(ValueError, "owned-rollout-directory-unreadable"):
                    RUNNER.retain_failed_sources(home, root / "retained")
            finally:
                unreadable.chmod(0o700)

    @unittest.skipIf(os.geteuid() == 0, "Root can read a mode000 directory")
    def test_incomplete_retention_is_reported_and_temporary_authentication_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = {"passed": False}
            with RUNNER.disposable_source(report, pathlib.Path(temporary) / "report.json") as private:
                home = pathlib.Path(private) / "home"
                unreadable = home / "sessions" / "unreadable"
                unreadable.mkdir(parents=True)
                (home / "auth.json").write_text("fake-auth")
                (unreadable / "source.jsonl").write_text("fake-original")
                unreadable.chmod(0)
            self.assertFalse(pathlib.Path(private).exists())
            self.assertEqual(report["failedSourceRetention"]["status"], "retention-incomplete")
            self.assertFalse(report["failedSourceRetention"]["authenticationRetained"])


class EntrypointExitTests(unittest.TestCase):
    def test_unmet_gate_returns_exit_one_from_real_script_entrypoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            output = root / "report.json"
            environment = dict(os.environ, HOME=str(root))
            result = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("run.py")),
                "--executable", str(root / "never-invoked-codex"), "--report", str(output),
                "--fixtures", str(root / "fixtures")], env=environment, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, b"")
            report = json.loads(output.read_text())
            self.assertEqual(report["status"], "authentication-unavailable")
            self.assertFalse(report["passed"])
            self.assertFalse(json.loads(result.stdout)["passed"])
            self.assertTrue(report["cleanup"]["temporaryAuthenticationRemoved"])
            self.assertFalse((root / "fixtures").exists())


class LatencyGateTests(unittest.TestCase):
    def report(self):
        final = complete()
        final.update(typedCommittedBeforeCatchUp=dict(final["typedCommitted"]),
            typedCommittedByRoleBeforeCatchUp={key: dict(value) for key, value in final["typedCommittedByRole"].items()},
            actualReaderVersion="fake-reader", observedProducerVersions=["fake-producer"],
            syntheticValuePresent=True, nativeLocationsUnique=True, gapReasons=[], queueCount=0,
            replayStable=True, finalCatchUpNewOccurrences=0, ciphertextMarkerInspectionPassed=True,
            sourceLatency={"live": {"canonicalReadStartToCommitObservation": {
                "count": 12, "p95": 10, "excludedNegativeOrNonfiniteCount": 0}},
                "historical": {"canonicalReadStartToCommitObservation": {"count": 0}},
                "firstCanonicalReadStartedAt": "2026-10-11T08:00:00Z", "unmeasuredSourceRevisionCount": 0})
        return {"pipeline": final, "actualProducerVersion": "fake-producer", "actualReaderVersion": "fake-reader",
            "producerFinishedAt": "2026-10-11T08:01:00+00:00", "producerExitCode": 0, "pipelineExitCode": 0,
            "observerReady": True, "cleanup": dict.fromkeys(("disposableRootRemoved",
                "temporaryAuthenticationRemoved", "ownedProcessGroupsStopped"), True)}

    def test_all_twelve_typed_live_markers_are_required(self):
        report = self.report()
        LATENCY.evaluate_measurement(report)
        self.assertTrue(report["passed"])
        self.assertTrue(report["nativeChildPromptCoverage"]["validated"])
        self.assertEqual(set(report["requiredTypedMarkers"]), RUNNER.REQUIRED_MARKERS)

    def test_missing_child_prompt_keeps_gate_unmet_despite_parent_aggregate(self):
        report = self.report()
        del report["pipeline"]["typedCommittedByRole"]["child"]["CHILD_PROMPT"]
        LATENCY.evaluate_measurement(report)
        self.assertFalse(report["passed"])
        self.assertFalse(report["nativeChildPromptCoverage"]["validated"])

    def test_child_seen_only_in_final_catchup_cannot_pass_live_latency(self):
        report = self.report()
        del report["pipeline"]["typedCommittedByRoleBeforeCatchUp"]["child"]["CHILD_PROMPT"]
        LATENCY.evaluate_measurement(report)
        self.assertFalse(report["passed"])
        self.assertFalse(report["latencyMeasurementPassed"])


if __name__ == "__main__":
    unittest.main()
