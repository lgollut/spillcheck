"""Constructed controlled-journal schema and filesystem boundary checks."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("mod_journal_test", Path(__file__).with_name("journal.py"))
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)

def row():
    return {"schemaVersion": 1, "sequence": 1, "event": "prompt.submit", "phase": "input",
        "selectedSessionMatches": True, "nativeIdentity": {field: {"present": False, "kind": "absent"}
            for field in journal.FIELDS}, "textField": "text", "text": {"present": True, "kind": "string",
                "length": 20, "truncated": False, "markers": ["LEAKRET_PHASE0_MODSIDE_PROMPT"], "comparison": "a" * 64},
        "index": None, "component": None, "surface": None, "reason": None, "isAborted": None}

class JournalBoundaries(unittest.TestCase):
    def test_raw_fields_ids_unselected_and_unknown_labels_are_refused(self):
        for key, value in (("rawText", "private"), ("selectedSessionMatches", False), ("event", "unknown")):
            value_row = row(); value_row[key] = value
            self.assertFalse(journal.valid(value_row))
        value = row(); value["nativeIdentity"]["turnId"]["comparison"] = "private-native-id"
        self.assertFalse(journal.valid(value))
        value = row(); value["text"]["markers"].append("private-content")
        self.assertFalse(journal.valid(value))

    def test_only_owned_regular_private_journal_and_row_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); directory.chmod(0o700)
            path = directory / "mod-summary.jsonl"
            journal.append(path, row())
            self.assertEqual(json.loads(path.read_text())["event"], "prompt.submit")
            path.chmod(0o644)
            with self.assertRaises(ValueError): journal.append(path, row())
            path.unlink(); path.symlink_to(directory / "other")
            with self.assertRaises(OSError): journal.append(path, row())
            path.unlink(); path.write_text("{}\n" * journal.MAX_ROWS); path.chmod(0o600)
            with self.assertRaises(ValueError): journal.append(path, row())
            path.unlink(); directory.chmod(0o755)
            with self.assertRaises(ValueError): journal.append(path, row())

if __name__ == "__main__":
    unittest.main()
