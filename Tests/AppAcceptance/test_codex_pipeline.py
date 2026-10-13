"""Codex signed-report gate boundaries. No app, provider, or Keychain is launched."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("signed_codex", Path(__file__).with_name("run-app-codex-pipeline.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
PARENT = "11111111-1111-4111-8111-111111111111"
CHILD = "22222222-2222-4222-8222-222222222222"


def report():
    return {
        "codexIndividualRoleCoverageMeasured": True,
        "codexIndividualRoleCoveragePassed": True,
        "codexNativeParentChildLinkVerified": True,
        "codexRoleEvidenceWithinBudget": True,
        "codexTypedCommittedMarkersByRole": {
            "parent": {key: 1 for key in RUNNER.PARENT_MARKERS},
            "child": {key: 1 for key in RUNNER.CHILD_MARKERS}},
        "codexCommittedContentTypesByRole": {
            role: sorted(RUNNER.CONTENT_TYPES) for role in ("parent", "child")}}


class CodexRoleGateTests(unittest.TestCase):
    def test_complete_individual_roles_pass(self):
        self.assertTrue(RUNNER.role_coverage_passed(report()))

    def test_aggregate_five_types_do_not_prove_child(self):
        aggregate = {"syntheticOccurrencesByContentType": {kind: 1 for kind in RUNNER.CONTENT_TYPES},
                     "syntheticSessionCount": 2}
        self.assertFalse(RUNNER.role_coverage_passed(aggregate))

    def test_missing_or_duplicated_child_marker_fails(self):
        for marker in RUNNER.CHILD_MARKERS:
            for count in (None, 0, 2, True, "1"):
                with self.subTest(marker=marker, count=count):
                    value = report()
                    if count is None:
                        del value["codexTypedCommittedMarkersByRole"]["child"][marker]
                    else:
                        value["codexTypedCommittedMarkersByRole"]["child"][marker] = count
                    self.assertFalse(RUNNER.role_coverage_passed(value))

    def test_parent_mirror_is_not_a_child(self):
        value = report()
        value["codexTypedCommittedMarkersByRole"]["parent"].update(value["codexTypedCommittedMarkersByRole"].pop("child"))
        self.assertFalse(RUNNER.role_coverage_passed(value))

    def test_native_link_and_bounded_measurement_are_required(self):
        for key in ("codexIndividualRoleCoverageMeasured", "codexIndividualRoleCoveragePassed",
                    "codexNativeParentChildLinkVerified", "codexRoleEvidenceWithinBudget"):
            value = report()
            value[key] = False
            self.assertFalse(RUNNER.role_coverage_passed(value))

    def test_all_seven_parent_markers_are_required(self):
        for marker in RUNNER.PARENT_MARKERS:
            value = report()
            del value["codexTypedCommittedMarkersByRole"]["parent"][marker]
            self.assertFalse(RUNNER.role_coverage_passed(value))

    def test_each_role_requires_all_five_types(self):
        for role in ("parent", "child"):
            value = report()
            value["codexCommittedContentTypesByRole"][role].remove("toolError")
            self.assertFalse(RUNNER.role_coverage_passed(value))

    def test_invalid_role_selection_is_rejected_before_running_app(self):
        valid = dict(expected_parent=PARENT, expected_child=CHILD, thread=[PARENT, CHILD])
        self.assertTrue(RUNNER.strict_roles(argparse.Namespace(**valid), argparse.ArgumentParser()))
        cases = [dict(expected_child=None), dict(expected_parent=CHILD), dict(thread=[PARENT]),
                 dict(thread=[PARENT, CHILD, "unrelated"]), dict(thread=[PARENT, PARENT]),
                 dict(expected_parent="bad"), dict(expected_child="../../private")]
        for change in cases:
            with self.subTest(change=change), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    RUNNER.strict_roles(argparse.Namespace(**(valid | change)), argparse.ArgumentParser())

    def test_legacy_selection_is_explicitly_not_individual_measurement(self):
        args = argparse.Namespace(expected_parent=None, expected_child=None, thread=[PARENT])
        self.assertFalse(RUNNER.strict_roles(args, argparse.ArgumentParser()))
        self.assertFalse(RUNNER.role_coverage_passed({}))


class CodexSignedRunnerTests(unittest.TestCase):
    def drive(self, *, strict=True, missing_child=False, verified_link=True,
              interface="standalone-cli"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "public.json"
            command = []
            result = report() | {"storageReady": True, "collectionConfigured": True, "queueCount": 0,
                "syntheticValuePresent": True, "syntheticSessionCount": 2, "gapReasons": [],
                "coverageReportTruncated": False, "newVaultCleanupPassed": True,
                "observedAgentVersions": ["0.162.1"],
                "syntheticOccurrencesByContentType": {kind: 1 for kind in RUNNER.CONTENT_TYPES}}
            if missing_child:
                result["codexTypedCommittedMarkersByRole"]["child"].pop("CHILD_PROMPT")
            result["codexNativeParentChildLinkVerified"] = verified_link

            class Artifacts(RUNNER.AcceptanceArtifacts):
                def __init__(self, prefix, output_path):
                    self.directory = root / "owned"
                    self.directory.mkdir()
                    self.output_path = output_path
                    self.report = {"passed": False}
                    self.passed = False

            class Process:
                returncode = 0
                def __init__(self, arguments, **kwargs):
                    command.extend(arguments)
                    Path(arguments[arguments.index("--store-directory") + 1]).mkdir()
                    Path(arguments[arguments.index("--acceptance-report") + 1]).write_text(json.dumps(result))
                def communicate(self, timeout):
                    return b"", b""

            fake_fixture = SimpleNamespace(observe_version=lambda *a, **k: "0.162.1")
            fake_spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
            args = ["--thread", PARENT, "--thread", CHILD, "--interface", interface, "--output", str(output)]
            if strict:
                args += ["--expected-parent", PARENT, "--expected-child", CHILD]
            with mock.patch.object(RUNNER, "AcceptanceArtifacts", Artifacts), \
                 mock.patch.object(RUNNER.subprocess, "run"), mock.patch.object(RUNNER.subprocess, "Popen", Process), \
                 mock.patch.object(RUNNER.importlib.util, "spec_from_file_location", return_value=fake_spec), \
                 mock.patch.object(RUNNER.importlib.util, "module_from_spec", return_value=fake_fixture), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                exit_code = RUNNER.main(args)
            public = json.loads(output.read_text())
            self.assertNotIn(PARENT, output.read_text())
            self.assertNotIn(CHILD, output.read_text())
            self.assertNotIn(str(root), output.read_text())
            return exit_code, public, command

    def test_strict_success_passes_explicit_roles_and_reports_child(self):
        code, result, command = self.drive()
        self.assertEqual(code, 0)
        self.assertTrue(result["nativeChildAllFiveTypesEstablished"])
        self.assertTrue(result["strictNativeChildAcceptanceRequired"])
        self.assertEqual(command[command.index("--acceptance-codex-parent") + 1], PARENT)
        self.assertEqual(command[command.index("--acceptance-codex-child") + 1], CHILD)

    def test_aggregate_success_with_missing_child_prompt_still_fails(self):
        code, result, _ = self.drive(missing_child=True)
        self.assertEqual(code, 1)
        self.assertFalse(result["nativeChildAllFiveTypesEstablished"])
        self.assertTrue(result["cleanupPending"])

    def test_unverified_link_cannot_pass(self):
        code, result, _ = self.drive(verified_link=False)
        self.assertEqual(code, 1)
        self.assertFalse(result["nativeChildAllFiveTypesEstablished"])

    def test_legacy_aggregate_success_does_not_claim_individual_coverage(self):
        code, result, command = self.drive(strict=False)
        self.assertEqual(code, 0)
        self.assertFalse(result["nativeChildAllFiveTypesEstablished"])
        self.assertFalse(result["individualRoleCoveragePassed"])
        self.assertNotIn("--acceptance-codex-parent", command)

    def test_desktop_route_requires_explicit_opt_in_without_t3_host_attribution(self):
        code, result, command = self.drive(strict=False, interface="desktop-code")
        self.assertEqual(code, 0)
        self.assertEqual(result["interface"], "desktop-code")
        self.assertIsNone(result["hostVersion"])
        self.assertEqual(command[command.index("--codex-authorized-host") + 1], "desktop-code")
        self.assertNotIn("--codex-t3-version", command)
        self.assertFalse(result["nativeChildAllFiveTypesEstablished"])

    def test_non_t3_route_rejects_t3_host_version_before_app_launch(self):
        for interface in ("standalone-cli", "desktop-code"):
            with self.subTest(interface=interface), mock.patch.object(RUNNER.subprocess, "run") as run, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    RUNNER.main(["--thread", PARENT, "--interface", interface,
                        "--host-version", "26.930.61225", "--output", "/unused.json"])
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
