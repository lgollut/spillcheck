"""Controlled provider diagnostics; no provider, authentication, app or Keychain access."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("claude_provider_failure_fixture", Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
PRIVATE = "fake-auth private-native-id /private/owned/source.jsonl"
SESSION = "You've hit your session limit · resets 2:20pm (Europe/Zurich)"


def encoded(*events):
    return b"".join(json.dumps(event).encode() + b"\n" for event in events)


class ProviderFailureTests(unittest.TestCase):
    def classify(self, output, errors=b"", exit_code=1):
        result = RUNNER.provider_failure_details(output, errors, exit_code=exit_code)
        for private in (PRIVATE, SESSION, "Europe/Zurich", "2:20pm"):
            self.assertNotIn(private, json.dumps(result))
        return result

    def test_flagged_assistant_session_limit_is_more_specific_than_rate_limit(self):
        event = {"type": "assistant", "error": "rate_limit", "isApiErrorMessage": True,
                 "message": {"content": [{"type": "text", "text": SESSION + " " + PRIVATE}]}}
        self.assertEqual(self.classify(encoded(event)), {
            "failureCategory": "sessionLimit", "failureClassificationTruncated": False})

    def test_flagged_result_limit_string_or_errors_list_is_classified(self):
        for fields in ({"result": SESSION}, {"errors": [SESSION]},
                       {"result": "You’ve hit your session limit"}):
            with self.subTest(fields=fields):
                self.assertEqual(self.classify(encoded({"type": "result", "is_error": True, **fields}))[
                    "failureCategory"], "sessionLimit")

    def test_explicit_provider_codes_have_closed_categories(self):
        for code, category in (("authentication_error", "authenticationUnavailable"),
                               ("invalid_api_key", "authenticationUnavailable"),
                               ("rate_limit_error", "rateLimit")):
            self.assertEqual(self.classify(encoded({"type": "error", "error": {
                "type": code, "message": PRIVATE}}))["failureCategory"], category)
        self.assertEqual(self.classify(encoded({"type": "result", "subtype": "error_max_budget_usd",
            "errors": [PRIVATE]}))["failureCategory"], "fixtureBudgetLimit")

    def test_known_error_messages_need_an_explicit_error_envelope(self):
        for text, category in (("Not logged in · Please run /login", "authenticationUnavailable"),
                               ("Invalid API key: " + PRIVATE, "authenticationUnavailable"),
                               ("Rate limit exceeded: " + PRIVATE, "rateLimit")):
            self.assertEqual(self.classify(encoded({"type": "error", "message": text}))[
                "failureCategory"], category)

    def test_prompt_tool_and_unflagged_assistant_text_cannot_diagnose_provider(self):
        events = [
            {"type": "user", "message": {"content": SESSION}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": SESSION}]}},
            {"type": "tool_result", "is_error": True, "content": SESSION},
            {"type": "result", "is_error": "true", "result": SESSION},
            {"type": "result", "is_error": False, "result": SESSION},
            {"type": "result", "is_error": True, "result": "The prompt quoted: " + SESSION},
        ]
        for event in events:
            self.assertEqual(self.classify(encoded(event))["failureCategory"], "providerFailed")

    def test_unknown_malformed_raw_and_duplicate_field_output_stays_generic(self):
        for output in (b"not JSON " + PRIVATE.encode(), SESSION.encode(), b"[]\n", b"{}\n",
                       b'{"type":"result","is_error":false,"is_error":true,"result":"Rate limit exceeded"}\n'):
            self.assertEqual(self.classify(output)["failureCategory"], "providerFailed")
        self.assertEqual(self.classify(b"", (SESSION + PRIVATE).encode())["failureCategory"], "providerFailed")

    def test_conflicting_provider_diagnoses_stay_generic(self):
        self.assertEqual(self.classify(encoded(
            {"type": "error", "error": {"type": "authentication_error"}},
            {"type": "error", "error": {"type": "rate_limit_error"}}))["failureCategory"], "providerFailed")

    def test_success_does_not_export_prior_recovered_provider_errors(self):
        self.assertEqual(self.classify(encoded({"type": "result", "is_error": True,
            "result": SESSION}), exit_code=0), {})

    def test_limits_bound_bytes_lines_and_fields_without_exposing_discarded_data(self):
        final = encoded({"type": "result", "is_error": True, "result": SESSION})
        result = self.classify(b"x" * (300 * 1024) + b"\n" + final)
        self.assertEqual(result["failureCategory"], "sessionLimit")
        self.assertTrue(result["failureClassificationTruncated"])
        result = self.classify(b"{}\n" * 200 + final)
        self.assertEqual(result["failureCategory"], "sessionLimit")
        self.assertTrue(result["failureClassificationTruncated"])
        result = self.classify(encoded({"type": "result", "is_error": True,
            "result": PRIVATE * 2048}))
        self.assertEqual(result["failureCategory"], "providerFailed")
        self.assertTrue(result["failureClassificationTruncated"])

    def test_run_provider_keeps_only_category_counts_and_cleanup(self):
        process = mock.Mock(returncode=1)
        process.communicate.return_value = (encoded({"type": "result", "is_error": True,
            "result": SESSION + PRIVATE}), PRIVATE.encode())
        cleanup = {"term_permission_denied": False, "kill_permission_denied": False}
        with mock.patch.object(RUNNER.subprocess, "Popen", return_value=process), \
             mock.patch.object(RUNNER, "stop_group", return_value=cleanup) as stopped:
            result = RUNNER.run_provider("fake", "fake prompt", {}, "/fake-project", "/fake-mcp")
        stopped.assert_called_once_with(process)
        self.assertEqual(result["failureCategory"], "sessionLimit")
        self.assertEqual(result["exitCode"], 1)
        self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertNotIn(SESSION, json.dumps(result))
        self.assertEqual(set(result), {"exitCode", "outputBytes", "diagnosticBytes", "failureCategory",
                                      "failureClassificationTruncated", "processGroupCleanup"})

    def test_signed_live_and_recovery_use_same_controlled_provider_labels(self):
        for name in ("run-app-claude-live.py", "run-app-claude-recovery.py"):
            path = Path(__file__).resolve().parents[1] / "AppAcceptance" / name
            spec = importlib.util.spec_from_file_location("shared_" + name, path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertEqual(module.fixture.provider_failure_details(encoded({
                "type": "assistant", "error": "rate_limit", "isApiErrorMessage": True,
                "message": {"content": [{"type": "text", "text": SESSION}]}}), b"", exit_code=1),
                {"failureCategory": "sessionLimit", "failureClassificationTruncated": False})


if __name__ == "__main__":
    unittest.main()
