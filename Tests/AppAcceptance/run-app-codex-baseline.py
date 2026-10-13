#!/usr/bin/env python3
"""Bind a fresh signed candidate to an immutable, previously owned fake T3 source."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location("codex_baseline_shared", Path(__file__).with_name("run-app-codex-recovery.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
ROOT = shared.ROOT


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-directory", required=True, type=Path)
    parser.add_argument("--candidate-manifest", required=True, type=Path)
    parser.add_argument("--directory", required=True, type=Path, help="New private evidence directory; never the source directory.")
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--expected-bundle-sha256", required=True)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--expected-reader-version", required=True)
    parser.add_argument("--expected-producer-version", required=True)
    parser.add_argument("--host-version", required=True, help="Observed original T3 source host version, not a new live-host claim.")
    return parser.parse_args(argv)


def signed_command(args, selection, directory, app, reader):
    return [sys.executable, str(ROOT / "Tests/AppAcceptance/run-app-codex-pipeline.py"),
        "--app", str(app), "--thread", selection["native"], "--home", str(selection["home"]),
        "--executable", str(reader), "--interface", "t3", "--host-version", args.host_version,
        "--expect-reader-version", args.expected_reader_version,
        "--expect-producer-version", args.expected_producer_version,
        "--output", str(directory / "signed-app-report.json"),
        "--private-control", str(directory / "signed-private-control.json")]


def receipt_template(args, binding, manifest_bytes, reader_hash):
    return {"schemaVersion": 1, "scope": shared.BASELINE_SCOPE, "passed": False,
        "signedCurrentCandidateBaselineEstablished": False,
        "sourceProvenanceBundleSHA256": binding["provenance_bundle"],
        "sourceProofSHA256": {name: shared.sha256_bytes(data) for name, data in binding["proof_bytes"].items()},
        "candidateBundleSHA256": shared.preflight.digest_value(args.expected_bundle_sha256),
        "candidateManifestSHA256": shared.sha256_bytes(manifest_bytes),
        "readerExecutableSHA256": reader_hash, "signedReportSHA256": None,
        "hostVersion": args.host_version, "readerVersion": args.expected_reader_version,
        "producerVersion": args.expected_producer_version,
        "expectedOccurrencesByContentType": binding["selection"]["counts"],
        "selectedThreadCount": 1, "providerSessionsCreated": 0,
        "sourceEnumerationPerformed": False, "providerConfigurationChanged": False,
        "fullT3Acceptance": False, "signedIndividualMarkerReceiptsVerified": False,
        "signedLiveCollectionEstablished": False, "historicalLiveEvidenceReboundToCurrentCandidate": False,
        "checks": {"historicalSourceProofsValidated": True}}


def run(args):
    os.umask(0o077)
    # These immutable reports are validated under their own historical bundle.
    # The new candidate must independently ingest the selected original source below.
    binding = shared.load_source_provenance(args.source_directory,
        root_native=os.environ.get("CODEX_THREAD_ID"), host=args.host_version,
        reader=args.expected_reader_version, producer=args.expected_producer_version, cwd=ROOT)
    selection = binding["selection"]
    manifest_bytes = shared.private_bytes(args.candidate_manifest)
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    shared.require(manifest == json.loads(manifest_bytes, object_pairs_hook=shared.unique_object)
        and shared.private_bytes(args.candidate_manifest) == manifest_bytes
        and manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256), "new-candidate-manifest-required")
    app = args.app.resolve(strict=True)
    reader = args.executable.resolve(strict=True)
    reader_hash = shared.preflight.hash_file(reader.parent, reader.name, [0])
    runner = ROOT / "Tests/AppAcceptance/run-app-codex-pipeline.py"
    runner_hash = shared.preflight.hash_file(runner.parent, runner.name, [0])
    directory = args.directory.absolute()
    shared.require(not directory.exists() and not directory.is_symlink()
        and directory.parent == directory.parent.resolve(strict=True)
        and directory != binding["source_directory"] and binding["source_directory"] not in directory.parents,
        "fresh-separate-baseline-directory-required")
    directory.mkdir(mode=0o700)
    shared.private_directory(directory)
    shared.write_new(directory / "candidate-build.json", manifest_bytes)
    report = receipt_template(args, binding, manifest_bytes, reader_hash)
    report["signedRunnerSHA256"] = runner_hash
    checks = report["checks"]
    cleanup = {}
    phase = "candidate-preflight"
    code = None
    signed = {}
    attempted = False
    try:
        shared.require(shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
        checks["candidatePreflightBeforePassed"] = True
        shared.require(shared.bound_evidence_unchanged(binding), "source-proofs-changed-before-baseline")
        phase = "signed-current-candidate-baseline"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SPILLCHECK_")}
        environment["CODEX_HOME"] = str(selection["home"])
        attempted = True
        code, output, elapsed = shared.live.bounded(signed_command(args, selection, directory, app, reader),
            environment=environment, directory=ROOT, timeout=90, maximum_bytes=256 * 1024, cleanup_report=cleanup)
        report.update(signedRunnerExitCode=code, runnerOutputBytes=len(output), elapsedMilliseconds=elapsed)
        raw_signed = shared.private_bytes(directory / "signed-app-report.json")
        signed = json.loads(raw_signed, object_pairs_hook=shared.unique_object)
        shared.require(isinstance(signed, dict), "signed-report-object-required")
        report["signedReportSHA256"] = shared.sha256_bytes(raw_signed)
        checks["signedExactSourceBaselinePassed"] = shared.exact_int(code, 0) and shared.signed_baseline_passed(signed,
            counts=selection["counts"], host=args.host_version, reader=args.expected_reader_version,
            producer=args.expected_producer_version)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
        report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
            failureCategory="controlled-baseline-failure")
    finally:
        checks["ownedRunnerGroupsStopped"] = cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
        try:
            checks["sourceProofsUnchanged"] = shared.bound_evidence_unchanged(binding)
            checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
            checks["signedRunnerUnchanged"] = shared.preflight.hash_file(runner.parent, runner.name, [0]) == runner_hash
            checks["candidatePreflightAfterPassed"] = (shared.private_bytes(args.candidate_manifest) == manifest_bytes
                and shared.private_bytes(directory / "candidate-build.json") == manifest_bytes
                and shared.preflight.check(manifest, app, ROOT)["consistent"])
        except (OSError, ValueError, RuntimeError):
            report["unmetGate"] = "final-evidence-boundary"
        result = signed.get("result", {}) if isinstance(signed, dict) else {}
        report["vaultCleanupConfirmed"] = result.get("newVaultCleanupPassed") is True
        report["signedRunnerLaunchAttempted"] = attempted
        report["runnerCleanupPending"] = attempted and signed.get("cleanupPending") is not False
        report["privateCleanupControlRetained"] = (directory / "signed-private-control.json").is_file()
        report["passed"] = ("unmetGate" not in report and set(checks) == shared.BASELINE_CHECKS
            and all(value is True for value in checks.values()))
        report["signedCurrentCandidateBaselineEstablished"] = report["passed"]
        shared.write_json(directory / "baseline-receipt.json", report)
        print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "baseline-rejected"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
