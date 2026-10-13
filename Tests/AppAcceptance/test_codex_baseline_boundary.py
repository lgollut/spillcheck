import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


baseline = module("codex_baseline", "run-app-codex-baseline.py")
fixtures = module("codex_recovery_fixtures", "test_codex_recovery_boundary.py")
shared = baseline.shared
OLD = fixtures.BUNDLE
NEW = "b" * 64


def manifest(bundle):
    return {"schemaVersion": 1, "bundleDigestFormat": shared.preflight.DIGEST_FORMAT,
        "bundleSHA256": bundle, "executableSHA256": "c" * 64, "sourceSHA256": {"Package.swift": "d" * 64}}


def signed_report():
    return {"schemaVersion": 1, "passed": True, "signedAppExitCode": 0, "timedOut": False,
        "actualReaderVersion": "reader", "observedProducerVersions": ["producer"], "interface": "t3",
        "hostVersion": "host", "selectedThreadCount": 1, "profileDiscoveryDisabled": True,
        "sourceIsOwnedSynthetic": True, "originalProviderStore": True, "passiveHistory": True,
        "strictNativeChildAcceptanceRequired": False, "stdoutBytes": 0, "diagnosticBytes": 0,
        "ciphertextMarkerInspectionPassed": True, "cleanupPending": False,
        "result": {"storageReady": True, "collectionConfigured": True,
            "syntheticValuePresent": True, "observedAgentVersions": ["producer"],
            "syntheticOccurrencesByContentType": dict(fixtures.COUNTS), "syntheticOccurrenceCount": 7,
            "occurrenceCount": 7, "valueCount": 1, "syntheticSessionCount": 1, "queueCount": 0,
            "gapReasons": [], "coverageReportTruncated": False, "newVaultCleanupPassed": True,
            "codexIndividualRoleCoverageMeasured": False}}


class Fixture:
    def __init__(self, directory):
        self.root = Path(directory).resolve()
        self.source = self.root / "original"
        self.source.mkdir(mode=0o700)
        self.home = self.root / "original-home"
        self.home.mkdir(mode=0o700)
        self.reader = self.root / "reader"
        shared.write_new(self.reader, b"controlled test executable; never run")
        self.reader.chmod(0o700)
        self.app = self.root / "fake.app"
        self.app.mkdir(mode=0o700)
        self.candidate_manifest = self.root / "new-candidate.json"
        shared.write_json(self.candidate_manifest, manifest(NEW))
        self.current = self.root / "current-baseline"
        self.proofs = fixtures.proofs()
        self.proofs["native-identity.json"].update(cwd=str(shared.ROOT), home=str(self.home))
        self.proofs["candidate-build.json"] = manifest(OLD)
        for name, value in self.proofs.items():
            shared.write_json(self.source / name, value)
        self.args = SimpleNamespace(source_directory=self.source, candidate_baseline_directory=None,
            candidate_manifest=self.candidate_manifest, directory=self.current, app=self.app,
            expected_bundle_sha256=NEW, executable=self.reader, expected_reader_version="reader",
            expected_producer_version="producer", host_version="host")

    def binding(self):
        return shared.load_source_provenance(self.source, root_native=fixtures.ROOT_NATIVE,
            host="host", reader="reader", producer="producer", cwd=shared.ROOT)

    def prepare_baseline(self):
        self.current.mkdir(mode=0o700)
        candidate = shared.private_bytes(self.candidate_manifest)
        shared.write_new(self.current / "candidate-build.json", candidate)
        shared.write_json(self.current / "signed-app-report.json", signed_report())
        binding = self.binding()
        receipt = baseline.receipt_template(self.args, binding, candidate,
            shared.preflight.hash_file(self.reader.parent, self.reader.name, [0]))
        receipt.update(passed=True, signedCurrentCandidateBaselineEstablished=True,
            signedRunnerExitCode=0, signedRunnerLaunchAttempted=True, vaultCleanupConfirmed=True, runnerCleanupPending=False,
            signedReportSHA256=shared.sha256_bytes(shared.private_bytes(self.current / "signed-app-report.json")),
            checks={key: True for key in shared.BASELINE_CHECKS})
        shared.write_json(self.current / "baseline-receipt.json", receipt)
        self.args.candidate_baseline_directory = self.current
        return receipt

    def rewrite(self, directory, name, value):
        path = directory / name
        path.unlink()
        shared.write_json(path, value)


class CodexBaselineBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"CODEX_THREAD_ID": fixtures.ROOT_NATIVE})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_default_keeps_original_same_candidate_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)
            fixture.args.expected_bundle_sha256 = OLD
            binding = shared.load_bound_selection(fixture.args)
            self.assertEqual(binding["manifest"]["bundleSHA256"], OLD)
            self.assertIsNone(binding["baseline_directory"])
            self.assertFalse(shared.evidence_lineage(binding)["historicalLiveEvidenceReboundToCurrentCandidate"])

    def test_current_baseline_links_immutable_original_and_new_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            original = {name: shared.private_bytes(fixture.source / name) for name in shared.PROOFS}
            fixture.prepare_baseline()
            binding = shared.load_bound_selection(fixture.args)
            self.assertEqual(binding["manifest"]["bundleSHA256"], NEW)
            self.assertEqual(binding["provenance_bundle"], OLD)
            self.assertEqual(binding["selection"]["native"], fixtures.CHILD)
            self.assertEqual(binding["selection"]["home"], fixture.home)
            self.assertEqual(binding["proof_bytes"], original)
            self.assertTrue(shared.bound_evidence_unchanged(binding))
            self.assertEqual(len(binding["evidence_files"]), len(shared.PROOFS) + len(shared.BASELINE_FILES))
            fixture.rewrite(fixture.current, "baseline-receipt.json", {"changed": True})
            self.assertFalse(shared.bound_evidence_unchanged(binding))

    def test_baseline_cannot_relabel_old_candidate_or_historical_live_evidence(self):
        for key, value in (("candidateBundleSHA256", OLD), ("sourceProvenanceBundleSHA256", NEW),
                ("historicalLiveEvidenceReboundToCurrentCandidate", True), ("signedLiveCollectionEstablished", True),
                ("signedIndividualMarkerReceiptsVerified", True), ("fullT3Acceptance", True),
                ("providerSessionsCreated", True), ("selectedThreadCount", True), ("hostVersion", "other"),
                ("readerVersion", "other"), ("producerVersion", "other"), ("passed", False)):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                receipt = fixture.prepare_baseline()
                fixture.rewrite(fixture.current, "baseline-receipt.json", {**receipt, key: value})
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_old_signed_summary_cannot_substitute_for_new_signed_report(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            receipt = fixture.prepare_baseline()
            fixture.rewrite(fixture.current, "signed-app-report.json", fixture.proofs["signed-summary.json"])
            receipt["signedReportSHA256"] = shared.sha256_bytes(shared.private_bytes(fixture.current / "signed-app-report.json"))
            fixture.rewrite(fixture.current, "baseline-receipt.json", receipt)
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)

    def test_cleanup_or_wrapper_failure_cannot_claim_a_current_baseline(self):
        for key, value in (("signedRunnerExitCode", 1), ("signedRunnerExitCode", False),
                ("signedRunnerLaunchAttempted", False), ("vaultCleanupConfirmed", False), ("runnerCleanupPending", True)):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                receipt = fixture.prepare_baseline()
                fixture.rewrite(fixture.current, "baseline-receipt.json", {**receipt, key: value})
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_missing_extra_or_changed_proof_hashes_are_rejected(self):
        for mutation in ("missing", "extra", "changed"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                receipt = fixture.prepare_baseline()
                if mutation == "missing": del receipt["sourceProofSHA256"]["native-identity.json"]
                elif mutation == "extra": receipt["sourceProofSHA256"]["unknown.json"] = "e" * 64
                else: receipt["sourceProofSHA256"]["native-identity.json"] = "e" * 64
                fixture.rewrite(fixture.current, "baseline-receipt.json", receipt)
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_native_identity_or_home_substitution_breaks_lineage(self):
        for key in ("threadID", "home"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                fixture.prepare_baseline()
                selected = copy.deepcopy(fixture.proofs["native-identity.json"])
                if key == "threadID": selected[key] = "33333333-3333-4333-8333-333333333333"
                else:
                    replacement = fixture.root / "other-home"
                    replacement.mkdir(mode=0o700)
                    selected[key] = str(replacement)
                fixture.rewrite(fixture.source, "native-identity.json", selected)
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_report_manifest_and_reader_mutation_cannot_pass(self):
        for target in ("signed-app-report.json", "candidate-build.json", "reader"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                fixture.prepare_baseline()
                if target == "reader": fixture.reader.write_bytes(b"changed reader")
                elif target == "signed-app-report.json":
                    fixture.rewrite(fixture.current, target, {**signed_report(), "unexpected": True})
                else: fixture.rewrite(fixture.current, target, manifest(OLD))
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_fresh_signed_baseline_requires_all_exact_gates_not_just_passed(self):
        original = signed_report()
        self.assertTrue(shared.signed_baseline_passed(original, counts=fixtures.COUNTS, host="host", reader="reader", producer="producer"))
        for target, key, value in (("top", "signedAppExitCode", False), ("top", "timedOut", True),
                ("top", "cleanupPending", True), ("top", "selectedThreadCount", 2),
                ("top", "profileDiscoveryDisabled", False), ("top", "diagnosticBytes", 1),
                ("top", "observedProducerVersions", ["different"]), ("top", "hostVersion", "different"),
                ("top", "ciphertextMarkerInspectionPassed", False),
                ("result", "syntheticOccurrencesByContentType", {**fixtures.COUNTS, "toolError": True}),
                ("result", "syntheticOccurrenceCount", 8), ("result", "occurrenceCount", 8),
                ("result", "syntheticSessionCount", 2), ("result", "valueCount", 2),
                ("result", "queueCount", 1), ("result", "gapReasons", ["source-unavailable"]),
                ("result", "coverageReportTruncated", True), ("result", "newVaultCleanupPassed", False),
                ("result", "codexIndividualRoleCoverageMeasured", True)):
            changed = copy.deepcopy(original)
            (changed if target == "top" else changed["result"])[key] = value
            with self.subTest(target=target, key=key):
                self.assertFalse(shared.signed_baseline_passed(changed, counts=fixtures.COUNTS, host="host", reader="reader", producer="producer"))

    def test_missing_failed_or_extra_baseline_check_is_rejected(self):
        for mutation in ("missing", "failed", "extra"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                receipt = fixture.prepare_baseline()
                if mutation == "missing": del receipt["checks"]["ownedRunnerGroupsStopped"]
                elif mutation == "failed": receipt["checks"]["ownedRunnerGroupsStopped"] = False
                else: receipt["checks"]["inferredAcceptance"] = True
                fixture.rewrite(fixture.current, "baseline-receipt.json", receipt)
                with self.assertRaises(shared.GateFailure):
                    shared.load_bound_selection(fixture.args)

    def test_baseline_directory_cannot_alias_source_or_follow_link(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.args.candidate_baseline_directory = fixture.source
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)
            fixture.prepare_baseline()
            alias = fixture.root / "alias"
            alias.symlink_to(fixture.current)
            fixture.args.candidate_baseline_directory = alias
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)

    def test_duplicate_receipt_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.prepare_baseline()
            path = fixture.current / "baseline-receipt.json"
            path.write_bytes(b'{"passed": true, "passed": false}')
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)

    def test_command_reads_one_original_source_without_provider_launch_or_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            command = baseline.signed_command(fixture.args, fixture.binding()["selection"], fixture.current, fixture.app, fixture.reader)
            self.assertEqual(command.count("--thread"), 1)
            self.assertEqual(command[command.index("--thread") + 1], fixtures.CHILD)
            self.assertEqual(command[command.index("--home") + 1], str(fixture.home))
            self.assertEqual(command[command.index("--interface") + 1], "t3")
            self.assertNotIn("--expected-child", command)
            self.assertNotIn("exec", command)

    def test_mocked_baseline_pass_binds_new_report_and_keeps_old_files_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            originals = {name: shared.private_bytes(fixture.source / name) for name in shared.PROOFS}
            def fake_signed(arguments, **kwargs):
                path = Path(arguments[arguments.index("--output") + 1])
                shared.write_json(path, signed_report())
                shared.write_json(path.parent / "signed-private-control.json", {"fake": True})
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return 0, b"controlled aggregate", 1
            with patch.object(shared.preflight, "check", return_value={"consistent": True}), \
                    patch.object(shared.live, "bounded", side_effect=fake_signed), patch("builtins.print"):
                self.assertEqual(baseline.run(fixture.args), 0)
            fixture.args.candidate_baseline_directory = fixture.current
            binding = shared.load_bound_selection(fixture.args)
            self.assertEqual(binding["manifest"]["bundleSHA256"], NEW)
            self.assertEqual({name: shared.private_bytes(fixture.source / name) for name in shared.PROOFS}, originals)

    def test_preflight_failure_retains_failed_receipt_without_running_app(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            with patch.object(shared.preflight, "check", return_value={"consistent": False}), \
                    patch.object(shared.live, "bounded") as launch, patch("builtins.print"):
                self.assertEqual(baseline.run(fixture.args), 1)
            launch.assert_not_called()
            receipt = shared.private_json(fixture.current / "baseline-receipt.json")
            self.assertFalse(receipt["passed"])
            self.assertFalse(receipt["signedCurrentCandidateBaselineEstablished"])
            self.assertFalse(receipt["vaultCleanupConfirmed"])
            self.assertFalse(receipt["signedRunnerLaunchAttempted"])
            self.assertFalse(receipt["runnerCleanupPending"])
            self.assertTrue((fixture.current / "candidate-build.json").is_file())

    def test_failed_signed_attempt_retains_cleanup_control_and_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            def fake_failure(arguments, **kwargs):
                path = Path(arguments[arguments.index("--output") + 1])
                report = signed_report()
                report.update(passed=False, cleanupPending=True)
                report["result"]["newVaultCleanupPassed"] = False
                shared.write_json(path, report)
                shared.write_json(path.parent / "signed-private-control.json", {"ownedArtifactDirectory": "/fake/private/control"})
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return 1, b"controlled failure", 1
            with patch.object(shared.preflight, "check", return_value={"consistent": True}), \
                    patch.object(shared.live, "bounded", side_effect=fake_failure), patch("builtins.print"):
                self.assertEqual(baseline.run(fixture.args), 1)
            receipt_bytes = shared.private_bytes(fixture.current / "baseline-receipt.json")
            receipt = shared.private_json(fixture.current / "baseline-receipt.json")
            self.assertFalse(receipt["passed"])
            self.assertTrue(receipt["runnerCleanupPending"])
            self.assertTrue(receipt["privateCleanupControlRetained"])
            fixture.args.candidate_baseline_directory = fixture.current
            with self.assertRaises(shared.GateFailure):
                shared.load_bound_selection(fixture.args)
            with patch.object(shared.live, "bounded") as launch, self.assertRaises(shared.GateFailure):
                baseline.run(fixture.args)
            launch.assert_not_called()
            self.assertEqual(shared.private_bytes(fixture.current / "baseline-receipt.json"), receipt_bytes)


if __name__ == "__main__":
    unittest.main()
