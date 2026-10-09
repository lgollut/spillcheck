"""Evidence boundary tests; constructed records are not provider acceptance."""
import json
from pathlib import Path
import tempfile
import unittest

from claude_native_evidence import MAXIMUM_FILE_BYTES, inspect_selected_native_source

SECRET = "synthetic-evidence-value"

def row(role, text, uuid, **fields):
    value = {"type": role, "sessionId": "native-parent", "uuid": uuid,
        "timestamp": "2026-10-09T12:00:00Z", "version": "2.1.295",
        "message": {"role": role, "content": [{"type": "text", "text": text}]}}
    if role == "assistant":
        value["message"]["stop_reason"] = "end_turn"
    value.update(fields)
    return value

def write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(value) + "\n" for value in rows))

class NativeEvidenceBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spillcheck-native-evidence-", dir="/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.parent = self.root / "native-parent.jsonl"

    def tearDown(self):
        self.temporary.cleanup()

    def inspect(self):
        return inspect_selected_native_source(self.parent, SECRET, "native-parent")

    def test_only_exact_parent_and_own_child_and_reused_native_session(self):
        write(self.parent, [row("user", "LEAKRET_M3_PROMPT " + SECRET, "main-row")])
        child = self.root / "native-parent/subagents/agent-owned.jsonl"
        write(child, [row("user", "LEAKRET_M3_CHILD_PROMPT " + SECRET, "child-prompt"),
            row("assistant", "LEAKRET_M3_CHILD_FINAL " + SECRET, "child-final")])
        write(self.root / "unrelated.jsonl", [row("assistant", "LEAKRET_M3_FINAL " + SECRET, "unrelated")])
        paths, evidence = self.inspect()
        self.assertEqual([path for path, _ in paths], [self.parent, child])
        self.assertEqual(evidence["nativeSessionCount"], 1)
        self.assertEqual(evidence["childTypedMarkers"], ["CHILD_FINAL", "CHILD_PROMPT"])
        self.assertNotIn("FINAL", evidence["typedMarkers"])
        self.assertNotIn("native-parent", json.dumps(evidence))
        self.assertNotIn(SECRET, json.dumps(evidence))

    def test_child_symlink_is_rejected_without_reading_unrelated_source(self):
        write(self.parent, [row("user", "LEAKRET_M3_PROMPT " + SECRET, "main-row")])
        other = self.root / "unrelated.jsonl"
        write(other, [row("assistant", "LEAKRET_M3_CHILD_FINAL " + SECRET, "unrelated")])
        child = self.root / "native-parent/subagents/agent-link.jsonl"
        child.parent.mkdir(parents=True)
        child.symlink_to(other)
        paths, evidence = self.inspect()
        self.assertFalse(evidence["requiredNativeFieldsValid"])
        self.assertEqual(evidence["bytesRead"], 0)
        self.assertEqual(paths, [])

    def test_changed_required_role_and_selected_native_identity_fail(self):
        value = row("user", "LEAKRET_M3_PROMPT " + SECRET, "main-row", sessionId="unrelated-native")
        value["message"]["role"] = "assistant"
        write(self.parent, [value])
        _, evidence = self.inspect()
        self.assertFalse(evidence["requiredNativeFieldsValid"])
        self.assertEqual(evidence["typedMarkers"], [])

    def test_source_size_and_child_count_limits_remain_explicit(self):
        self.parent.write_bytes(b"x" * (MAXIMUM_FILE_BYTES + 1))
        _, evidence = self.inspect()
        self.assertIn("sourceByteBudgetExceeded", evidence["nativeEvidenceLimitReasons"])
        self.assertEqual(evidence["bytesRead"], 0)
        write(self.parent, [row("user", "LEAKRET_M3_PROMPT " + SECRET, "main-row")])
        for index in range(33):
            write(self.root / f"native-parent/subagents/agent-{index}.jsonl", [])
        _, evidence = self.inspect()
        self.assertIn("childFileCountBudgetExceeded", evidence["nativeEvidenceLimitReasons"])

    def test_incomplete_final_record_is_not_used_for_positive_evidence(self):
        write(self.parent, [row("user", "LEAKRET_M3_PROMPT " + SECRET, "main-row")])
        with self.parent.open("ab") as stream:
            stream.write(json.dumps(row("assistant", "LEAKRET_M3_FINAL " + SECRET, "partial-final")).encode())
        _, evidence = self.inspect()
        self.assertFalse(evidence["completeJSONLFraming"])
        self.assertNotIn("FINAL", evidence["typedMarkers"])

if __name__ == "__main__":
    unittest.main()
