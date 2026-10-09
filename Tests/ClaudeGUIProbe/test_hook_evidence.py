"""Constructed hook boundary checks. These do not establish GUI acceptance."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

hook = load("claude_gui_hook_test", "hook.py")
probe = load("claude_gui_probe_test", "run.py")
PROMPT, FINAL = "LEAKRET_PHASE0_SIDEPROBE_PROMPT", "LEAKRET_PHASE0_SIDEPROBE_FINAL"

class HookEvidenceBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spillcheck-gui-hook-evidence-", dir="/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.journal = self.root / "summary.jsonl"
        self.config = {"source": str(self.root / "private-native.jsonl"),
            "sessionID": "private-native-session", "childDirectory": str(self.root / "private-native/subagents"),
            "events": ["SubagentStart", "SubagentStop", "MessageDisplay", "UserPromptSubmit"],
            "markers": [PROMPT, FINAL]}
        self.key = b"k" * 32

    def tearDown(self):
        self.temporary.cleanup()

    def summary(self, name, **fields):
        event = {"hook_event_name": name, "session_id": self.config["sessionID"],
            "transcript_path": self.config["source"], **fields}
        value = hook.controlled_summary(event, len(json.dumps(event)), self.config, self.key)
        value.update(forwarded=True, helperExitCode=0)
        return value

    def report(self, rows, native_paths=()):
        self.journal.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return probe.hook_summary(self.journal, set(), native_paths, PROMPT, FINAL)

    def test_empty_agent_type_final_is_independent_from_display_and_contains_no_raw_data(self):
        row = self.summary("SubagentStop", agent_id="private-agent-identity", agent_type="",
            agent_transcript_path=self.config["childDirectory"] + "/agent-private-agent-identity.jsonl",
            last_assistant_message=FINAL + " private-synthetic-value")
        report = self.report([row])
        self.assertEqual(report["sideFinalSubagentStopSelectedCallbackCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopSuccessfulDeliveryCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopAgentTypeCategories"], ["empty"])
        self.assertEqual(report["sideFinalDisplayGroupCount"], 0)
        self.assertEqual(report["sideFinalSubagentStopExactExistingNativeTranscriptMatches"], 0)
        self.assertNotIn("private-agent-identity", json.dumps(row))
        self.assertNotIn("private-synthetic-value", json.dumps(row))
        self.assertNotIn(str(self.root), json.dumps(row))
        self.assertNotIn(row["agentComparison"], json.dumps(report))

    def test_start_stop_exact_agent_comparison_and_duplicate_events(self):
        start = self.summary("SubagentStart", agent_id="private-agent", agent_type="private-custom-name")
        stop = self.summary("SubagentStop", agent_id="private-agent", agent_type="private-custom-name",
            agent_transcript_path=self.config["childDirectory"] + "/agent-private-agent.jsonl",
            last_assistant_message=FINAL)
        report = self.report([start, stop, stop], {stop["agentTranscriptComparison"]})
        self.assertEqual(report["sideFinalSubagentStopAgentIDsMatchedStartCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopDistinctEventCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopDuplicateCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopExactExistingNativeTranscriptMatches"], 2)
        self.assertEqual(report["sideFinalSubagentStopAgentTypeCategories"], ["nonempty"])
        self.assertNotIn("private-custom-name", json.dumps(stop))

    def test_wrong_selected_session_cannot_establish_side_callback(self):
        row = self.summary("SubagentStop", session_id="different-native-session", agent_id="private-agent",
            agent_type="", last_assistant_message=FINAL)
        report = self.report([row])
        self.assertEqual(report["sideFinalSubagentStopCount"], 1)
        self.assertEqual(report["sideFinalSubagentStopSelectedCallbackCount"], 0)
        self.assertEqual(report["sideFinalSubagentStopSuccessfulDeliveryCount"], 0)

    def test_assistant_echo_is_not_prompt_capture_and_nested_transcript_is_not_own_child(self):
        row = self.summary("SubagentStop", agent_id="private-agent", agent_type="",
            agent_transcript_path=self.config["childDirectory"] + "/nested/agent-private-agent.jsonl",
            last_assistant_message=PROMPT + " " + FINAL)
        report = self.report([row])
        self.assertTrue(report["sidePromptHookObserved"])
        self.assertFalse(report["sidePromptUserPromptSubmitObserved"])
        self.assertEqual(report["sideFinalSubagentStopSelectedChildPathCount"], 0)

    def test_conflicting_display_batches_do_not_prove_complete_group(self):
        first = self.summary("MessageDisplay", turn_id="private-turn", message_id="private-display", index=0,
            final=True, delta=FINAL)
        conflicting = self.summary("MessageDisplay", turn_id="private-turn", message_id="private-display", index=0,
            final=True, delta=FINAL + " changed")
        report = self.report([first, conflicting])
        self.assertEqual(report["sideFinalDisplayGroupCount"], 1)
        self.assertEqual(report["completeSideFinalDisplayGroupCount"], 0)
        self.assertEqual(report["sideFinalSubagentStopCount"], 0)

if __name__ == "__main__":
    unittest.main()
