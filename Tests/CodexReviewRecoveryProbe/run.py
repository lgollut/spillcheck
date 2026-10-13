#!/usr/bin/env python3
"""Fake native review through the production detector and encrypted queue.

Build first, then run three separate worker processes against one owned provider
home. This does not exercise Keychain, a signed app, desktop, T3, or native-child
input. Importing this module never launches a process or reads credentials.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# A private module instance keeps the earlier source-only probe unchanged.
producer = load("recovery_review_producer", ROOT / "Tests/CodexReviewProbe/run.py")
common = producer.common
VERSION, PARSER, MAXIMUM = producer.VERSION, producer.PARSER, producer.MAXIMUM
ProbeFailure, require = producer.ProbeFailure, producer.require
decode, digest, private_bytes = producer.decode, producer.digest, producer.private_bytes
write_json, exclusive, environment = producer.write_json, producer.exclusive, producer.environment
FAKE_TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
producer.INSTRUCTIONS = producer.INSTRUCTIONS.replace(
    "the supplied fictional addition is correct.",
    "the supplied fictional addition is correct. Fake test credential " + FAKE_TOKEN + ".")
SCANNER_SHA = "70d2103c2915aababa0e1eea121bd3db0ff0da86bee40ddc6f5982181acaf6d0"
RULES_SHA = "a8f553eb634ac3c5c1ca3f0dc95e2b8abdea7d14b622604c5af07f30ce7926ef"
DETECTOR = "betterleaks-1.9.0+stdlib-1+leakret-native-1+mapping-1"
STAGES = ("queue", "resume", "replay")
FAILURE_STAGES = {"preflight", "opening-encrypted-store", "checking-cold-pending", "checking-cold-inventory",
                  "binding-original-native-sources", "processing-production-history", "checking-full-receipts-and-recovery",
                  "closing-reader", "closing-store", "checking-ciphertext"}
LIMITS = {"signedAcceptance", "keychainAcceptance", "desktopAcceptance", "t3Acceptance",
          "nativeChildCoverage", "providerUpgradeAcceptance"}
COMMON_CHECKS = {"originalBindingVerified", "nativeInputRootVerified", "exactOwnedSourceOnly", "authAbsent",
                 "scannerArtifactsVerified", "readerShutdown", "storeClosed", "ciphertextVerified"}
COUNTS = {"threadReadCalls", "itemReadCalls", "turnReadCalls", "threadListCalls", "detectorScanCalls",
          "analysisReceiptCount", "occurrenceCount", "sourceCount", "valueCount", "queueCount", "gapCount",
          "cursorCalls", "exactTurnCalls"}
# The witness contract is deliberately closed. Missing proof never defaults true.
STAGE_CHECKS = {
    "queue": {"emptyBeforeAdmission", "inspectionPageRead", "pendingInspectionDurable"},
    "resume": {"pendingIdentityUnchanged", "pendingConsumed", "pendingSuccessfullyProcessed",
               "originalReceiptsFull", "bothPresentationGapsResolved", "noPresentationCopies"},
    "replay": {"coldInventoryUnchanged", "freshAuditRead", "inventoryUnchanged", "receiptsUnchanged",
               "noAdditionalDetectorScans", "bothPresentationGapsResolved", "noPresentationCopies"},
}


def group_absent(pgid, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(.02)


base_stop_group = producer.processes.stop_group


def stop_producer(process, grace=.2):
    result = base_stop_group(process, grace=grace)
    require(group_absent(process.pid), "producer-group-shutdown-unconfirmed")
    return result


def bounded(command, *, environment, directory, input_bytes=b"", timeout=120,
            maximum_bytes=MAXIMUM, cleanup_report=None, merge_errors=False):
    selector, output = selectors.DefaultSelector(), bytearray()
    try:
        child = subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except BaseException:
        selector.close()
        raise
    started, total = time.monotonic(), 0
    try:
        # All calls in this runner have empty input. Interactive production uses
        # the separately reviewed ReviewProbe RPC pump.
        require(input_bytes == b"", "unexpected-worker-input")
        child.stdin.close()
        for stream in (child.stdout, child.stderr):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            require(time.monotonic() - started <= timeout, "worker-deadline")
            for key, _ in selector.select(.05):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                total += len(chunk)
                require(total <= maximum_bytes, "worker-output-budget")
                if key.fileobj is child.stdout or merge_errors:
                    output.extend(chunk)
        return child.wait(timeout=2), bytes(output), round((time.monotonic() - started) * 1000, 1)
    finally:
        confirmed, denied = False, False
        try:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                denied = True
            child.wait(timeout=5)
            confirmed = group_absent(child.pid)
        finally:
            if cleanup_report is not None:
                cleanup_report.update(leaderExited=child.poll() is not None,
                    groupKillPermissionDenied=denied, ownedGroupAbsent=confirmed)
            selector.close()
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()


# Restrict stronger teardown to this private probe instance. Do not change the
# earlier source-only acceptance code or its retained evidence.
producer.processes.stop_group = stop_producer
producer.live.bounded = bounded


def source_hashes():
    names = {"Package.swift", "Package.resolved", "Tests/Support/processes.py", "Tests/CodexLive/run.py",
             "Tests/CodexPlanProbe/run.py", "Tests/CodexReviewProbe/run.py",
             "Tests/CodexReviewRecoveryProbe/run.py"}
    for base in ("Sources", "Tests/SpillcheckCoreTests", "Tests/Fixtures"):
        names.update(str(p.relative_to(ROOT)) for p in (ROOT / base).rglob("*") if p.is_file())
    require(all(not (ROOT / name).is_symlink() for name in names), "source-symlink")
    return {name: digest((ROOT / name).read_bytes()) for name in sorted(names)}


def artifact_hashes(scratch):
    scratch = scratch.resolve(strict=True)
    products = (scratch / "debug").resolve(strict=True)
    require(products.is_relative_to(scratch), "compiled-test-products-outside-build")
    bundles = list(products.glob("*.xctest"))
    require(len(bundles) == 1 and bundles[0].name in {"SpillcheckPackageTests.xctest", "SpillcheckCoreTests.xctest"},
            "compiled-test-bundle-required")
    resources = products / "Spillcheck_SpillcheckCoreTests.bundle"
    require(resources.is_dir(), "compiled-test-resources-required")
    runtime_roots = bundles + list(products.glob("*.bundle"))
    if (products / "PackageFrameworks").is_dir():
        runtime_roots.append(products / "PackageFrameworks")
    paths = [p for base in runtime_roots for p in base.rglob("*") if p.is_file()]
    paths += list(products.glob("*.dylib"))
    require(paths and all(not p.is_symlink() for p in paths), "compiled-test-artifact-boundary")
    return {str(p.relative_to(scratch)): digest(p.read_bytes()) for p in sorted(paths)}


def clean_env():
    return {key: value for key, value in os.environ.items() if not key.startswith("SPILLCHECK_")}


def build(args):
    os.umask(0o077)
    require(not args.build_binding.exists() and not args.build_binding.is_symlink(), "build-binding-already-exists")
    before = source_hashes()
    cleanup = {}
    code, output, _ = producer.live.bounded(["/usr/bin/swift", "build", "--build-tests", "--scratch-path",
        str(args.scratch_path)], environment=clean_env(), directory=ROOT, timeout=600,
        maximum_bytes=8 * 1024 * 1024, cleanup_report=cleanup, merge_errors=True)
    exclusive(args.build_binding.with_suffix(".build.log"), output)
    require(code == 0 and stopped(cleanup), "test-build-failed")
    require(source_hashes() == before, "build-sources-changed")
    binding = {"schemaVersion": 1, "parserContract": PARSER, "scratchPath": str(args.scratch_path.resolve()),
               "sources": before, "artifacts": artifact_hashes(args.scratch_path), "inputsStableAcrossBuild": True}
    write_json(args.build_binding, binding)
    print(json.dumps({"built": True, "sourceCount": len(before), "artifactCount": len(binding["artifacts"])}))
    return 0


def stopped(cleanup):
    return (cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
            and cleanup.get("ownedGroupAbsent") is True)


def verify_build(args):
    binding = decode(private_bytes(args.build_binding))
    require(binding.get("schemaVersion") == 1 and binding.get("inputsStableAcrossBuild") is True
            and binding.get("parserContract") == PARSER
            and binding.get("scratchPath") == str(args.scratch_path.resolve()), "build-binding-mismatch")
    require(binding.get("sources") == source_hashes(), "build-sources-changed")
    require(binding.get("artifacts") == artifact_hashes(args.scratch_path), "compiled-test-artifacts-changed")
    return digest(private_bytes(args.build_binding))


def public_stage(value):
    if not isinstance(value, dict):
        return {}
    result = {key: value[key] for key in COMMON_CHECKS | LIMITS | {"passed"} if type(value.get(key)) is bool}
    result.update({key: value[key] for key in COUNTS | {"schemaVersion", "inputTextBytes", "outputTextBytes"}
                   if type(value.get(key)) is int and 0 <= value[key] <= 1_000_000})
    expected_strings = {"parserContract": {PARSER}, "readerVersion": {VERSION}, "producerVersion": {VERSION},
                        "stage": set(STAGES), "detectorVersion": {DETECTOR},
                        "queueInspectionKind": {"entry", "exit"},
                        "cryptoScope": {"disposable-deterministic-test-keys"}, "failureStage": FAILURE_STAGES}
    for key, allowed in expected_strings.items():
        if isinstance(value.get(key), str) and value[key] in allowed:
            result[key] = value[key]
    for key in ("inputTextSHA256", "outputTextSHA256", "scannerSHA256", "rulesSHA256"):
        if isinstance(value.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", value[key]):
            result[key] = value[key]
    checks = value.get("checks")
    if isinstance(checks, dict):
        allowed = set().union(*STAGE_CHECKS.values())
        result["checks"] = {key: checks[key] for key in allowed if type(checks.get(key)) is bool}
    return result


def stage_gate(value, stage, original_input, original_output):
    report = public_stage(value)
    if not (report.get("passed") is True and report.get("schemaVersion") == 1 and report.get("stage") == stage
            and all(report.get(key) is True for key in COMMON_CHECKS)
            and all(report.get(key) is False for key in LIMITS)
            and all(report.get("checks", {}).get(key) is True for key in STAGE_CHECKS[stage])
            and report.get("parserContract") == PARSER
            and report.get("readerVersion") == report.get("producerVersion") == VERSION
            and report.get("detectorVersion") == DETECTOR and report.get("scannerSHA256") == SCANNER_SHA
            and report.get("rulesSHA256") == RULES_SHA
            and report.get("cryptoScope") == "disposable-deterministic-test-keys"
            and report.get("threadListCalls") == 0 and all(key in report for key in COUNTS)
            and report.get("threadReadCalls", 0) >= 1 and report.get("itemReadCalls", 0) >= 1):
        return False
    for prefix, original in (("input", original_input), ("output", original_output)):
        if report.get(prefix + "TextSHA256") != original["textSHA256"] or report.get(prefix + "TextBytes") != original["textBytes"]:
            return False
    if stage == "queue":
        measured = ((report.get("queueInspectionKind") == "entry" and report["turnReadCalls"] >= 1)
                    or (report.get("queueInspectionKind") == "exit" and report["itemReadCalls"] >= 2))
        return (measured and report["queueCount"] == 1 and 1 <= report["gapCount"] <= 2
                and report["detectorScanCalls"] <= 2
                and all(report[key] <= 2 for key in ("analysisReceiptCount", "occurrenceCount", "sourceCount"))
                and report["valueCount"] <= 1)
    return (all(report[key] == value for key, value in {"analysisReceiptCount": 2, "occurrenceCount": 2,
            "sourceCount": 2, "valueCount": 1, "queueCount": 0, "gapCount": 0}.items())
            and report["itemReadCalls"] >= 2 and report["turnReadCalls"] >= 1
            and report["cursorCalls"] > 0 and report["exactTurnCalls"] > 0
            and (stage != "replay" or report["detectorScanCalls"] == 0))


def run(args):
    os.umask(0o077)
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.model) is not None, "invalid-model")
    require(not args.report.exists() and not args.report.is_symlink(), "report-already-exists")
    build_sha = verify_build(args)
    args.private_control.mkdir(mode=0o700, parents=False, exist_ok=False)
    executable = args.executable.expanduser().resolve(strict=True)
    scanner, rules = args.scanner_executable.resolve(strict=True), args.scanner_rules.resolve(strict=True)
    require(digest(scanner.read_bytes()) == SCANNER_SHA and digest(rules.read_bytes()) == RULES_SHA,
            "scanner-artifacts-mismatch")
    root = Path(tempfile.mkdtemp(prefix="spillcheck-native-review-recovery-", dir="/private/tmp")).resolve()
    home, work = root / "home", root / "work"
    home.mkdir(mode=0o700); work.mkdir(mode=0o700)
    hi, ri = home.stat(), root.stat()
    identity, root_identity = (hi.st_dev, hi.st_ino), (ri.st_dev, ri.st_ino)
    lifetime = {"producerStopped": True, "readerStopped": True, "versionProcessStopped": True, "providerLaunchCount": 0}
    report = {"schemaVersion": 1, "passed": False, "fixture": "fake-native-review-production-recovery",
              "model": args.model, "workerStages": [], "buildBindingSHA256": build_sha,
              "authRemoved": False, "originalAuthUnchanged": False, "ownedRootRemoved": False,
              **{key: False for key in LIMITS}}
    original = None
    try:
        executable_hash = digest(executable.read_bytes())
        cleanup = {}
        lifetime["versionProcessStopped"] = False
        try:
            version = producer.live.observe_version(str(executable), environment=environment(root, home), directory=work,
                                                     expected=VERSION, cleanup_report=cleanup)
        finally:
            lifetime["versionProcessStopped"] = stopped(cleanup)
        require(version == VERSION and lifetime["versionProcessStopped"], "reader-version-mismatch")
        authentication = private_bytes(args.auth_file, 1024 * 1024)
        original = digest(authentication)
        exclusive(home / "auth.json", authentication)
        del authentication
        exclusive(home / "config.toml", (f'model = "{args.model}"\nreview_model = "{args.model}"\nweb_search = "disabled"\n'
            '[features]\nshell_tool = false\n[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())
        observed, production = producer.produce(executable, args.model, root, home, work, lifetime, args.private_control)
        report["producer"] = production
        require(lifetime["producerStopped"], "producer-cleanup-unconfirmed")
        report["authRemoved"] = common.cleanup_auth(home, identity)
        require(report["authRemoved"], "auth-removal-required-before-workers")
        for stage in STAGES:
            require(verify_build(args) == build_sha and digest(executable.read_bytes()) == executable_hash,
                    "recovery-inputs-changed")
            env = clean_env()
            env.update(environment(root, home))
            private_report = args.private_control / (stage + "-report.json")
            fields = {"STAGE": stage, "ROOT": str(root), "HOME": str(home), "THREAD": observed.thread,
                      "TURN": observed.turn, "EXECUTABLE": str(executable), "REPORT": str(private_report),
                      "SCANNER_EXECUTABLE": str(scanner), "SCANNER_RULES": str(rules),
                      "INPUT_SHA256": observed.input_message["textSHA256"], "INPUT_BYTES": str(observed.input_message["textBytes"]),
                      "OUTPUT_SHA256": observed.message["textSHA256"], "OUTPUT_BYTES": str(observed.message["textBytes"])}
            env.update({"SPILLCHECK_REVIEW_RECOVERY_" + key: value for key, value in fields.items()})
            cleanup = {}
            lifetime["readerStopped"] = False
            try:
                code, _, _ = producer.live.bounded(["/usr/bin/swift", "test", "--scratch-path", str(args.scratch_path),
                    "--skip-build", "--no-parallel", "--filter", "CodexReviewRecoveryLiveTests"], environment=env,
                    directory=ROOT, timeout=180, maximum_bytes=MAXIMUM, cleanup_report=cleanup)
            finally:
                lifetime["readerStopped"] = stopped(cleanup)
            witness = decode(private_bytes(private_report)) if private_report.is_file() else {}
            report["workerStages"].append(public_stage(witness))
            require(code == 0 and lifetime["readerStopped"], "recovery-worker-failed")
            require(stage_gate(witness, stage, observed.input_message, observed.message), "recovery-worker-proof-incomplete")
        require(sum(stage["detectorScanCalls"] for stage in report["workerStages"]) == 2,
                "original-detector-scan-count-mismatch")
        require(verify_build(args) == build_sha and digest(executable.read_bytes()) == executable_hash
                and digest(scanner.read_bytes()) == SCANNER_SHA and digest(rules.read_bytes()) == RULES_SHA,
                "recovery-inputs-changed")
        report.update(executableSHA256=executable_hash, inputsUnchanged=True, passed=True,
                      workerProcessCount=3, coldProcessRecoveryEstablished=True,
                      detectorReceiptAcceptance=True, presentationRecoveryEstablished=True)
    except ProbeFailure as error:
        report["failureCategory"] = str(error)
    except Exception:
        report["failureCategory"] = "recovery-probe-unavailable"
    finally:
        common.finish_cleanup(report, lifetime, original_path=args.auth_file, original_hash=original,
            root=root, home=home, root_identity=root_identity, home_identity=identity)
        report.update(lifetime)
        report["passed"] = report["passed"] and all(report[key] is True for key in (
            "authRemoved", "originalAuthUnchanged", "ownedRootRemoved", "producerStopped", "readerStopped", "versionProcessStopped"))
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
    parser.add_argument("--model")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--private-control", type=Path)
    parser.add_argument("--scanner-executable", type=Path, default=ROOT / ".build/scanner/betterleaks")
    parser.add_argument("--scanner-rules", type=Path, default=ROOT / ".build/scanner/betterleaks.toml")
    args = parser.parse_args(argv)
    if args.action == "run" and any(getattr(args, key) is None for key in (
            "executable", "auth_file", "model", "report", "private_control")):
        parser.error("run requires executable, auth-file, model, report, and private-control")
    return args


if __name__ == "__main__":
    opts = arguments()
    sys.exit(build(opts) if opts.action == "build" else run(opts))
