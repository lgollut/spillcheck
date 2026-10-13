import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("beta_trial", Path(__file__).with_name("trial.py"))
trial = importlib.util.module_from_spec(spec); spec.loader.exec_module(trial)
DIGEST = "a" * 64


def cli(log, *arguments):
    return subprocess.run([sys.executable, str(Path(__file__).with_name("trial.py")), "--log", str(log),
        *arguments], capture_output=True, timeout=5)


def record_arguments(digest=DIGEST, provider="codex"):
    return ["record", "--candidate-bundle-sha256", digest, "--date", "2026-10-12",
        "--provider", provider, "--host", "cli", "--content-type", "userPrompt"]


def row(day="2026-10-12", provider="codex", host="cli", content="userPrompt", **counts):
    return {"date": day, "provider": provider, "host": host, "contentType": content,
        "counts": {key: counts.get(key, 0) for key in trial.COUNTS}, "latencyMilliseconds": [], "resources": {}}


class TrialMetrics(unittest.TestCase):
    def test_empty_claude_scope_requires_fifteen_scopes_without_implying_a_trial(self):
        log = trial.new_log(DIGEST, scope="claude-beta-v1")
        self.assertEqual(log, {"schemaVersion": 3, "candidateBundleSHA256": DIGEST,
            "scope": "claude-beta-v1", "days": []})
        report = trial.summarize(log)
        self.assertEqual(report["declaredScope"], "claude-beta-v1")
        self.assertEqual(report["requiredProviders"], ["claude"])
        self.assertEqual(report["requiredHosts"], list(trial.HOSTS))
        self.assertEqual(report["unseededRequiredScopes"], [
            {"provider": "claude", "host": host, "contentType": content}
            for host in trial.HOSTS for content in trial.TYPES])
        self.assertEqual(report["loggedDates"], [])
        self.assertEqual(report["loggedWorkingDays"], 0)
        self.assertEqual(report["byScope"], [])
        self.assertFalse(report["minimumFiveWorkingDaysLogged"])
        self.assertFalse(report["allRequiredRoutesHaveSeededObservations"])
        self.assertFalse(report["allSixRoutesHaveSeededObservations"])
        self.assertFalse(report["trialAcceptanceEstablished"])
        self.assertFalse(report["candidateArtifactVerified"])
        self.assertIsNone(report["overall"]["seededItemCollectionRecall"]["ratio"])

    def test_claude_scope_includes_native_child_prompts_and_its_exact_exclusions(self):
        report = trial.summarize(trial.new_log(DIGEST, scope="claude-beta-v1"))
        self.assertEqual(report["includedSourceClasses"],
            ["savedMainConversations", "readableNativeSubagentConversations"])
        self.assertEqual(report["includedContentTypes"], list(trial.TYPES))
        self.assertEqual(report["excludedSourceClasses"],
            ["desktopSideQuestions", "claudeChat", "cowork", "remoteCode", "binaryMediaAnalysis"])
        self.assertNotIn("encryptedIncomingSubagentInstructions", report["excludedSourceClasses"])
        self.assertNotIn("runtimeUnverifiedContent", report)
        self.assertEqual(report["scopeAttribution"], "operatorDeclaredAtInitialization")
        self.assertEqual(report["hostAttribution"], "operatorDeclaredPerSnapshot")
        self.assertFalse(report["sourceClassMembershipVerified"])

    def test_complete_five_day_claude_matrix_never_promotes_acceptance(self):
        log = trial.new_log(DIGEST, scope="claude-beta-v1")
        for day in range(12, 17):
            for host in trial.HOSTS:
                for content in trial.TYPES:
                    log = trial.record(log, row(day=f"2026-10-{day}", provider="claude",
                        host=host, content=content, expectedItems=1, collectedItems=1,
                        expectedValues=1, collectedValues=1, normalizedValues=1,
                        detectedValues=1, visibleValues=1), DIGEST)
        report = trial.summarize(log)
        self.assertEqual(len(report["byScope"]), 15)
        self.assertEqual(report["unseededRequiredScopes"], [])
        self.assertTrue(report["allRequiredRoutesHaveSeededObservations"])
        self.assertTrue(report["minimumFiveWorkingDaysLogged"])
        self.assertEqual(report["overall"]["seededValueEndToEndRecall"]["ratio"], 1)
        self.assertFalse(report["allSixRoutesHaveSeededObservations"])
        self.assertFalse(report["trialAcceptanceEstablished"])
        self.assertFalse(report["candidateArtifactVerified"])
        self.assertFalse(report["sourceClassMembershipVerified"])

    def test_claude_scope_rejects_other_provider_and_modified_scope_schema(self):
        log = trial.new_log(DIGEST, scope="claude-beta-v1")
        with self.assertRaisesRegex(trial.Invalid, "rowOutsideDeclaredScope"):
            trial.record(log, row(provider="codex"), DIGEST)
        log = trial.record(log, row(provider="claude"), DIGEST)
        for scope in ("codex-beta-v1", "all-providers", "claude", {}, None):
            changed = copy.deepcopy(log); changed["scope"] = scope
            with self.subTest(scope=scope):
                with self.assertRaises(trial.Invalid): trial.validate_log(changed)
        for key, value in (("excludedSourceClasses", []), ("sourceClass", "private")):
            changed = copy.deepcopy(log); changed[key] = value
            with self.assertRaises(trial.Invalid): trial.validate_log(changed)

    def test_claude_cli_scope_cannot_reinitialize_any_existing_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            for initial_scope in ("all-providers", "codex-beta-v1", "claude-beta-v1"):
                path = Path(temporary) / (initial_scope + ".json")
                self.assertEqual(cli(path, "init", "--candidate-bundle-sha256", DIGEST,
                    "--scope", initial_scope).returncode, 0)
                original = path.read_bytes()
                attempted_scopes = (("all-providers", "codex-beta-v1", "claude-beta-v1")
                    if initial_scope == "claude-beta-v1" else ("claude-beta-v1",))
                for scope in attempted_scopes:
                    result = cli(path, "init", "--candidate-bundle-sha256", DIGEST, "--scope", scope)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(json.loads(result.stdout)["reason"], "logAlreadyExists")
                    self.assertEqual(path.read_bytes(), original)

    def test_claude_cli_rejects_digest_provider_and_scope_changes_without_losing_misses(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "private-claude-counts.json"
            self.assertEqual(cli(path, "init", "--candidate-bundle-sha256", DIGEST,
                "--scope", "claude-beta-v1").returncode, 0)
            self.assertEqual(cli(path, *record_arguments(provider="claude"), "--expected-items", "2",
                "--collected-items", "0", "--expected-values", "2", "--collected-values", "0",
                "--normalized-values", "0", "--detected-values", "0", "--visible-values", "0").returncode, 0)
            original = path.read_bytes()
            for arguments, reason in (
                (record_arguments("b" * 64, provider="claude"), "candidateBundleMismatch"),
                (record_arguments(provider="codex"), "rowOutsideDeclaredScope")):
                result = cli(path, *arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["reason"], reason)
                self.assertEqual(path.read_bytes(), original)
                self.assertNotIn(str(path).encode(), result.stdout + result.stderr)
            result = cli(path, *record_arguments(provider="claude"), "--scope", "codex-beta-v1")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), original)
            report = json.loads(cli(path, "summary").stdout)
            self.assertEqual(report["overall"]["seededValueMissesByStage"]["collection"], 2)
            self.assertEqual(len(report["unseededRequiredScopes"]), 14)
            self.assertEqual(report["declaredScope"], "claude-beta-v1")
            self.assertFalse(report["trialAcceptanceEstablished"])
            self.assertNotIn(str(path), json.dumps(report))

    def test_codex_beta_scope_has_its_own_matrix_without_full_matrix_acceptance(self):
        log = trial.new_log(DIGEST, scope="codex-beta-v1")
        for host in trial.HOSTS:
            for content in trial.TYPES:
                log = trial.record(log, row(host=host, content=content, expectedItems=1,
                    collectedItems=1, expectedValues=1, collectedValues=1, normalizedValues=1,
                    detectedValues=1, visibleValues=1), DIGEST)
        report = trial.summarize(log)
        self.assertEqual(report["declaredScope"], "codex-beta-v1")
        self.assertEqual(report["requiredProviders"], ["codex"])
        self.assertEqual(report["unseededRequiredScopes"], [])
        self.assertTrue(report["allRequiredRoutesHaveSeededObservations"])
        self.assertFalse(report["allSixRoutesHaveSeededObservations"])
        self.assertFalse(report["trialAcceptanceEstablished"])
        self.assertFalse(report["candidateArtifactVerified"])
        self.assertIn("automaticEphemeralSideChats", report["excludedSourceClasses"])
        self.assertIn("encryptedIncomingSubagentInstructions", report["excludedSourceClasses"])
        self.assertEqual(report["candidateAttribution"], "recordedDigest")

    def test_codex_scope_rejects_other_provider_and_arbitrary_scope(self):
        log = trial.new_log(DIGEST, scope="codex-beta-v1")
        with self.assertRaises(trial.Invalid): trial.record(log, row(provider="claude"), DIGEST)
        for scope in ("private-project", {}, None):
            with self.assertRaises(trial.Invalid): trial.new_log(DIGEST, scope=scope)
        for key, value in (("scope", "all-providers"), ("notes", "private")):
            changed = copy.deepcopy(log); changed[key] = value
            with self.assertRaises(trial.Invalid): trial.validate_log(changed)

    def test_scoped_cli_does_not_relabel_old_log_or_hide_included_misses(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "trial.json"
            self.assertEqual(cli(path, "init", "--candidate-bundle-sha256", DIGEST,
                "--scope", "codex-beta-v1").returncode, 0)
            self.assertEqual(cli(path, *record_arguments(), "--expected-items", "2",
                "--collected-items", "0", "--expected-values", "2", "--collected-values", "0",
                "--normalized-values", "0", "--detected-values", "0", "--visible-values", "0").returncode, 0)
            before = path.read_bytes()
            self.assertNotEqual(cli(path, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            self.assertEqual(path.read_bytes(), before)
            report = json.loads(cli(path, "summary").stdout)
            self.assertEqual(report["overall"]["seededValueMissesByStage"]["collection"], 2)
            self.assertEqual(len(report["unseededRequiredScopes"]), 14)
            self.assertFalse(report["allRequiredRoutesHaveSeededObservations"])
            self.assertNotIn(str(path), json.dumps(report))

    def test_denominators_and_all_four_miss_classes(self):
        measured = row(expectedItems=10, collectedItems=8, expectedValues=20, collectedValues=16,
            normalizedValues=14, detectedValues=11, visibleValues=10,
            confirmedFindings=3, falsePositiveFindings=1, unreviewedFindings=99)
        report = trial.summarize({"schemaVersion": 1, "days": [measured]})
        metrics = report["overall"]
        self.assertEqual(metrics["seededItemCollectionRecall"], {"numerator": 8, "denominator": 10, "ratio": .8})
        self.assertEqual(metrics["seededValueDetectionRecallInCollectedContent"]["ratio"], 11 / 16)
        self.assertEqual(metrics["seededValueEndToEndRecall"]["ratio"], .5)
        self.assertEqual(metrics["precisionAmongReviewedFindings"]["ratio"], .75)
        self.assertEqual(metrics["unreviewedFindings"], 99)
        self.assertEqual(metrics["seededValueMissesByStage"],
            {"collection": 4, "normalization": 2, "detection": 3, "presentation": 1})
        self.assertEqual(sum(metrics["seededValueMissesByStage"].values()), 20 - 10)
        self.assertFalse(report["trialAcceptanceEstablished"])

    def test_empty_measurements_are_unknown_not_perfect(self):
        report = trial.summarize({"schemaVersion": 1, "days": []})
        self.assertIsNone(report["overall"]["precisionAmongReviewedFindings"]["ratio"])
        self.assertIsNone(report["overall"]["seededItemCollectionRecall"]["ratio"])
        self.assertIsNone(report["overall"]["latency"]["p95Milliseconds"])
        self.assertEqual(len(report["unseededRequiredScopes"]), 30)
        self.assertFalse(report["allSixRoutesHaveSeededObservations"])

    def test_snapshot_replacement_and_weighted_counts_avoid_false_averages(self):
        first = row(expectedItems=1, collectedItems=1, expectedValues=1, collectedValues=1,
            normalizedValues=1, detectedValues=1, visibleValues=1)
        second = row(day="2026-10-13", expectedItems=9, expectedValues=9)
        log = trial.record(trial.new_log(DIGEST), first, DIGEST)
        log = trial.record(log, first, DIGEST)
        self.assertEqual(len(log["days"]), 1)
        log = trial.record(log, second, DIGEST)
        self.assertEqual(trial.summarize(log)["overall"]["seededItemCollectionRecall"]["ratio"], .1)
        updated = copy.deepcopy(first); updated["counts"]["confirmedFindings"] = 2
        log = trial.record(log, updated, DIGEST)
        self.assertEqual(len(log["days"]), 2)
        self.assertEqual(trial.summarize(log)["overall"]["counts"]["expectedItems"], 10)

    def test_working_days_and_all_six_hosts_are_independent(self):
        log = {"schemaVersion": 1, "days": [row(day=f"2026-10-{day}") for day in range(12, 17)]}
        report = trial.summarize(log)
        self.assertTrue(report["minimumFiveWorkingDaysLogged"])
        self.assertFalse(report["allSixRoutesHaveSeededObservations"])
        self.assertFalse(report["trialAcceptanceEstablished"])
        weekends = {"schemaVersion": 1, "days": [row(day="2026-10-10"), row(day="2026-10-11")]}
        self.assertEqual(trial.summarize(weekends)["loggedWorkingDays"], 0)
        complete = {"schemaVersion": 1, "days": [row(provider=p, host=h, content=t, expectedItems=1, expectedValues=1)
            for p in trial.PROVIDERS for h in trial.HOSTS for t in trial.TYPES]}
        report = trial.summarize(complete)
        self.assertTrue(report["allSixRoutesHaveSeededObservations"])
        self.assertEqual(report["unseededRequiredScopes"], [])
        self.assertEqual(report["overall"]["seededItemCollectionRecall"]["ratio"], 0)

    def test_latency_sample_count_nearest_rank_and_observed_resources(self):
        measured = row(); measured["latencyMilliseconds"] = list(range(1, 21))
        measured["resources"] = {"queueDepth": 5, "rssMiB": 120}
        report = trial.metrics([measured])
        self.assertEqual(report["latency"]["sampleCount"], 20)
        self.assertEqual(report["latency"]["p50Milliseconds"], 10)
        self.assertEqual(report["latency"]["p95Milliseconds"], 19)
        self.assertTrue(report["latency"]["includesPollingDelay"])
        self.assertEqual(report["resourceObservations"]["queueDepth"], {"sampleCount": 1, "minimum": 5, "maximum": 5})
        self.assertNotIn("cpuPercent", report["resourceObservations"])

    def test_impossible_stage_counts_and_nonfinite_metrics_are_rejected(self):
        bad = [row(expectedItems=1, collectedItems=2), row(expectedItems=1, expectedValues=1, detectedValues=1),
            row(expectedItems=1, collectedItems=1, expectedValues=1), row(expectedValues=1)]
        for name, value in (("provider", "private-custom-provider"), ("date", "2026-02-31"), ("rawText", "private")):
            value_row = row(); value_row[name] = value; bad.append(value_row)
        for value in (float("nan"), float("inf"), -1, True, "private"):
            value_row = row(); value_row["latencyMilliseconds"] = [value]; bad.append(value_row)
            value_row = row(); value_row["resources"] = {"rssMiB": value}; bad.append(value_row)
        value_row = row(); value_row["resources"] = {"sourcePath": "/private"}; bad.append(value_row)
        for value in bad:
            with self.subTest(value=value):
                with self.assertRaises(trial.Invalid): trial.valid_row(value)

    def test_log_rejects_unstructured_fields_and_duplicate_daily_scopes(self):
        for value in ({"schemaVersion": 1, "days": [], "notes": "private"},
            {"schemaVersion": 1, "days": [row(), row()]}):
            with self.assertRaises(trial.Invalid): trial.validate_log(value)

    def test_cli_writes_only_fixed_count_schema_and_keeps_local_path_out(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "private-directory-label.json"
            self.assertEqual(cli(log, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            command = [sys.executable, str(Path(__file__).with_name("trial.py")), "--log", str(log), "record",
                "--candidate-bundle-sha256", DIGEST,
                "--date", "2026-10-12", "--provider", "codex", "--host", "cli", "--content-type", "toolError",
                "--expected-items", "2", "--collected-items", "0", "--expected-values", "2", "--collected-values", "0",
                "--normalized-values", "0", "--detected-values", "0", "--visible-values", "0",
                "--false-positive-findings", "1", "--latency-ms", "42",
                "--queue-depth", "0", "--cpu-percent", "2.3", "--rss-mib", "120", "--storage-mib", "14"]
            result = subprocess.run(command, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(str(log).encode(), result.stdout)
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            raw = log.read_text(); self.assertNotIn("private-directory-label", raw)
            report = trial.summarize(trial.read_log(log))
            self.assertEqual(report["overall"]["seededValueMissesByStage"]["collection"], 2)
            self.assertEqual(report["overall"]["precisionAmongReviewedFindings"]["ratio"], 0)
            self.assertEqual(report["overall"]["resourceObservations"]["rssMiB"]["maximum"], 120)
            result = subprocess.run(command, capture_output=True, timeout=5)
            self.assertTrue(json.loads(result.stdout)["replacedDailyScope"])

    def test_partial_seeded_measurements_cannot_silently_classify_unknown_stages(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "counts.json"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("trial.py")), "--log", str(log),
                "record", "--candidate-bundle-sha256", DIGEST, "--date", "2026-10-12", "--provider", "codex", "--host", "cli",
                "--content-type", "userPrompt", "--expected-items", "1"], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"all seven seeded item/value counts", result.stderr)
            self.assertFalse(log.exists())

    def test_symlink_log_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); target = root / "target"; target.write_text("untouched")
            link = root / "log"; link.symlink_to(target)
            with self.assertRaises(OSError): trial.read_log(link)
            with self.assertRaises(trial.Invalid): trial.write_log(link, {"schemaVersion": 1, "days": []})
            self.assertEqual(target.read_text(), "untouched")

    def test_candidate_binding_is_visible_without_claiming_artifact_verification(self):
        log = trial.record(trial.new_log(DIGEST), row(confirmedFindings=2), DIGEST)
        report = trial.summarize(log)
        self.assertEqual(log["candidateBundleSHA256"], DIGEST)
        self.assertEqual(report["candidateBundleSHA256"], DIGEST)
        self.assertEqual(report["candidateAttribution"], "recordedDigest")
        self.assertFalse(report["candidateArtifactVerified"])
        self.assertFalse(report["trialAcceptanceEstablished"])
        self.assertEqual(report["overall"]["counts"]["confirmedFindings"], 2)

    def test_candidate_mismatch_preserves_existing_snapshot_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "private-location.json"
            self.assertEqual(cli(log, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            self.assertEqual(cli(log, *record_arguments(), "--confirmed-findings", "2").returncode, 0)
            original = log.read_bytes()
            result = cli(log, *record_arguments("b" * 64), "--confirmed-findings", "99")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "candidateBundleMismatch")
            self.assertEqual(log.read_bytes(), original)
            self.assertNotIn(str(log).encode(), result.stdout + result.stderr)
            result = cli(log, *record_arguments(), "--confirmed-findings", "3")
            self.assertEqual(result.returncode, 0)
            self.assertTrue(json.loads(result.stdout)["replacedDailyScope"])
            self.assertEqual(trial.read_log(log)["days"][0]["counts"]["confirmedFindings"], 3)

    def test_candidate_digest_and_schema_reject_unstructured_or_wrongly_typed_metadata(self):
        invalid = [None, True, 0, {}, [], "a" * 63, "a" * 65, "A" * 64, "g" * 64, "a" * 64 + "\n", "private-note"]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(trial.Invalid): trial.new_log(value)
                with self.assertRaises(trial.Invalid):
                    trial.validate_log({"schemaVersion": 2, "candidateBundleSHA256": value, "days": []})
        for value in ({"schemaVersion": 2, "days": []},
            {"schemaVersion": 2, "candidateBundleSHA256": DIGEST, "days": [], "candidatePath": "/private"},
            {"schemaVersion": 1, "candidateBundleSHA256": DIGEST, "days": []}):
            with self.assertRaises(trial.Invalid): trial.validate_log(value)
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "counts.json"
            result = cli(log, "init", "--candidate-bundle-sha256", "private-unstructured-label")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "candidateBundleSHA256MustBeLowercaseHex")
            self.assertNotIn(b"private-unstructured-label", result.stdout + result.stderr)
            self.assertFalse(log.exists())

    def test_fresh_initialization_never_overwrites_or_rebinds_existing_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "counts.json"
            self.assertEqual(cli(log, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            original = log.read_bytes()
            for digest in (DIGEST, "b" * 64):
                result = cli(log, "init", "--candidate-bundle-sha256", digest)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["reason"], "logAlreadyExists")
                self.assertEqual(log.read_bytes(), original)
            link = Path(temporary) / "link.json"; link.symlink_to(log)
            result = cli(link, "init", "--candidate-bundle-sha256", "b" * 64)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(link.is_symlink())
            self.assertEqual(log.read_bytes(), original)
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(temporary).glob(".beta-trial-*")), [])

    def test_legacy_summary_is_unbound_and_legacy_bytes_remain_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "legacy.json"
            original = json.dumps({"schemaVersion": 1, "days": [row(confirmedFindings=4)]}).encode()
            log.write_bytes(original)
            result = cli(log, "summary")
            self.assertEqual(result.returncode, 0)
            report = json.loads(result.stdout)
            self.assertIsNone(report["candidateBundleSHA256"])
            self.assertEqual(report["candidateAttribution"], "legacyUnbound")
            self.assertFalse(report["candidateArtifactVerified"])
            self.assertFalse(report["trialAcceptanceEstablished"])
            self.assertEqual(report["overall"]["counts"]["confirmedFindings"], 4)
            self.assertEqual(log.read_bytes(), original)
            result = cli(log, *record_arguments(), "--confirmed-findings", "99")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "legacyLogIsReadOnly")
            self.assertEqual(log.read_bytes(), original)
            self.assertNotEqual(cli(log, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            self.assertEqual(log.read_bytes(), original)

    def test_record_requires_initialization_and_a_candidate_assertion_on_every_update(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "counts.json"
            result = cli(log, *record_arguments())
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "logNotInitialized")
            self.assertFalse(log.exists())
            self.assertEqual(cli(log, "init", "--candidate-bundle-sha256", DIGEST).returncode, 0)
            original = log.read_bytes()
            arguments = record_arguments(); del arguments[1:3]
            result = cli(log, *arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(log.read_bytes(), original)
            result = cli(log, *record_arguments("private-candidate-label"))
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(b"private-candidate-label", result.stdout + result.stderr)
            self.assertEqual(log.read_bytes(), original)
            missing_date = record_arguments(); del missing_date[3:5]
            self.assertNotEqual(cli(log, *missing_date).returncode, 0)
            self.assertEqual(log.read_bytes(), original)

    def test_huge_json_integer_metrics_fail_cleanly_without_changing_log_bytes(self):
        huge = 10 ** 400
        cases = [("latencyMilliseconds", [huge], "latencySamplesMustBeBoundedMilliseconds"),
            ("resources", {"rssMiB": huge}, "resourcesMustBeBoundedNonnegativeNumbers")]
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "private-counts.json"
            for key, value, reason in cases:
                with self.subTest(metric=key):
                    measured = row(); measured[key] = value
                    original = json.dumps({**trial.new_log(DIGEST), "days": [measured]}).encode()
                    log.write_bytes(original)
                    for command in (["summary"], record_arguments()):
                        result = cli(log, *command)
                        self.assertEqual(result.returncode, 1)
                        self.assertEqual(json.loads(result.stdout), {"recorded": False, "reason": reason})
                        self.assertEqual(result.stderr, b"")
                        self.assertEqual(log.read_bytes(), original)
                        self.assertNotIn(str(log).encode(), result.stdout)


if __name__ == "__main__": unittest.main()
