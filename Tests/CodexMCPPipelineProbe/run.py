#!/usr/bin/env python3
"""One genuine fake MCP result scanned, cold-loaded, and reread through production.

Build separately before running. Imports and boundary tests never launch a
provider, scanner, app, or protection service. All cryptography is disposable.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


# Each dependency is an isolated instance. Historical runners and their fixtures
# remain unchanged, including the source-only producer's original module import.
producer = load("mcp_pipeline_producer", ROOT / "Tests/CodexMCPSourceProbe/run.py")
support = load("mcp_pipeline_lifecycle", ROOT / "Tests/CodexReviewRecoveryProbe/run.py")
fixture = load("mcp_pipeline_fixture", Path(__file__).with_name("fixture.py"))
producer.fixture = fixture
VERSION, PARSER, MAXIMUM = producer.VERSION, producer.PARSER, producer.MAXIMUM
ProbeFailure, require = producer.ProbeFailure, producer.require
decode, digest, private_bytes = producer.decode, producer.digest, producer.private_bytes
exclusive, write_json, environment = producer.exclusive, producer.write_json, producer.environment
SCANNER_SHA, RULES_SHA, DETECTOR = support.SCANNER_SHA, support.RULES_SHA, support.DETECTOR
AUTH_FILE = Path.home() / ".codex/auth.json"
STAGES = ("collect", "cold", "replay")
LIMITS = {"signedAcceptance", "keychainAcceptance", "desktopAcceptance", "t3Acceptance",
          "nativeChildCoverage", "providerUpgradeAcceptance", "fullHostAcceptance"}
COMMON_CHECKS = {"originalBindingVerified", "targetOccurrencesExact", "fullCurrentTargetReceipt",
                 "noFindingsOutsideTarget", "allReceiptsFull", "zeroTargetGaps"}
CLOSURE = {"readerClosedOrNotStarted", "storeClosed", "ciphertextVerified", "authAbsent"}
STAGE_CHECKS = {
    "collect": {"emptyBeforeAdmission", "sameResponseNativeBinding", "initialCaptureConsumed",
                "initialCaptureSuccessfullyProcessed"},
    "cold": {"coldInventoryUnchanged", "coldVerifiedBeforeReads", "noSourceReads", "noDetectorScans"},
    "replay": {"coldInventoryUnchanged", "coldVerifiedBeforeReads", "freshAuditRead", "sameResponseNativeBinding",
               "newCaptureConsumed", "newCaptureSuccessfullyProcessed", "inventoryUnchanged",
               "receiptsUnchanged", "noAdditionalDetectorScans"},
}
COUNTS = {"targetSegmentCount", "targetTextBytes", "targetOccurrenceCount", "valueCount", "occurrenceCount",
          "payloadRowCount", "targetReceiptCount", "analysisReceiptCount", "sourceCount", "targetGapCount",
          "gapCount", "queueCount", "detectorScanCalls", "threadReadCalls", "itemReadCalls", "turnReadCalls",
          "threadListCalls", "nativeTargetReadCount"}
DOMAINS = {"records", "occurrences", "obsoleteMarkers", "obsoleteAppearances", "alerts", "historicalNotifications",
           "unlocatedResults", "analysisReceipts", "locationReceipts", "strongSignalReceipts", "unlocatedReceipts",
           "sourceKinds", "sourceTimes", "conversationLabels", "valueLabels", "unlocatedLabels"}
COMMITMENTS = {"bindingDigest", "targetReceiptDigest", "targetSourceDigest", "targetResultDigest"}
FAILURE_STAGES = {"preflight", "opening-encrypted-store", "checking-cold-inventory", "processing-production-history",
                  "checking-native-result", "checking-full-receipts", "closing-reader", "closing-store", "checking-ciphertext"}
DEPENDENCIES = {"Package.swift", "Package.resolved", "Tests/CodexMCPSourceProbe/run.py",
    "Tests/CodexMCPSourceProbe/fixture.py", "Tests/CodexReviewRecoveryProbe/run.py", "Tests/CodexReviewProbe/run.py",
    "Tests/CodexPlanProbe/run.py", "Tests/CodexLive/run.py", "Tests/Support/processes.py",
    "Tests/CodexMCPPipelineProbe/run.py", "Tests/CodexMCPPipelineProbe/fixture.py",
    "Tests/CodexMCPPipelineProbe/test_boundary.py", "Tests/CodexMCPPipelineProbe/README.md"}


def fixture_segments():
    result = fixture.RESULT
    opaque = result["structuredContent"]
    return {"/result/content/0/text": result["content"][0]["text"],
        **{"/result/structuredContent/" + key: opaque[key] for key in ("type", "caption", "printed", "error", "status")},
        **{"/result/structuredContent/content/0/" + key.replace("~", "~0").replace("/", "~1"): value
           for key, value in opaque["content"][0].items()},
        "/result/structuredContent/resource/blob": opaque["resource"]["blob"]}


TARGET_BYTES = sum(len(text.encode()) for text in fixture_segments().values())
base_stop_group = producer.processes.stop_group


def stop_producer(process, grace=.2):
    result = base_stop_group(process, grace=grace)
    require(support.group_absent(process.pid), "producer-group-shutdown-unconfirmed")
    return result


producer.processes.stop_group = stop_producer
producer.live.bounded = support.bounded


def source_hashes():
    names = set(DEPENDENCIES)
    for base in ("Sources", "Tests/SpillcheckCoreTests", "Tests/Fixtures"):
        names.update(str(path.relative_to(ROOT)) for path in (ROOT / base).rglob("*") if path.is_file())
    require(all(not (ROOT / name).is_symlink() for name in names), "source-symlink")
    return {name: digest((ROOT / name).read_bytes()) for name in sorted(names)}


def build(args):
    os.umask(0o077)
    require(not args.build_binding.exists() and not args.build_binding.is_symlink(), "build-binding-already-exists")
    before, cleanup = source_hashes(), {}
    code, output, _ = support.bounded(["/usr/bin/swift", "build", "--build-tests", "--scratch-path", str(args.scratch_path)],
        environment=support.clean_env(), directory=ROOT, timeout=600, maximum_bytes=8 * 1024 * 1024,
        cleanup_report=cleanup, merge_errors=True)
    exclusive(args.build_binding.with_suffix(".build.log"), output)
    require(code == 0 and support.stopped(cleanup), "test-build-failed")
    require(source_hashes() == before, "build-sources-changed")
    value = {"schemaVersion": 1, "parserContract": PARSER, "scratchPath": str(args.scratch_path.resolve()),
        "sources": before, "artifacts": support.artifact_hashes(args.scratch_path), "inputsStableAcrossBuild": True}
    write_json(args.build_binding, value)
    print(json.dumps({"built": True, "sourceCount": len(before), "artifactCount": len(value["artifacts"])}))
    return 0


def verify_build(args):
    raw = private_bytes(args.build_binding)
    value = decode(raw)
    require(value.get("schemaVersion") == 1 and value.get("inputsStableAcrossBuild") is True
        and value.get("parserContract") == PARSER and value.get("scratchPath") == str(args.scratch_path.resolve()),
        "build-binding-mismatch")
    require(value.get("sources") == source_hashes(), "build-sources-changed")
    require(value.get("artifacts") == support.artifact_hashes(args.scratch_path), "compiled-test-artifacts-changed")
    return digest(raw)


def keyed_digest(value):
    if not isinstance(value, str) or len(value) != 44:
        return False
    try:
        raw = base64.b64decode(value, validate=True)
        return len(raw) == 32 and base64.b64encode(raw).decode() == value
    except ValueError:
        return False


def inventory_valid(value):
    if not isinstance(value, dict) or set(value) != {"counts", "digests", "schemaVersion", "nextValueLabel", "payloadCount"}:
        return False
    if not all(type(value.get(key)) is int and value[key] >= 0 for key in ("schemaVersion", "nextValueLabel", "payloadCount")):
        return False
    counts, digests = value["counts"], value["digests"]
    if not isinstance(counts, dict) or not isinstance(digests, dict) or set(counts) != DOMAINS or set(digests) != DOMAINS:
        return False
    return all(type(counts[key]) is int and 0 <= counts[key] <= 256
        and isinstance(digests[key], list) and len(digests[key]) == counts[key]
        and all(keyed_digest(x) for x in digests[key]) and digests[key] == sorted(set(digests[key])) for key in DOMAINS)


def public_stage(value):
    if not isinstance(value, dict):
        return {}
    booleans = COMMON_CHECKS | CLOSURE | LIMITS | {"passed", "historyClientCreated", "readerVersionMeasured", "readerShutdownNotNeeded"}
    result = {key: value[key] for key in booleans if type(value.get(key)) is bool}
    if value.get("readerShutdown") is None and "readerShutdown" in value:
        result["readerShutdown"] = None
    elif type(value.get("readerShutdown")) is bool:
        result["readerShutdown"] = value["readerShutdown"]
    result.update({key: value[key] for key in COUNTS | {"schemaVersion"}
                   if type(value.get(key)) is int and 0 <= value[key] <= 1_000_000})
    strings = {"stage": set(STAGES), "parserContract": {PARSER}, "readerVersion": {VERSION},
        "producerVersion": {VERSION}, "detectorVersion": {DETECTOR}, "failureStage": FAILURE_STAGES,
        "cryptoScope": {"disposable-deterministic-test-keys"}, "versionBinding": {"same-response", "saved-evidence"}}
    for key, allowed in strings.items():
        if isinstance(value.get(key), str) and value[key] in allowed:
            result[key] = value[key]
    for key in ("scannerSHA256", "rulesSHA256"):
        if isinstance(value.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", value[key]):
            result[key] = value[key]
    for key in COMMITMENTS:
        if keyed_digest(value.get(key)):
            result[key] = value[key]
    if value.get("observedReaderVersions") in ([], [VERSION]):
        result["observedReaderVersions"] = value["observedReaderVersions"]
    if value.get("gapReasons") == []:
        result["gapReasons"] = []
    if inventory_valid(value.get("inventory")):
        result["inventory"] = value["inventory"]
    checks = value.get("checks")
    if isinstance(checks, dict):
        result["checks"] = {key: checks[key] for key in set().union(*STAGE_CHECKS.values()) if type(checks.get(key)) is bool}
    return result


def stage_gate(value, stage):
    report = public_stage(value)
    if not (report.get("schemaVersion") == 1 and report.get("stage") == stage and report.get("passed") is True
        and all(report.get(key) is True for key in COMMON_CHECKS | CLOSURE)
        and all(report.get(key) is False for key in LIMITS)
        and all(report.get("checks", {}).get(key) is True for key in STAGE_CHECKS[stage])
        and report.get("parserContract") == PARSER and report.get("readerVersion") == report.get("producerVersion") == VERSION
        and report.get("detectorVersion") == DETECTOR and report.get("scannerSHA256") == SCANNER_SHA
        and report.get("rulesSHA256") == RULES_SHA and report.get("cryptoScope") == "disposable-deterministic-test-keys"
        and set(COUNTS) <= set(report) and set(COMMITMENTS) <= set(report)
        and report.get("gapReasons") == [] and inventory_valid(report.get("inventory"))):
        return False
    fixed = {"targetSegmentCount": 11, "targetTextBytes": TARGET_BYTES, "targetOccurrenceCount": 4, "valueCount": 1,
        "occurrenceCount": 4, "payloadRowCount": 6, "targetReceiptCount": 1, "gapCount": 0, "targetGapCount": 0,
        "queueCount": 0, "threadListCalls": 0}
    if not all(report[key] == count for key, count in fixed.items()):
        return False
    count = report["sourceCount"]
    if not (1 <= count <= 256 and report["analysisReceiptCount"] == count):
        return False
    inv = report["inventory"]
    expected = {"records": 1, "occurrences": 4, "analysisReceipts": count, "sourceKinds": count,
                "sourceTimes": count, "locationReceipts": 4, "conversationLabels": 1, "valueLabels": 1}
    empty = {"obsoleteMarkers", "obsoleteAppearances", "unlocatedResults", "unlocatedReceipts", "unlocatedLabels"}
    if not (inv["payloadCount"] == 6 and all(inv["counts"][key] == n for key, n in expected.items())
        and all(inv["counts"][key] == 0 for key in empty)
        and report["targetReceiptDigest"] in inv["digests"]["analysisReceipts"]
        and report["targetSourceDigest"] in inv["digests"]["sourceKinds"]):
        return False
    if stage == "cold":
        return (report.get("historyClientCreated") is False and report.get("readerVersionMeasured") is False
            and report.get("observedReaderVersions") == [] and report.get("readerShutdown") is None
            and report.get("readerShutdownNotNeeded") is True and report.get("versionBinding") == "saved-evidence"
            and all(report[key] == 0 for key in ("threadReadCalls", "itemReadCalls", "turnReadCalls", "nativeTargetReadCount", "detectorScanCalls")))
    return (report.get("historyClientCreated") is True and report.get("readerVersionMeasured") is True
        and report.get("observedReaderVersions") == [VERSION] and report.get("readerShutdown") is True
        and report.get("readerShutdownNotNeeded") is False and report.get("versionBinding") == "same-response"
        and report["threadReadCalls"] > 0 and report["itemReadCalls"] > 0 and report["nativeTargetReadCount"] > 0
        and report["detectorScanCalls"] == (count if stage == "collect" else 0))


def stable_stages(stages):
    if len(stages) != 3 or not all(stage_gate(value, stage) for value, stage in zip(stages, STAGES)):
        return False
    first = stages[0]
    return all(value["inventory"] == first["inventory"]
        and all(value[key] == first[key] for key in COMMITMENTS) for value in stages[1:])


def source_files(home):
    # This is a newly created private provider home; no user history is enumerated.
    sessions = home / "sessions"
    require(sessions.is_dir() and not sessions.is_symlink(), "owned-native-source-unavailable")
    paths = sorted(sessions.rglob("*.jsonl"))
    require(1 <= len(paths) <= 4, "owned-native-source-count")
    result = {}
    for path in paths:
        require(not any(parent.is_symlink() for parent in path.parents if parent.is_relative_to(home)), "owned-source-symlink")
        result[str(path.relative_to(home))] = digest(private_bytes(path, MAXIMUM))
    return result


def source_commitment(sources):
    return digest(json.dumps(sources, sort_keys=True, separators=(",", ":")).encode())


def recheck(args, build_sha, executable, executable_sha, scanner, rules, home=None, sources=None):
    require(verify_build(args) == build_sha and digest(executable.read_bytes()) == executable_sha
        and digest(scanner.read_bytes()) == SCANNER_SHA and digest(rules.read_bytes()) == RULES_SHA, "pipeline-inputs-changed")
    if sources is not None:
        require(source_files(home) == sources, "owned-native-source-changed")


def auth_absent(home):
    return not (home / "auth.json").exists() and not (home / "auth.json").is_symlink()


def run(args):
    os.umask(0o077)
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.model) is not None, "invalid-model")
    require(args.auth_file == AUTH_FILE, "authorized-auth-path-required")
    require(not args.report.exists() and not args.report.is_symlink(), "report-already-exists")
    build_sha = verify_build(args)
    args.private_control.mkdir(mode=0o700, parents=False, exist_ok=False)
    executable = args.executable.expanduser().resolve(strict=True)
    scanner, rules = args.scanner_executable.resolve(strict=True), args.scanner_rules.resolve(strict=True)
    require(digest(scanner.read_bytes()) == SCANNER_SHA and digest(rules.read_bytes()) == RULES_SHA, "scanner-artifacts-mismatch")
    root = Path(tempfile.mkdtemp(prefix="spillcheck-native-mcp-pipeline-", dir="/private/tmp")).resolve()
    home, work = root / "home", root / "work"
    home.mkdir(mode=0o700); work.mkdir(mode=0o700)
    hi, ri = home.stat(), root.stat()
    home_identity, root_identity = (hi.st_dev, hi.st_ino), (ri.st_dev, ri.st_ino)
    lifetime = {"producerStopped": True, "readerStopped": True, "versionProcessStopped": True,
                "providerLaunchCount": 0, "mcpServerStopped": True}
    report = {"schemaVersion": 1, "passed": False, "fixture": "fake-native-mcp-production-pipeline", "model": args.model,
        "workerStages": [], "buildBindingSHA256": build_sha, "authRemoved": False, "originalAuthUnchanged": False,
        "ownedRootRemoved": False, "sourceInputsStable": False, **{key: False for key in LIMITS}}
    original = None
    try:
        executable_sha = digest(executable.read_bytes())
        report.update(executableSHA256=executable_sha, sourceInputSHA256=source_hashes())
        cleanup = {}
        lifetime["versionProcessStopped"] = False
        try:
            version = producer.live.observe_version(str(executable), environment=environment(root, home), directory=work,
                expected=VERSION, cleanup_report=cleanup)
        finally:
            lifetime["versionProcessStopped"] = support.stopped(cleanup)
        require(version == VERSION and lifetime["versionProcessStopped"], "reader-version-mismatch")
        recheck(args, build_sha, executable, executable_sha, scanner, rules)
        authentication = private_bytes(args.auth_file, 1024 * 1024)
        original = digest(authentication)
        exclusive(home / "auth.json", authentication)
        del authentication
        exclusive(home / "config.toml", producer.fixture_configuration(args.model, Path(__file__).with_name("fixture.py").resolve(),
            args.private_control.resolve()))
        lifetime["mcpServerStopped"] = False
        observed, production = producer.produce(executable, args.model, root, home, work, lifetime, args.private_control)
        report["producer"] = production
        lifetime["mcpServerStopped"] = producer.confirm_mcp_stopped(args.private_control, lifetime, True)
        require(lifetime["producerStopped"] and lifetime["mcpServerStopped"], "producer-cleanup-unconfirmed")
        report["authRemoved"] = producer.cleanup_auth(home, home_identity)
        require(report["authRemoved"] and auth_absent(home), "auth-removal-required-before-workers")
        sources = source_files(home)
        report["ownedSourceCommitment"] = source_commitment(sources)
        for stage in STAGES:
            recheck(args, build_sha, executable, executable_sha, scanner, rules, home, sources)
            require(auth_absent(home), "auth-removal-required-before-workers")
            lifetime["mcpServerStopped"] = producer.confirm_mcp_stopped(args.private_control, lifetime, True)
            require(lifetime["mcpServerStopped"], "mcp-pre-worker-shutdown-unconfirmed")
            env = support.clean_env(); env.update(environment(root, home))
            private_report = args.private_control / (stage + "-report.json")
            fields = {"STAGE": stage, "ROOT": str(root), "HOME": str(home), "THREAD": observed.thread,
                "TURN": observed.turn, "ITEM": observed.mcp["itemID"], "EXECUTABLE": str(executable),
                "REPORT": str(private_report), "SCANNER_EXECUTABLE": str(scanner), "SCANNER_RULES": str(rules)}
            env.update({"SPILLCHECK_MCP_PIPELINE_" + key: value for key, value in fields.items()})
            cleanup = {}; lifetime["readerStopped"] = False
            try:
                code, _, _ = support.bounded(["/usr/bin/swift", "test", "--scratch-path", str(args.scratch_path), "--skip-build",
                    "--no-parallel", "--filter", "CodexMCPPipelineLiveTests"], environment=env, directory=ROOT,
                    timeout=180, maximum_bytes=MAXIMUM, cleanup_report=cleanup)
            finally:
                lifetime["readerStopped"] = support.stopped(cleanup)
                lifetime["mcpServerStopped"] = False
                lifetime["mcpServerStopped"] = producer.confirm_mcp_stopped(args.private_control, lifetime, True)
                recheck(args, build_sha, executable, executable_sha, scanner, rules, home, sources)
            witness = decode(private_bytes(private_report)) if private_report.is_file() else {}
            report["workerStages"].append(public_stage(witness))
            require(code == 0 and lifetime["readerStopped"] and lifetime["mcpServerStopped"], "pipeline-worker-failed")
            require(stage_gate(witness, stage), "pipeline-worker-proof-incomplete")
        require(stable_stages(report["workerStages"]), "cold-replay-state-mismatch")
        recheck(args, build_sha, executable, executable_sha, scanner, rules, home, sources)
        report.update(sourceInputsStable=True, passed=True, workerProcessCount=3, coldStatePreservationEstablished=True,
            detectorReceiptAcceptance=True, actualSourceReplayEstablished=True)
    except (ProbeFailure, support.ProbeFailure) as error:
        report["failureCategory"] = str(error)
    except Exception:
        report["failureCategory"] = "pipeline-probe-unavailable"
    finally:
        try:
            report["fixtureDiagnostic"] = producer.fixture_diagnostic(args.private_control)
        except Exception:
            report["fixtureDiagnostic"] = {"measured": False, "unavailable": True}
        try:
            lifetime["mcpServerStopped"] = producer.confirm_mcp_stopped(args.private_control, lifetime)
        except Exception:
            lifetime["mcpServerStopped"] = False
        producer.finish_cleanup(report, lifetime, original_path=args.auth_file, original_hash=original,
            root=root, home=home, root_identity=root_identity, home_identity=home_identity)
        report.update(lifetime)
        report["passed"] = report["passed"] and all(report[key] is True for key in (
            "authRemoved", "originalAuthUnchanged", "ownedRootRemoved", "producerStopped", "readerStopped",
            "versionProcessStopped", "mcpServerStopped", "sourceInputsStable"))
        report["privateCleanupPending"] = not report["ownedRootRemoved"]
        if not report["ownedRootRemoved"]:
            write_json(args.private_control / "cleanup-handoff.json", {"ownedRoot": str(root),
                "authenticationMayRemain": not report["authRemoved"], **lifetime})
        write_json(args.report, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "run"))
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--build-binding", type=Path, required=True)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--auth-file", type=Path)
    parser.add_argument("--model", default="gpt-6-astra")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--private-control", type=Path)
    parser.add_argument("--scanner-executable", type=Path, default=ROOT / ".build/scanner/betterleaks")
    parser.add_argument("--scanner-rules", type=Path, default=ROOT / ".build/scanner/betterleaks.toml")
    args = parser.parse_args(argv)
    if args.action == "run" and any(getattr(args, key) is None for key in ("executable", "auth_file", "report", "private_control")):
        parser.error("run requires executable, auth-file, report, and private-control")
    return args


if __name__ == "__main__":
    options = arguments()
    try:
        raise SystemExit(build(options) if options.action == "build" else run(options))
    except (ProbeFailure, support.ProbeFailure):
        print(json.dumps({"passed": False, "failureCategory": "preflight-or-handoff-unavailable", "cleanupEstablished": False}))
        raise SystemExit(1)
