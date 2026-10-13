"""Signed source selection tests with fake records; no providers or Keychain access."""
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("codex_live_runner", pathlib.Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
PARENT = "00000000-0000-7000-8000-000000000001"
CHILD = "00000000-0000-7000-8000-000000000002"
OTHER = "00000000-0000-7000-8000-000000000003"
VERSION = "0.162.1"


def evidence():
    report = {"schemaVersion": 2, "interface": "standalone-cli", "readerVersion": VERSION,
              "passive": True, "networkDenied": True, "forkDenied": True, "startCalls": 0, "resumeCalls": 0,
              "threads": [{"threadID": PARENT, "metadataMatches": True, "cliVersion": VERSION,
                           "status": "read-complete", "mappedGapReasons": [], "nativeItemIDs": ["start", "stop"]}]}
    fixture = {"thread": {"id": PARENT, "cliVersion": VERSION}, "items": [
        {"item": {"id": "start", "type": "subAgentActivity", "agentThreadId": CHILD}},
        {"item": {"id": "stop", "type": "subAgentActivity", "agentThreadId": CHILD}}]}
    return report, fixture


class SignedSourceSelectionTests(unittest.TestCase):
    def select(self, report, fixture):
        return RUNNER.signed_source_threads(report, fixture, parent=PARENT,
                                             producer_version=VERSION, reader_version=VERSION)

    def rejected(self, report, fixture):
        with self.assertRaises(ValueError) as caught:
            self.select(report, fixture)
        for identity in (PARENT, CHILD, OTHER):
            self.assertNotIn(identity, str(caught.exception))

    def test_repeated_original_activity_links_select_exact_parent_and_one_child(self):
        self.assertEqual(self.select(*evidence()), [PARENT, CHILD])

    def test_recognized_collaboration_receiver_links_are_accepted(self):
        report, fixture = evidence()
        fixture["items"][0]["item"] = {"id": "start", "type": "collabAgentToolCall", "receiverThreadIds": [CHILD]}
        self.assertEqual(self.select(report, fixture), [PARENT, CHILD])

    def test_public_route_and_version_evidence_must_match(self):
        for key, value in (("schemaVersion", 1), ("interface", "t3"), ("readerVersion", "different"),
                           ("passive", False), ("networkDenied", False), ("forkDenied", False),
                           ("startCalls", 1), ("resumeCalls", 1), ("startCalls", False)):
            with self.subTest(key=key, value=value):
                report, fixture = evidence()
                report[key] = value
                self.rejected(report, fixture)

    def test_missing_public_evidence_fails(self):
        for key in evidence()[0]:
            with self.subTest(key=key):
                report, fixture = evidence()
                del report[key]
                self.rejected(report, fixture)

    def test_complete_exact_parent_metadata_is_required(self):
        for key, value in (("threadID", OTHER), ("metadataMatches", False), ("metadataMatches", 1),
                           ("cliVersion", "different"), ("status", "bounded-partial"),
                           ("mappedGapReasons", ["malformedSource"]), ("mappedGapReasons", None)):
            with self.subTest(key=key, value=value):
                report, fixture = evidence()
                report["threads"][0][key] = value
                self.rejected(report, fixture)

    def test_missing_or_extra_public_threads_fail(self):
        for threads in ([], [None], evidence()[0]["threads"] * 2, None):
            report, fixture = evidence()
            report["threads"] = threads
            self.rejected(report, fixture)

    def test_parent_fixture_metadata_must_match(self):
        for metadata in ({"id": OTHER, "cliVersion": VERSION}, {"id": PARENT, "cliVersion": "different"}, None):
            report, fixture = evidence()
            fixture["thread"] = metadata
            self.rejected(report, fixture)

    def test_fixture_items_must_match_recorded_public_native_item_ids(self):
        for ids in ([], ["start"], ["stop", "start"], ["start", "other"]):
            report, fixture = evidence()
            report["threads"][0]["nativeItemIDs"] = ids
            self.rejected(report, fixture)

    def test_duplicate_native_item_ids_fail_even_if_report_matches(self):
        report, fixture = evidence()
        fixture["items"][1]["item"]["id"] = "start"
        report["threads"][0]["nativeItemIDs"] = ["start", "start"]
        self.rejected(report, fixture)

    def test_missing_self_or_multiple_child_links_fail(self):
        for value in (None, PARENT, OTHER):
            report, fixture = evidence()
            fixture["items"][0]["item"]["agentThreadId"] = value
            if value is None:
                fixture["items"][1]["item"]["agentThreadId"] = None
            self.rejected(report, fixture)

    def test_malformed_or_noncanonical_child_identity_fails(self):
        for value in ("../private", "", "not-a-uuid", 1, {}, CHILD.replace("7000", "ABCD")):
            report, fixture = evidence()
            fixture["items"][0]["item"]["agentThreadId"] = value
            self.rejected(report, fixture)

    def test_unrecognized_item_cannot_authorize_a_child(self):
        report, fixture = evidence()
        fixture["items"][0]["item"]["type"] = "userMessage"
        self.rejected(report, fixture)

    def test_malformed_or_oversized_receiver_list_fails(self):
        for value in (CHILD, {}, [CHILD, 1], [CHILD] * 5, [PARENT], [OTHER]):
            report, fixture = evidence()
            fixture["items"][0]["item"]["receiverThreadIds"] = value
            self.rejected(report, fixture)

    def test_malformed_or_oversized_item_list_fails(self):
        for items in (None, [], [{}], [None], [{"item": []}], evidence()[1]["items"] * 513):
            report, fixture = evidence()
            fixture["items"] = items
            self.rejected(report, fixture)

    def test_bounded_json_rejects_symlink_and_oversized_or_nonobject_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "owned.json"
            source.write_text('{"count": 1}')
            self.assertEqual(RUNNER.bounded_json(source, maximum_bytes=64), {"count": 1})
            link = root / "link.json"
            link.symlink_to(source)
            with self.assertRaises(OSError):
                RUNNER.bounded_json(link, maximum_bytes=64)
            with self.assertRaises(ValueError):
                RUNNER.bounded_json(source, maximum_bytes=4)
            source.write_text("[]")
            with self.assertRaises(ValueError):
                RUNNER.bounded_json(source, maximum_bytes=64)


class RunnerOrderTests(unittest.TestCase):
    def run_to_signed_launch(self, *, partial=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            auth = root / ".codex" / "auth.json"
            auth.parent.mkdir()
            auth.write_text("fake authentication fixture")
            public, fixture = evidence()
            if partial:
                public["threads"][0]["status"] = "bounded-partial"
            calls = []

            def bounded(command, **kwargs):
                cleanup = kwargs.get("cleanup_report")
                if cleanup is not None:
                    cleanup.update(leaderExited=True, ownedGroupTerminationRequested=True, groupKillPermissionDenied=False)
                if "--version" in command:
                    return 0, ("codex-cli " + VERSION).encode(), 1
                if "exec" in command:
                    calls.append("producer")
                    return 0, json.dumps({"type": "thread.started", "thread_id": PARENT}).encode(), 1
                if "CodexPublicLiveTests" in command:
                    calls.append("public-read")
                    env = kwargs["environment"]
                    pathlib.Path(env["SPILLCHECK_CODEX_PROBE_REPORT"]).write_text(json.dumps(public))
                    (pathlib.Path(env["SPILLCHECK_CODEX_PROBE_FIXTURE_DIRECTORY"]) / (PARENT + ".json")).write_text(json.dumps(fixture))
                    return 0, b"", 1
                if any(str(value).endswith("run-app-codex-pipeline.py") for value in command):
                    calls.append([command[index + 1] for index, value in enumerate(command) if value == "--thread"])
                    raise ValueError("stop-at-mocked-signed-launch")
                self.fail("unexpected subprocess")

            argv = ["run.py", "--executable", "/fake/codex", "--signed-app", str(root / "fake.app"),
                    "--report", str(root / "report.json"), "--fixtures", str(root / "fixtures")]
            with mock.patch.object(RUNNER.sys, "argv", argv), mock.patch.object(RUNNER, "bounded", side_effect=bounded), \
                 mock.patch.object(pathlib.Path, "home", return_value=root), contextlib.redirect_stdout(io.StringIO()):
                RUNNER.main()
            return calls, json.loads((root / "report.json").read_text())

    def test_public_evidence_precedes_signed_launch_with_both_exact_threads(self):
        calls, report = self.run_to_signed_launch()
        self.assertEqual(calls, ["producer", "public-read", [PARENT, CHILD]])
        self.assertEqual(report["signedSourceSelection"], {"parentCount": 1, "nativeLinkedChildCount": 1,
                         "completeParentPublicRead": True, "originalNativeChildLinkVerified": True})
        self.assertFalse(report["passed"])
        self.assertTrue(report["cleanup"]["temporaryAuthenticationRemoved"])

    def test_partial_public_read_cannot_launch_signed_app(self):
        calls, report = self.run_to_signed_launch(partial=True)
        self.assertEqual(calls, ["producer", "public-read"])
        self.assertNotIn("signedSourceSelection", report)
        self.assertFalse(report["passed"])


if __name__ == "__main__":
    unittest.main()
