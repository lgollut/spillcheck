#!/usr/bin/env python3
"""Signed restart of one synthetic queued poll over an exact, previously owned T3 source."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
sys.path.insert(0, str(ROOT / "Tests/BetaTrial"))
from Support.acceptance_artifacts import AcceptanceArtifacts
from Support.processes import stop_group
import preflight

spec = importlib.util.spec_from_file_location("codex_recovery_live", ROOT / "Tests/CodexLive/run.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)

TOKEN = live.TOKEN.encode()
PROFILE = "owned-signed-codex-recovery"
TYPES = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
MARKERS = {key: 1 for key in ("PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR")}
PROOFS = ("native-identity.json", "observer-report.json", "signed-summary.json",
          "t3-task-terminal.json", "t3-lineage.json", "t3-live-overlap.json", "candidate-build.json")
DIGEST_KEYS = ("recoveryOccurrenceDigests", "recoveryReceiptDigests", "recoveryAlertDigests")
BASELINE_FILES = ("candidate-build.json", "signed-app-report.json", "baseline-receipt.json")
BASELINE_SCOPE = "signed-current-candidate-retained-T3-source-baseline"
BASELINE_CHECKS = {"historicalSourceProofsValidated", "candidatePreflightBeforePassed",
    "candidatePreflightAfterPassed", "sourceProofsUnchanged", "readerExecutableUnchanged",
    "signedRunnerUnchanged", "ownedRunnerGroupsStopped", "signedExactSourceBaselinePassed"}


class GateFailure(RuntimeError):
    def __init__(self, gate):
        self.gate = gate
        super().__init__(gate)


def require(value, gate):
    if not value:
        raise GateFailure(gate)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-key")
        result[key] = value
    return result


def private_bytes(path, limit=256 * 1024):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                and before.st_size <= limit, "private-file-boundary")
        data = os.read(descriptor, limit + 1)
        require(len(data) == before.st_size and preflight.fingerprint(before)
                == preflight.fingerprint(os.fstat(descriptor)), "private-file-changed")
        return data
    finally:
        os.close(descriptor)


def private_json(path):
    result = json.loads(private_bytes(path), object_pairs_hook=unique_object)
    require(isinstance(result, dict), "private-object-required")
    return result


def write_new(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        require(os.write(descriptor, data) == len(data), "short-private-write")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_json(path, value):
    write_new(path, json.dumps(value, sort_keys=True).encode() + b"\n")


def canonical_id(value):
    require(isinstance(value, str) and len(value) == 36, "native-identity-unavailable")
    require(str(uuid.UUID(value)) == value, "native-identity-unavailable")
    return value


def checked_counts(value):
    require(isinstance(value, dict) and set(value) == TYPES
            and all(type(count) is int and count > 0 for count in value.values()), "five-type-counts-required")
    return value


def exact_int(value, expected):
    return type(value) is int and value == expected


def validate_proofs(proofs, *, root_native, host, reader, producer, bundle, cwd):
    """Interpret only the closed proof contract; never discover a source from content."""
    selected = proofs["native-identity.json"]
    native = canonical_id(selected.get("threadID"))
    require(native != canonical_id(root_native) and selected.get("nativeIdentitySource") == "own-runtime-CODEX_THREAD_ID"
            and selected.get("cwd") == str(cwd) and selected.get("sourceEnumerationPerformed") is False
            and selected.get("homeSource") in ("CODEX_HOME", "CODEX_HOME-unset-HOME-default"), "owned-selection-required")
    home = Path(selected.get("home", ""))
    require(home.is_absolute() and "\0" not in str(home), "original-home-required")
    terminal, lineage = proofs["t3-task-terminal.json"], proofs["t3-lineage.json"]
    require(terminal.get("status") == "completed" and terminal.get("hasPendingChildRuns") is False
            and terminal.get("providerInstanceId") == "codex" and terminal.get("hostVersion") == host
            and isinstance(terminal.get("model"), str) and bool(terminal["model"]), "terminal-proof-required")
    require(lineage.get("source") == "t3_thread_read" and lineage.get("creationSource") == "mcp"
            and lineage.get("createdBy") == "agent" and lineage.get("relationshipToParent") == "subagent"
            and lineage.get("providerInstanceId") == "codex" and lineage.get("model") == terminal["model"]
            and lineage.get("status") == "completed" and type(lineage.get("runCount")) is int and lineage["runCount"] == 1
            and type(lineage.get("pendingRequestCount")) is int and lineage["pendingRequestCount"] == 0
            and all(lineage.get(key) is True for key in ("worktreeIsExpected", "isExactCreatedChild", "parentMatchesCurrent")),
            "T3-lineage-required")
    observer, signed, overlap = proofs["observer-report.json"], proofs["signed-summary.json"], proofs["t3-live-overlap.json"]
    require(observer.get("passed") is True and observer.get("hostVersion") == host and observer.get("readerVersion") == reader
            and observer.get("candidateBundleSHA256") == bundle and observer.get("sourceEnumerationPerformed") is False
            and observer.get("selectedThreadCount") == 1
            and all(observer.get(key) is True for key in ("producerCompletedSignal", "waitIdentityMatched",
                "ownedObserverGroupsStopped", "observerBinaryUnchanged", "candidateExecutableUnchanged")), "observer-proof-required")
    require(all(overlap.get(key) is True for key in ("observerTaskLifetimeOverlapEstablished",
                "firstCanonicalReadBeforeTaskCompletion")), "overlap-proof-required")
    pipeline = observer.get("pipeline", {})
    require(pipeline.get("typedCommitted") == MARKERS and pipeline.get("typedCommittedBeforeCatchUp") == MARKERS
            and pipeline.get("typedCommittedByRole") == {"parent": MARKERS, "child": {}}
            and pipeline.get("nativeSourceRoles") == {"primarySessionCount": 1, "verifiedPrimarySessionCount": 1,
                "nativeLinkedChildSessionCount": 0, "verifiedNativeLinkedChildSessionCount": 0}
            and pipeline.get("sessionCount") == 1 and pipeline.get("queueCount") == 0 and pipeline.get("gapReasons") == []
            and pipeline.get("replayStable") is True and pipeline.get("ciphertextMarkerInspectionPassed") is True
            and pipeline.get("actualReaderVersion") == reader and pipeline.get("observedProducerVersions") == [producer]
            and pipeline.get("interface") == "t3" and pipeline.get("hostVersion") == host, "typed-observer-proof-required")
    counts = checked_counts(pipeline.get("occurrencesByContentType"))
    require(pipeline.get("occurrenceCount") == sum(counts.values()), "observer-counts-mismatch")
    require(signed.get("passed") is True and signed.get("signedSelectedSourceAcceptance") is True
            and signed.get("candidateBundleSHA256") == bundle and signed.get("candidateBundleUnchanged") is True
            and signed.get("actualReaderVersion") == reader and signed.get("observedProducerVersions") == [producer]
            and signed.get("hostVersion") == host and signed.get("actualOccurrencesByContentType") == counts
            and signed.get("actualOccurrenceCount") == sum(counts.values()) and signed.get("actualSyntheticSessionCount") == 1
            and signed.get("newVaultCleanupPassed") is True and signed.get("cleanupPending") is False,
            "signed-source-proof-required")
    require(proofs["candidate-build.json"].get("bundleSHA256") == bundle, "candidate-proof-required")
    return {"native": native, "home": home, "counts": counts, "model": terminal["model"]}


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def private_directory(path):
    path = path.absolute()
    require(path == path.resolve(strict=True), "private-directory-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "private-directory-required")
    return path


def load_source_provenance(source, *, root_native, host, reader, producer, cwd, bundle=None):
    """Historical ownership evidence stays bound to its original candidate, never relabeled."""
    source = private_directory(source)
    raw = {name: private_bytes(source / name) for name in PROOFS}
    proofs = {name: json.loads(data, object_pairs_hook=unique_object) for name, data in raw.items()}
    require(all(isinstance(value, dict) for value in proofs.values()), "source-proof-object-required")
    manifest = preflight.read_manifest(source / "candidate-build.json")
    require(manifest == proofs["candidate-build.json"]
            and private_bytes(source / "candidate-build.json") == raw["candidate-build.json"], "source-manifest-changed")
    provenance_bundle = preflight.digest_value(manifest["bundleSHA256"])
    selection = validate_proofs(proofs, root_native=root_native, host=host, reader=reader,
        producer=producer, bundle=bundle if bundle is not None else provenance_bundle, cwd=cwd)
    require(selection["home"] == selection["home"].resolve(strict=True)
            and selection["home"].is_dir(), "canonical-original-home-required")
    return {"source_directory": source, "selection": selection, "manifest": manifest,
        "proof_bytes": raw, "provenance_bundle": provenance_bundle,
        "evidence_files": {source / name: data for name, data in raw.items()}}


def signed_baseline_passed(report, *, counts, host, reader, producer):
    """Exact durable counts, not old live observations, establish the new signed baseline."""
    result = report.get("result")
    if not isinstance(result, dict):
        return False
    actual = result.get("syntheticOccurrencesByContentType")
    return (report.get("passed") is True and exact_int(report.get("signedAppExitCode"), 0)
        and report.get("timedOut") is False and report.get("actualReaderVersion") == reader
        and report.get("observedProducerVersions") == [producer]
        and report.get("interface") == "t3" and report.get("hostVersion") == host
        and report.get("sourceIsOwnedSynthetic") is True and report.get("originalProviderStore") is True
        and report.get("passiveHistory") is True
        and exact_int(report.get("selectedThreadCount"), 1) and report.get("profileDiscoveryDisabled") is True
        and report.get("strictNativeChildAcceptanceRequired") is False
        and exact_int(report.get("stdoutBytes"), 0) and exact_int(report.get("diagnosticBytes"), 0)
        and report.get("ciphertextMarkerInspectionPassed") is True and report.get("cleanupPending") is False
        and result.get("storageReady") is True and result.get("collectionConfigured") is True
        and result.get("syntheticValuePresent") is True and result.get("observedAgentVersions") == [producer]
        and isinstance(actual, dict) and all(type(value) is int for value in actual.values()) and actual == counts
        and exact_int(result.get("syntheticOccurrenceCount"), sum(counts.values()))
        and exact_int(result.get("occurrenceCount"), sum(counts.values()))
        and exact_int(result.get("valueCount"), 1) and exact_int(result.get("syntheticSessionCount"), 1)
        and exact_int(result.get("queueCount"), 0) and result.get("gapReasons") == []
        and result.get("coverageReportTruncated") is False and result.get("newVaultCleanupPassed") is True
        and result.get("codexIndividualRoleCoverageMeasured") is False)


def validate_baseline_receipt(receipt, signed, *, binding, baseline_bytes, manifest, bundle,
        host, reader, producer, reader_hash):
    require(exact_int(receipt.get("schemaVersion"), 1) and receipt.get("scope") == BASELINE_SCOPE
        and receipt.get("passed") is True and receipt.get("signedCurrentCandidateBaselineEstablished") is True
        and exact_int(receipt.get("signedRunnerExitCode"), 0) and receipt.get("signedRunnerLaunchAttempted") is True
        and receipt.get("vaultCleanupConfirmed") is True and receipt.get("runnerCleanupPending") is False
        and receipt.get("candidateBundleSHA256") == bundle and manifest.get("bundleSHA256") == bundle
        and receipt.get("sourceProvenanceBundleSHA256") == binding["provenance_bundle"], "candidate-baseline-binding-required")
    expected_hashes = {name: sha256_bytes(data) for name, data in binding["proof_bytes"].items()}
    require(receipt.get("sourceProofSHA256") == expected_hashes
        and receipt.get("candidateManifestSHA256") == sha256_bytes(baseline_bytes["candidate-build.json"])
        and receipt.get("signedReportSHA256") == sha256_bytes(baseline_bytes["signed-app-report.json"])
        and receipt.get("readerExecutableSHA256") == reader_hash, "candidate-baseline-hash-mismatch")
    checks = receipt.get("checks")
    receipt_counts = receipt.get("expectedOccurrencesByContentType")
    require(isinstance(checks, dict) and set(checks) == BASELINE_CHECKS and all(value is True for value in checks.values())
        and receipt.get("hostVersion") == host and receipt.get("readerVersion") == reader
        and receipt.get("producerVersion") == producer
        and isinstance(receipt_counts, dict) and all(type(value) is int for value in receipt_counts.values())
        and receipt_counts == binding["selection"]["counts"]
        and exact_int(receipt.get("selectedThreadCount"), 1)
        and exact_int(receipt.get("providerSessionsCreated"), 0)
        and all(receipt.get(key) is False for key in ("sourceEnumerationPerformed", "providerConfigurationChanged",
            "fullT3Acceptance", "signedIndividualMarkerReceiptsVerified", "signedLiveCollectionEstablished",
            "historicalLiveEvidenceReboundToCurrentCandidate"))
        and signed_baseline_passed(signed, counts=binding["selection"]["counts"], host=host, reader=reader, producer=producer),
        "current-signed-baseline-required")


def load_bound_selection(args):
    """Read provenance and optional fresh baseline; the caller still preflights the actual app."""
    baseline_directory = getattr(args, "candidate_baseline_directory", None)
    bundle = preflight.digest_value(args.expected_bundle_sha256)
    binding = load_source_provenance(args.source_directory, root_native=os.environ.get("CODEX_THREAD_ID"),
        host=args.host_version, reader=args.expected_reader_version, producer=args.expected_producer_version,
        cwd=ROOT, bundle=bundle if baseline_directory is None else None)
    binding["baseline_directory"] = None
    binding["baseline_receipt_sha256"] = None
    if baseline_directory is not None:
        directory = private_directory(baseline_directory)
        require(directory != binding["source_directory"], "separate-candidate-baseline-required")
        raw = {name: private_bytes(directory / name) for name in BASELINE_FILES}
        values = {name: json.loads(data, object_pairs_hook=unique_object) for name, data in raw.items()}
        require(all(isinstance(value, dict) for value in values.values()), "baseline-object-required")
        manifest = preflight.read_manifest(directory / "candidate-build.json")
        require(manifest == values["candidate-build.json"] and private_bytes(directory / "candidate-build.json")
                == raw["candidate-build.json"], "baseline-manifest-changed")
        reader_path = args.executable.resolve(strict=True)
        reader_hash = preflight.hash_file(reader_path.parent, reader_path.name, [0])
        validate_baseline_receipt(values["baseline-receipt.json"], values["signed-app-report.json"],
            binding=binding, baseline_bytes=raw, manifest=manifest, bundle=bundle, host=args.host_version,
            reader=args.expected_reader_version, producer=args.expected_producer_version, reader_hash=reader_hash)
        binding.update(manifest=manifest, baseline_directory=directory,
            baseline_receipt_sha256=sha256_bytes(raw["baseline-receipt.json"]))
        binding["evidence_files"].update({directory / name: data for name, data in raw.items()})
    return binding


def bound_evidence_unchanged(binding):
    return all(private_bytes(path) == data for path, data in binding["evidence_files"].items())


def evidence_lineage(binding):
    return {"sourceProvenanceBundleSHA256": binding["provenance_bundle"],
        "currentCandidateBaselineRequired": binding["baseline_directory"] is not None,
        "currentCandidateBaselineReceiptSHA256": binding["baseline_receipt_sha256"],
        "historicalLiveEvidenceReboundToCurrentCandidate": False}


def digest_set(report, key, *, empty=False):
    values = report.get(key)
    if not isinstance(values, list) or len(values) > 8192 or (not empty and not values):
        return None
    try:
        if any(not isinstance(value, str) or len(value) != 44 or len(base64.b64decode(value, validate=True)) != 32 for value in values):
            return None
        return set(values) if len(set(values)) == len(values) else None
    except ValueError:
        return None


def manifest_digest(report):
    values = digest_set({"manifest": [report.get("recoveryManifestDigest")]}, "manifest")
    return next(iter(values)) if values else None


def collected(report, counts, producer):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
            and report.get("recoveryLoadedExistingManifest") is True and manifest_digest(report) is not None
            and isinstance(report.get("syntheticOccurrencesByContentType"), dict)
            and all(type(value) is int for value in report["syntheticOccurrencesByContentType"].values())
            and report.get("syntheticOccurrencesByContentType") == counts
            and exact_int(report.get("syntheticOccurrenceCount"), sum(counts.values()))
            and exact_int(report.get("occurrenceCount"), sum(counts.values())) and exact_int(report.get("valueCount"), 1)
            and exact_int(report.get("syntheticSessionCount"), 1) and report.get("observedAgentVersions") == [producer]
            and report.get("gapReasons") == [] and report.get("coverageReportTruncated") is False
            and all(digest_set(report, key, empty=key == "recoveryAlertDigests") is not None for key in DIGEST_KEYS))


def inventory_unchanged(before, after):
    return (manifest_digest(before) is not None and manifest_digest(before) == manifest_digest(after)
            and all(digest_set(before, key, empty=key == "recoveryAlertDigests") is not None
                    and digest_set(before, key, empty=key == "recoveryAlertDigests")
                    == digest_set(after, key, empty=key == "recoveryAlertDigests") for key in DIGEST_KEYS))


def singleton_pending(report, baseline):
    pending = digest_set(report, "recoveryPendingCaptureDigests")
    consumed = digest_set(baseline, "recoveryConsumedCaptureDigests", empty=True)
    processed = digest_set(baseline, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
    return (report.get("recoveryProcessingStopped") is True and report.get("recoveryCaptureIdentityMeasurementAvailable") is True
            and type(report.get("queueCount")) is int and report["queueCount"] == 1
            and type(report.get("recoveryQueueClaimedCount")) is int and report["recoveryQueueClaimedCount"] == 0
            and type(report.get("recoveryEncryptedQueueBytes")) is int and report["recoveryEncryptedQueueBytes"] > 0
            and pending is not None and len(pending) == 1 and consumed is not None and processed is not None
            and not pending.intersection(consumed | processed))


def pending_recovered(stopped, recovered):
    pending = digest_set(stopped, "recoveryPendingCaptureDigests")
    consumed = digest_set(recovered, "recoveryConsumedCaptureDigests")
    processed = digest_set(recovered, "recoverySuccessfullyProcessedCaptureDigests")
    return (pending is not None and len(pending) == 1 and consumed is not None and processed is not None
            and pending <= consumed and pending <= processed
            and recovered.get("recoveryCaptureIdentityMeasurementAvailable") is True
            and exact_int(recovered.get("queueCount"), 0) and exact_int(recovered.get("recoveryQueueClaimedCount"), 0)
            and digest_set(recovered, "recoveryPendingCaptureDigests", empty=True) == set())


def empty_unclaimed_queue(report):
    return (report.get("recoveryCaptureIdentityMeasurementAvailable") is True
            and exact_int(report.get("queueCount"), 0) and exact_int(report.get("recoveryQueueClaimedCount"), 0)
            and digest_set(report, "recoveryPendingCaptureDigests", empty=True) == set())


def safe_creator_cleanup(workers, *, helper_stopped, socket_absent):
    return helper_stopped and socket_absent and all(
        exact_int(worker.get("exitCode"), 0) and worker.get("shutdownPhase") == "shutdown-complete"
        and worker.get("groupStopped") is True for worker in workers)


def command(binary, root, name, *, selection=None, reader=None, version=None, host=None, active=True):
    result = [str(binary), "--store-directory", str(root / "protected-store"),
        "--acceptance-recovery-root", str(root), "--acceptance-recovery-token", str(root / "run-token"),
        "--acceptance-report", str(root / (name + "-report.json")),
        "--acceptance-finish-file", str(root / (name + "-finish")), "--acceptance-seconds", "120", "--acceptance-hold"]
    if selection is None:
        return result + ["--acceptance-vault-owner"]
    result += ["--acceptance-recovery-worker", "--acceptance-no-profile-catchup",
        "--codex-profile", PROFILE, "--codex-version", version, "--codex-home", str(selection["home"]),
        "--codex-executable", str(reader), "--codex-interface", "t3", "--codex-authorized-host", "t3",
        "--codex-t3-version", host, "--codex-authority", "codex-public-native-v1"]
    if active:
        result += ["--codex-active-thread", selection["native"]]
    return result


class OwnedProcess:
    """Drain bounded anonymous pipes; retain byte counts, never raw app diagnostics."""
    def __init__(self, arguments):
        self.process = subprocess.Popen(arguments, cwd=ROOT, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            env={key: value for key, value in os.environ.items() if not key.startswith("SPILLCHECK_")})
        self.selector = selectors.DefaultSelector()
        self.counts = {"stdoutBytes": 0, "diagnosticBytes": 0}
        for handle, label in ((self.process.stdout, "stdoutBytes"), (self.process.stderr, "diagnosticBytes")):
            os.set_blocking(handle.fileno(), False)
            self.selector.register(handle, selectors.EVENT_READ, label)

    def pump(self):
        for key, _ in self.selector.select(0):
            data = os.read(key.fd, 65536)
            if data:
                self.counts[key.data] += len(data)
                require(self.counts[key.data] <= 65536, "app-output-budget")
            else:
                self.selector.unregister(key.fileobj)

    def wait_report(self, path, predicate, gate, *, timeout=40):
        # Atomic replacement precedes chmod in the app's report writer. Retry an
        # unavailable snapshot briefly, but pass only a complete private read to
        # the predicate and never extend the caller's overall stage deadline.
        deadline = time.monotonic() + timeout
        unavailable_deadline = None
        report_observed = False
        while (now := time.monotonic()) < deadline:
            require(unavailable_deadline is None or now < unavailable_deadline, "private-report-snapshot-unavailable")
            self.pump()
            try:
                report = private_json(path)
            except GateFailure as error:
                if error.gate not in ("private-file-boundary", "private-file-changed"):
                    raise
                report_observed = True
            except FileNotFoundError:
                if not report_observed:
                    require(self.process.poll() is None, gate)
                    time.sleep(0.1)
                    continue
            except (OSError, json.JSONDecodeError):
                report_observed = True
            else:
                report_observed = True
                unavailable_deadline = None
                if predicate(report):
                    return report
                require(self.process.poll() is None, gate)
                time.sleep(0.1)
                continue
            now = time.monotonic()
            if unavailable_deadline is None:
                unavailable_deadline = now + 2
            require(now < unavailable_deadline, "private-report-snapshot-unavailable")
            require(self.process.poll() is None, gate)
            time.sleep(0.05)
        raise GateFailure(gate)

    def wait_exit(self, timeout=35):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None and time.monotonic() < deadline:
            self.pump()
            time.sleep(0.05)
        self.pump()
        require(self.process.poll() == 0, "owned-process-exit-unconfirmed")

    def stop(self):
        result = stop_group(self.process)
        try:
            self.pump()
        finally:
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        return result


def marker_free(directory):
    if not directory.is_dir():
        return False
    names = preflight.tree_files(directory)
    total = 0
    for name in names:
        descriptor = preflight.opened_file(directory, name)
        try:
            size = os.fstat(descriptor).st_size
            total += size
            require(total <= 64 * 1024 * 1024, "ciphertext-inspection-budget")
            tail = b""
            while data := os.read(descriptor, 65536):
                if TOKEN in tail + data:
                    return False
                tail = data[-len(TOKEN):]
        finally:
            os.close(descriptor)
    return True


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-directory", required=True, type=Path)
    parser.add_argument("--candidate-baseline-directory", type=Path,
                        help="Separate passed current-candidate baseline; original source proofs remain unchanged.")
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--expected-bundle-sha256", required=True)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--expected-reader-version", required=True)
    parser.add_argument("--expected-producer-version", required=True)
    parser.add_argument("--host-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--private-control", required=True, type=Path)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    source = args.source_directory.absolute()
    require(source == source.resolve(strict=True) and stat.S_ISDIR(source.lstat().st_mode)
            and source.stat().st_uid == os.getuid() and stat.S_IMODE(source.stat().st_mode) == 0o700, "private-source-directory-required")
    require(not args.output.exists() and not args.output.is_symlink()
            and not args.private_control.exists() and not args.private_control.is_symlink()
            and args.output.absolute() != args.private_control.absolute(), "new-report-paths-required")
    binding = load_bound_selection(args)
    selection = binding["selection"]
    app = args.app.resolve(strict=True)
    manifest = binding["manifest"]
    require(preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    reader = args.executable.resolve(strict=True)
    reader_hash = preflight.hash_file(reader.parent, reader.name, [0])
    with AcceptanceArtifacts("spillcheck-cx-recovery-", args.output) as artifacts:
        root = artifacts.directory
        run_token = os.urandom(32)
        write_new(root / "run-token", run_token)
        write_json(root / "candidate-build.json", manifest)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "sourceDirectory": str(source), "runTokenPath": str(root / "run-token"),
            "candidateBaselineDirectory": str(binding["baseline_directory"]) if binding["baseline_directory"] else None,
            "cleanupOwnerReport": str(root / "owner-report.json"), "loadedWorkersMayDeleteKeys": False,
            "cleanupAuthority": "original-fresh-vault-owner-only",
            "protectionCleanupReportField": "ownedProtectionCleanupPending",
            "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-T3-exact-source-synthetic-queue-restart",
            "candidateBundleSHA256": args.expected_bundle_sha256, "hostVersion": args.host_version,
            "readerVersion": args.expected_reader_version, "producerVersion": args.expected_producer_version,
            "selectedThreadCount": 1, "expectedOccurrencesByContentType": selection["counts"],
            "syntheticQueueAdmission": True, "providerHookDispatchEstablished": False,
            "providerSessionsCreated": 0, "providerConfigurationChanged": False, "sourceEnumerationPerformed": False,
            "savedProfileRecoveryEstablished": False, "loadedCheckpointProofEstablished": False,
            "upgradeRecoveryEstablished": False, "degradationRecoveryEstablished": False,
            "fullT3Acceptance": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "signedIndividualMarkerReceiptsVerified": False,
            "freshDetectorScanEstablished": False, "crashRecoveryEstablished": False,
            "checks": {}, "passed": False, **evidence_lineage(binding)}
        checks = report["checks"]
        artifacts.report = report
        owner = None
        workers = []
        stopped_groups = []
        helper_stopped = True
        final = {}
        phase = "reader-version"
        try:
            version = live.observe_version(reader, environment=dict(os.environ, CODEX_HOME=str(selection["home"])),
                directory=root, expected=args.expected_reader_version)
            checks["readerVersionObserved"] = version == args.expected_reader_version
            phase = "fresh-vault-owner"
            owner = OwnedProcess(command(binary, root, "owner"))
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            checks["freshOwnerCreatedVault"] = True
            phase = "baseline-worker"
            worker1 = OwnedProcess(command(binary, root, "worker1", selection=selection, reader=reader,
                version=version, host=args.host_version))
            workers.append(worker1)
            baseline = worker1.wait_report(root / "worker1-report.json", lambda value:
                collected(value, selection["counts"], args.expected_producer_version) and empty_unclaimed_queue(value),
                "baseline-not-collected")
            checks["baselineFiveTypesCollected"] = True
            # A normal finish drains any poll already racing the last zero-queue sample.
            # The separate paused worker has no active source that could refill that queue.
            write_new(root / "worker1-finish", b"finished\n")
            worker1.wait_exit()
            drained = private_json(root / "worker1-report.json")
            require(collected(drained, selection["counts"], args.expected_producer_version)
                    and empty_unclaimed_queue(drained) and inventory_unchanged(baseline, drained)
                    and drained.get("acceptancePhase") == "shutdown-complete"
                    and not (root / "protected-store/capture.sock").exists(), "baseline-shutdown-not-drained")
            checks["baselineWorkerExitedWithEmptyQueue"] = True
            phase = "paused-worker"
            require(owner.process.poll() is None, "fresh-owner-lost")
            write_new(root / "stop-processing", run_token)
            worker2 = OwnedProcess(command(binary, root, "worker2", selection=selection, reader=reader,
                version=version, host=args.host_version, active=False))
            workers.append(worker2)
            baseline = worker2.wait_report(root / "worker2-report.json", lambda value:
                collected(value, selection["counts"], args.expected_producer_version)
                and value.get("recoveryProcessingStopped") is True and empty_unclaimed_queue(value)
                and inventory_unchanged(drained, value), "processing-barrier-unavailable")
            checks["pausedWorkerLoadedSameVaultWithEmptyQueue"] = True
            phase = "synthetic-queue-admission"
            payload = json.dumps({"hook_event_name": "SpillcheckHistoryPoll", "session_id": selection["native"]}).encode()
            delivery_cleanup = {}
            helper_stopped = False
            try:
                code, output, _ = live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
                    "--agent", "codex", "--interface", "t3", "--profile-id", PROFILE],
                    environment=dict(os.environ), directory=ROOT, input_bytes=payload,
                    timeout=5, maximum_bytes=1024, cleanup_report=delivery_cleanup)
            finally:
                helper_stopped = delivery_cleanup.get("leaderExited") is True and delivery_cleanup.get("groupKillPermissionDenied") is False
            require(code == 0 and output.strip() == b"{}" and delivery_cleanup.get("leaderExited") is True
                    and not delivery_cleanup.get("groupKillPermissionDenied", False), "helper-lifetime-unconfirmed")
            # Helper exit 0 is deliberately not delivery proof; the encrypted queue is.
            pending = worker2.wait_report(root / "worker2-report.json", lambda value:
                singleton_pending(value, baseline) and inventory_unchanged(baseline, value), "exact-pending-poll-unavailable")
            checks["singleEncryptedUnclaimedPollAdmitted"] = True
            phase = "paused-worker-exit"
            write_new(root / "exit-with-pending", run_token)
            worker2.wait_exit()
            stopped = private_json(root / "worker2-report.json")
            require(singleton_pending(stopped, baseline)
                    and digest_set(stopped, "recoveryPendingCaptureDigests") == digest_set(pending, "recoveryPendingCaptureDigests")
                    and inventory_unchanged(baseline, stopped) and stopped.get("acceptancePhase") == "shutdown-complete"
                    and not (root / "protected-store/capture.sock").exists(), "pending-poll-not-preserved-at-exit")
            checks["pausedWorkerExitedWithExactPendingPoll"] = True
            (root / "stop-processing").unlink()
            (root / "exit-with-pending").unlink()
            phase = "recovery-worker"
            require(owner.process.poll() is None, "fresh-owner-lost")
            worker3 = OwnedProcess(command(binary, root, "worker3", selection=selection, reader=reader,
                version=version, host=args.host_version, active=False))
            workers.append(worker3)
            recovered = worker3.wait_report(root / "worker3-report.json", lambda value:
                collected(value, selection["counts"], args.expected_producer_version)
                and pending_recovered(stopped, value) and inventory_unchanged(baseline, value), "pending-poll-recovery-unavailable", timeout=60)
            checks["actualSignedWorkerRestart"] = len({worker.process.pid for worker in workers}) == 3 and worker2.process.poll() == 0
            checks["sameVaultManifestLoaded"] = manifest_digest(baseline) == manifest_digest(recovered)
            checks["exactPendingPollConsumedAndSuccessfullyProcessed"] = pending_recovered(stopped, recovered)
            checks["noNewOccurrencesReceiptsOrAlerts"] = inventory_unchanged(baseline, recovered)
            write_new(root / "worker3-finish", b"finished\n")
            worker3.wait_exit()
            final = private_json(root / "worker3-report.json")
            require(collected(final, selection["counts"], args.expected_producer_version)
                    and pending_recovered(stopped, final) and inventory_unchanged(baseline, final)
                    and final.get("acceptancePhase") == "shutdown-complete"
                    and not (root / "protected-store/capture.sock").exists(), "final-state-changed")
            checks["finalQueueEmptyWithoutGaps"] = True
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, GateFailure) else phase, failureCategory="controlled-run-failure")
        finally:
            collectors_stopped = True
            worker_shutdowns = []
            for index, worker in enumerate(workers, 1):
                # Ask a live worker to perform its normal passive-reader shutdown first.
                if worker.process.poll() is None:
                    try:
                        finish = root / ("worker%d-finish" % index)
                        if not finish.exists():
                            write_new(finish, b"finished\n")
                        worker.wait_exit()
                    except (OSError, RuntimeError):
                        pass
                group_stopped = False
                try:
                    cleanup = worker.stop()
                    stopped_groups.append(cleanup)
                    group_stopped = (worker.process.poll() is not None and cleanup.get("term_permission_denied") is False
                        and cleanup.get("kill_permission_denied") is False)
                    collectors_stopped = collectors_stopped and group_stopped
                except (OSError, RuntimeError):
                    collectors_stopped = False
                shutdown = {}
                try:
                    shutdown = private_json(root / ("worker%d-report.json" % index))
                except (OSError, ValueError, RuntimeError):
                    pass
                worker_shutdowns.append({"exitCode": worker.process.poll(), "shutdownPhase": shutdown.get("acceptancePhase"),
                    "groupStopped": group_stopped})
            # Only the original ready creator may delete keys, and only after workers stop.
            cleanup_authorized = safe_creator_cleanup(worker_shutdowns, helper_stopped=helper_stopped,
                socket_absent=not (root / "protected-store/capture.sock").exists())
            if owner is not None and cleanup_authorized and owner.process.poll() is None:
                try:
                    write_new(root / "owner-finish", run_token)
                    owner.wait_exit()
                except (OSError, RuntimeError):
                    pass
            owner_report = {}
            try:
                owner_report = private_json(root / "owner-report.json")
            except (OSError, ValueError, RuntimeError):
                pass
            if owner is not None:
                try:
                    stopped_groups.append(owner.stop())
                except (OSError, RuntimeError):
                    collectors_stopped = False
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            report["ownedProtectionCleanupPending"] = owner is not None and owner_report.get("cleanupPassed") is not True
            checks["creatorCleanupAuthorizedOnlyAfterNormalShutdown"] = cleanup_authorized
            checks["ownedProcessGroupsStopped"] = helper_stopped and collectors_stopped and bool(stopped_groups) and all(
                result.get("term_permission_denied") is False and result.get("kill_permission_denied") is False for result in stopped_groups)
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            try:
                checks["encryptedMarkerInspectionPassed"] = marker_free(root / "protected-store")
                checks["sourceSelectionAndProofsUnchanged"] = bound_evidence_unchanged(binding)
                checks["readerExecutableUnchanged"] = preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = preflight.check(manifest, app, ROOT)["consistent"]
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "syntheticOccurrencesByContentType": final.get("syntheticOccurrencesByContentType", {}),
                "syntheticOccurrenceCount": final.get("syntheticOccurrenceCount", 0),
                "syntheticSessionCount": final.get("syntheticSessionCount", 0),
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons", [])}
            required = {"readerVersionObserved", "freshOwnerCreatedVault", "baselineFiveTypesCollected",
                "baselineWorkerExitedWithEmptyQueue", "pausedWorkerLoadedSameVaultWithEmptyQueue",
                "singleEncryptedUnclaimedPollAdmitted", "pausedWorkerExitedWithExactPendingPoll", "actualSignedWorkerRestart",
                "sameVaultManifestLoaded", "exactPendingPollConsumedAndSuccessfullyProcessed", "noNewOccurrencesReceiptsOrAlerts",
                "finalQueueEmptyWithoutGaps", "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped",
                "noAppDiagnosticsOrOutput", "encryptedMarkerInspectionPassed", "sourceSelectionAndProofsUnchanged",
                "readerExecutableUnchanged", "candidateAndProductionInputsUnchanged"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(checks.values())
            report["signedSyntheticQueueRestartEstablished"] = report["passed"]
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(parse_arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "preflight-rejected", "signedAppLaunched": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
