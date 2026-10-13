"""Constructed scope/privacy boundaries; these tests establish no host acceptance."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock
import uuid

import claude_concurrent_evidence as evidence

SECRET = "fake-concurrent-evidence-value"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))
    path.chmod(0o600)


def marker_rows(session, workspace, version, *, child=False):
    rows = []
    for marker, kind in evidence.native.EXPECTED.items():
        if marker.startswith("CHILD_") != child:
            continue
        role = "user" if kind in ("userPrompt", "toolOutput", "toolError") else "assistant"
        text = "LEAKRET_M3_" + marker + " " + SECRET
        message = {"role": role, "content": [{"type": "text", "text": text}]}
        if role == "assistant":
            message["stop_reason"] = "end_turn" if kind == "finalResponse" else "tool_use"
        if kind in ("toolOutput", "toolError"):
            message["content"] = [{"type": "tool_result", "tool_use_id": marker,
                "is_error": kind == "toolError", "content": text}]
        rows.append({"type": role, "sessionId": session, "cwd": workspace, "version": version,
            "uuid": str(uuid.uuid5(uuid.UUID(session), marker)), "timestamp": "2026-10-12T12:00:00Z",
            "message": message})
    return rows


class ConcurrentEvidenceBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spillcheck-concurrent-evidence-", dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.lanes = []
        for index, host in enumerate(evidence.HOSTS):
            session = str(uuid.uuid5(uuid.NAMESPACE_DNS, "owned-test-" + host))
            workspace = self.root / host / "work"
            workspace.mkdir(parents=True)
            version = "2.1.295" if host == "desktop" else "2.1.296"
            source = self.root / "fake-profile/projects" / re.sub(r"[^A-Za-z0-9]", "-", str(workspace)) / (session + ".jsonl")
            identity = self.root / host / "runtime-private.json"
            write_json(identity, {"schemaVersion": 1, "nativeSessionID": session,
                "workingDirectory": str(workspace), "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID"})
            lane = {"host": host, "workspace": str(workspace), "producerVersion": version,
                "runtimeIdentityPath": str(identity), "runtimeIdentitySHA256": self.sha(identity),
                "nativeSessionID": session, "originalTranscriptPath": str(source),
                "sourceRegistrationByteCount": 1, "sourceRegistrationSHA256": "0" * 64}
            self.lanes.append(lane)
            self.write_rows(source, marker_rows(session, str(workspace), version))
            self.register(lane)
            self.write_rows(self.child(lane), marker_rows(session, str(workspace), version, child=True))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def child(lane):
        parent = Path(lane["originalTranscriptPath"])
        return parent.parent / parent.stem / "subagents/agent-owned.jsonl"

    @staticmethod
    def write_rows(path, rows):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"".join(json.dumps(r).encode() + b"\n" for r in rows))

    def register(self, lane):
        path = Path(lane["originalTranscriptPath"])
        lane["sourceRegistrationByteCount"] = path.stat().st_size
        lane["sourceRegistrationSHA256"] = self.sha(path)

    def inspect(self, **kwargs):
        return evidence.inspect_concurrent_sources(self.lanes, SECRET, **kwargs)

    def reject(self, reason=None, **kwargs):
        paths, report, snapshot = self.inspect(**kwargs)
        self.assertFalse(report["passed"])
        if not report["admittedUniverseValid"]:
            self.assertEqual(paths, [])
            self.assertEqual(snapshot, {})
        if reason:
            self.assertIn(reason, report["nativeEvidenceLimitReasons"])
        self.assertNotIn(SECRET, json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))
        return report

    def test_exact_three_pairs_and_private_snapshot_without_host_claim(self):
        paths, report, snapshot = self.inspect()
        self.assertTrue(report["passed"])
        self.assertTrue(report["admittedUniverseValid"])
        self.assertTrue(report["allThreePairsComplete"])
        self.assertEqual(report["completeNativeParentChildPairCountByProducer"], {"2.1.295": 1, "2.1.296": 2})
        self.assertEqual(len(paths), 6)
        self.assertEqual(len(snapshot), 6)
        self.assertEqual(report["nativeCanonicalSessionCount"], 3)
        for (path, _), (size, digest) in snapshot.items():
            self.assertEqual(Path(path).stat().st_size, size)
            self.assertEqual(self.sha(Path(path)), digest)
        self.assertFalse(report["hostOriginIndependentlyVerified"])
        self.assertTrue(report["hostEvidenceRequiredSeparately"])
        self.assertFalse(report["siblingParentDirectoriesEnumerated"])
        for lane in self.lanes:
            host = report["hosts"][lane["host"]]
            self.assertEqual(len(host["typedMarkers"]), 12)
            self.assertEqual(host["contentTypesByRole"], {"parent": evidence.TYPES, "child": evidence.TYPES})
            self.assertNotIn(lane["nativeSessionID"], json.dumps(report))
        self.assertNotIn(SECRET, json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_shared_producer_counts_require_all_three_individual_pairs(self):
        for lane in self.lanes:
            lane["producerVersion"] = "2.1.296"
            for path in (Path(lane["originalTranscriptPath"]), self.child(lane)):
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                for row in rows:
                    row["version"] = lane["producerVersion"]
                self.write_rows(path, rows)
            self.register(lane)
        self.assertEqual(self.inspect()[1]["completeNativeParentChildPairCountByProducer"], {"2.1.296": 3})

    def test_does_not_enumerate_or_read_unrelated_parent_siblings(self):
        for lane in self.lanes:
            sibling = Path(lane["originalTranscriptPath"]).with_name(str(uuid.uuid4()) + ".jsonl")
            sibling.write_text("PRIVATE UNRELATED NOT JSON")
        scandir = os.scandir
        def bounded_scandir(fd):
            self.assertIsInstance(fd, int)
            identity = (os.fstat(fd).st_dev, os.fstat(fd).st_ino)
            allowed = {(self.child(lane).parent.stat().st_dev, self.child(lane).parent.stat().st_ino) for lane in self.lanes}
            self.assertIn(identity, allowed)
            return scandir(fd)
        with mock.patch.object(evidence.os, "scandir", side_effect=bounded_scandir):
            self.assertTrue(self.inspect()[1]["passed"])

    def test_extra_or_missing_admitted_parent_rejected_before_source_reads(self):
        original = copy.deepcopy(self.lanes)
        for lanes in (original[:2], original + [copy.deepcopy(original[0])]):
            self.lanes = lanes
            with mock.patch.object(evidence._Reader, "read", side_effect=AssertionError("no read permitted")):
                self.reject("exactlyThreeAdmittedHostsRequired")

    def test_duplicate_host_or_session_and_wrong_path_are_rejected(self):
        original = copy.deepcopy(self.lanes)
        cases = [("host", original[0]["host"], "exactlyThreeAdmittedHostsRequired"),
            ("nativeSessionID", original[0]["nativeSessionID"], "admittedParentIdentityAmbiguous"),
            ("originalTranscriptPath", str(self.root / "outside.jsonl"), "runtimeDerivedParentPathRequired")]
        for key, value, reason in cases:
            with self.subTest(key=key):
                self.lanes = copy.deepcopy(original); self.lanes[1][key] = value
                self.reject(reason)

    def test_runtime_identity_digest_or_workspace_mismatch_fails(self):
        lane = self.lanes[0]
        lane["runtimeIdentitySHA256"] = "0" * 64
        self.reject("runtimeIdentityDigestMismatch")
        identity = Path(lane["runtimeIdentityPath"])
        value = json.loads(identity.read_text()); value["workingDirectory"] = str(self.root)
        write_json(identity, value); lane["runtimeIdentitySHA256"] = self.sha(identity)
        self.reject("runtimeIdentityBindingMismatch")

    def test_registered_prefix_is_immutable_while_append_is_allowed(self):
        parent = Path(self.lanes[0]["originalTranscriptPath"])
        with parent.open("ab") as stream:
            stream.write(b'{"type":"progress"}\n')
        self.assertTrue(self.inspect()[1]["passed"])
        parent.write_bytes(parent.read_bytes().replace(b'LEAKRET', b'CHANGED', 1))
        self.reject("registeredNativeSourcePrefixChanged")

    def test_missing_child_or_marker_is_incomplete_not_malformed(self):
        self.child(self.lanes[0]).unlink()
        report = self.reject("threeCompleteNativePairsRequired")
        self.assertTrue(report["admittedUniverseValid"])
        self.assertEqual(report["hosts"]["cli"]["ownNativeChildCount"], 0)
        partial = self.inspect(require_complete=False)[1]
        self.assertTrue(partial["passed"])
        self.assertFalse(partial["allThreePairsComplete"])

    def test_split_missing_markers_cannot_pool_across_children_or_hosts(self):
        child = self.child(self.lanes[0]); rows = [json.loads(line) for line in child.read_text().splitlines()]
        self.write_rows(child, rows[:2])
        report = self.reject("threeCompleteNativePairsRequired")
        self.assertFalse(report["hosts"]["cli"]["individualNativeRoleCoverageComplete"])
        self.write_rows(child.with_name("agent-extra.jsonl"), rows[2:])
        self.reject("exactlyOneOwnChildRequired")

    def test_extra_complete_child_rejected_even_when_three_pairs_can_be_counted(self):
        child = self.child(self.lanes[0])
        child.with_name("agent-extra.jsonl").write_bytes(child.read_bytes())
        self.reject("exactlyOneOwnChildRequired")

    def test_parent_and_child_all_content_rows_bind_workspace_version_session(self):
        lane = self.lanes[0]
        for path in (Path(lane["originalTranscriptPath"]), self.child(lane)):
            original = path.read_bytes()
            for key, value in (("cwd", str(self.root)), ("version", "2.1.999"),
                    ("sessionId", self.lanes[1]["nativeSessionID"])):
                with self.subTest(role=path.name, key=key):
                    rows = [json.loads(line) for line in original.splitlines()]
                    rows[-1][key] = value; self.write_rows(path, rows)
                    if path.name.endswith(lane["nativeSessionID"] + ".jsonl"):
                        self.register(lane)
                    self.reject("nativeIdentityWorkspaceOrProducerMismatch", require_complete=False)
            path.write_bytes(original)
            self.register(lane)

    def test_unique_child_session_allowed_but_shared_child_identity_is_not(self):
        unique = str(uuid.uuid4())
        for lane in self.lanes[:2]:
            child = self.child(lane); rows = [json.loads(line) for line in child.read_text().splitlines()]
            for row in rows:
                row["sessionId"] = unique
            self.write_rows(child, rows)
            if lane is self.lanes[0]:
                report = self.inspect()[1]
                self.assertTrue(report["passed"])
                self.assertEqual(report["nativeCanonicalSessionCount"], 4)
        self.reject("childNativeSessionAppearedUnderDistinctParents")

    def test_cross_source_row_identity_collision_is_rejected(self):
        lane = self.lanes[0]; parent = Path(lane["originalTranscriptPath"])
        item = json.loads(parent.read_text().splitlines()[0])["uuid"]
        child = self.child(lane); rows = [json.loads(line) for line in child.read_text().splitlines()]
        rows[0]["uuid"] = item; self.write_rows(child, rows)
        self.reject("nativeIdentityAppearedInDistinctSourceFiles")

    def test_child_symlink_and_fifo_are_rejected_without_following_or_waiting(self):
        child = self.child(self.lanes[0]); child.unlink()
        child.symlink_to(Path(self.lanes[1]["originalTranscriptPath"]))
        self.reject("unexpectedOwnChildEntry")
        child.unlink(); os.mkfifo(child)
        self.reject("unexpectedOwnChildEntry")

    def test_parent_fifo_and_hardlink_rejected_without_reading(self):
        path = Path(self.lanes[0]["originalTranscriptPath"]); path.unlink(); os.mkfifo(path)
        self.reject("sourceOwnershipTypeOrLinkRejected")
        path.unlink(); os.link(Path(self.lanes[1]["originalTranscriptPath"]), path)
        self.reject("sourceOwnershipTypeOrLinkRejected")

    def test_intermediate_directory_symlink_and_parent_alias_rejected(self):
        path = Path(self.lanes[0]["originalTranscriptPath"])
        old = path.parent.with_name(path.parent.name + "-moved")
        path.parent.rename(old); path.parent.symlink_to(old)
        self.reject("sourceOwnershipTypeOrAccessFailure")

    def test_partial_jsonl_and_duplicate_fields_fail_in_partial_mode(self):
        child = self.child(self.lanes[0]); raw = child.read_bytes()
        child.write_bytes(raw[:-1])
        self.reject("completeJSONLFramingRequired", require_complete=False)
        child.write_bytes(raw + b'{"type":"progress","type":"system"}\n')
        self.reject("duplicateJSONField", require_complete=False)

    def test_byte_and_own_child_directory_budgets_fail_closed(self):
        with mock.patch.object(evidence, "MAXIMUM_FILE_BYTES", 64):
            self.reject("sourceByteBudgetExceeded")
        with mock.patch.object(evidence, "MAXIMUM_TOTAL_BYTES", 64):
            self.reject("sourceByteBudgetExceeded")
        child = self.child(self.lanes[0])
        for index in range(3):
            child.with_name(f"metadata-{index}.json").write_text("{}")
        with mock.patch.object(evidence, "MAXIMUM_DIRECTORY_ENTRIES", 2):
            self.reject("childMetadataBudgetExceeded")

    def test_child_added_during_inspection_fails_final_universe_check(self):
        content = evidence._content
        added = False
        def add_child(*args, **kwargs):
            nonlocal added
            result = content(*args, **kwargs)
            if not added:
                added = True
                child = self.child(self.lanes[0])
                child.with_name("agent-late.jsonl").write_bytes(child.read_bytes())
            return result
        with mock.patch.object(evidence, "_content", side_effect=add_child):
            self.reject("exactlyOneOwnChildRequired")

    def test_file_changes_after_read_fail_final_snapshot_check(self):
        content = evidence._content
        changed = False
        def append_after_read(*args, **kwargs):
            nonlocal changed
            result = content(*args, **kwargs)
            if not changed:
                changed = True
                with Path(self.lanes[0]["originalTranscriptPath"]).open("ab") as stream:
                    stream.write(b'{"type":"progress"}\n')
            return result
        with mock.patch.object(evidence, "_content", side_effect=append_after_read):
            self.reject("sourceChangedDuringInspection")


if __name__ == "__main__":
    unittest.main()
