"""Constructed native equality observations remain separate from source authority."""
import copy
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import journal
import summarize
from test_journal import row

class ControlledSummary(unittest.TestCase):
    def test_native_turn_equality_is_counted_without_publishing_it_or_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); directory.chmod(0o700)
            path = directory / "mod-summary.jsonl"
            prompt = row()
            prompt["nativeIdentity"]["turnId"] = {"present": True, "kind": "string", "comparison": "b" * 64}
            final = copy.deepcopy(prompt); final["sequence"] = 2
            final["event"] = "turn.complete"; final["textField"] = "answer"
            final["text"]["markers"] = ["LEAKRET_PHASE0_MODSIDE_FINAL"]
            journal.append(path, prompt); journal.append(path, final)
            report = summarize.summarize(path)
            self.assertEqual(report["sidePromptAndFinalSharedTurnIDCount"], 1)
            self.assertEqual(report["sideAndMainSharedTurnIDCount"], 0)
            self.assertFalse(report["canonicalSideAuthorityEstablished"])
            self.assertFalse(report["phase0Passed"])
            self.assertNotIn("b" * 64, str(report))

    def test_unrelated_schema_or_non_private_file_cannot_be_summarized(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); directory.chmod(0o700)
            path = directory / "mod-summary.jsonl"
            path.write_text('{"rawText":"private-content"}\n'); path.chmod(0o600)
            with self.assertRaises(ValueError): summarize.summarize(path)
            path.chmod(0o644)
            with self.assertRaises(ValueError): summarize.summarize(path)

if __name__ == "__main__":
    unittest.main()
