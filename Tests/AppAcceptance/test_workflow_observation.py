import sys
import os
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Support.workflow_observation import WorkflowObservations, read_workflow_report


def sample(**changes):
    return dict(processID=42, viewingAuthorized=False, windowVisible=True,
                revealedValueCount=0, revealedExcerptCount=0, revealedSourceMetadataCount=0,
                workflowEvents={}, **changes)


class WorkflowObservationTests(unittest.TestCase):
    def test_drops_other_process_and_incomplete_reports(self):
        observer = WorkflowObservations(42)
        other = sample(); other["processID"] = 43
        observer.observe(other); observer.observe({"processID": 42})
        self.assertEqual(observer.report()["samples"], [])

    def test_records_revealed_before_masked_and_deduplicates(self):
        observer = WorkflowObservations(42)
        revealed = sample(); revealed.update(viewingAuthorized=True, revealedValueCount=1)
        observer.observe(revealed); observer.observe(revealed)
        masked = sample(); masked["workflowEvents"] = {"mask-sessionLock": 1}
        observer.observe(masked)
        states = observer.report()["samples"]
        self.assertEqual(len(states), 2)
        self.assertTrue(states[0]["viewingAuthorized"])
        self.assertFalse(states[1]["viewingAuthorized"])
        self.assertEqual(states[1]["workflowEvents"]["mask-sessionLock"], 1)

    def test_never_exports_unknown_fields_or_events(self):
        observer = WorkflowObservations(42)
        report = sample(); report.update(secret="PRIVATE", nativePath="PRIVATE")
        report["workflowEvents"]["PRIVATE"] = 1
        observer.observe(report)
        self.assertNotIn("PRIVATE", str(observer.report()))

    def test_rejects_invalid_counts_and_bounds_samples(self):
        observer = WorkflowObservations(42, limit=1)
        invalid = sample(); invalid["revealedValueCount"] = True
        observer.observe(invalid)
        self.assertEqual(observer.report()["samples"], [])
        observer.observe(sample())
        second = sample(); second["windowVisible"] = False
        observer.observe(second)
        self.assertTrue(observer.report()["sampleBudgetExhausted"])
        self.assertEqual(len(observer.report()["samples"]), 1)

    def test_report_input_is_bounded_regular_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"processID":42}')
            self.assertEqual(read_workflow_report(path), {"processID": 42})
            link = Path(directory) / "link"; link.symlink_to(path)
            with self.assertRaises(OSError): read_workflow_report(link)
            fifo = Path(directory) / "fifo"; os.mkfifo(fifo)
            with self.assertRaises(ValueError): read_workflow_report(fifo)
            path.write_bytes(b" " * (256 * 1024 + 1))
            with self.assertRaises(ValueError): read_workflow_report(path)
            path.write_text('[]')
            with self.assertRaises(ValueError): read_workflow_report(path)


if __name__ == "__main__":
    unittest.main()
