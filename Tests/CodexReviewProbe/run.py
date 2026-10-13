#!/usr/bin/env python3
"""Genuine fake-only inline review, followed by two production passive reads.

The original persisted assistant source is selected independently of the live
item ID. No signed app, detector, child, desktop or T3 acceptance is claimed.
Importing this module and boundary tests do not launch a provider.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
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


common = load("review_probe_common", ROOT / "Tests/CodexPlanProbe/run.py")
VERSION, PARSER, MAXIMUM = common.VERSION, common.PARSER, common.MAXIMUM
ProbeFailure, require = common.ProbeFailure, common.require
decode, digest, private_bytes = common.decode, common.digest, common.private_bytes
write_json, exclusive, environment = common.write_json, common.exclusive, common.environment
native_id, opaque_id = common.native_id, common.opaque_id
live, processes = common.live, common.processes
MARKER = "SPILLCHECK_FAKE_NATIVE_REVIEW_42"
INSTRUCTIONS = (
    "This is an isolated fake-only review-format test. Review only the following complete fictional code: "
    "def add(a, b): return a + b. It correctly implements addition. Do not use tools, commands, "
    "agents, files, skills, web search or external services. There are no repository changes to inspect. "
    "Return the review JSON object with findings [], overall_correctness 'patch is correct', "
    "overall_explanation '" + MARKER + ": the supplied fictional addition is correct.', "
    "and overall_confidence_score 1.0. Do not add findings or perform any other work."
)
SAFE_ITEMS = {"userMessage", "agentMessage", "reasoning", "enteredReviewMode", "exitedReviewMode"}
SOURCE_INPUTS = (
    "Tests/CodexReviewProbe/run.py", "Tests/SpillcheckCoreTests/CodexReviewLiveTests.swift",
    "Tests/CodexPlanProbe/run.py", "Tests/CodexLive/run.py", "Tests/Support/processes.py",
    "Sources/SpillcheckCore/CodexAdapter.swift", "Sources/SpillcheckCore/CodexHistoryClient.swift",
    "Sources/SpillcheckCore/CodexHistoryWork.swift", "Package.swift", "Package.resolved",
)


def input_hashes():
    return {name: digest((ROOT / name).read_bytes()) for name in SOURCE_INPUTS}


def review_parameters(thread):
    require(native_id(thread), "invalid-owned-thread")
    return {"threadId": thread, "target": {"type": "custom", "instructions": INSTRUCTIONS},
            "delivery": "inline"}


def text_evidence(value):
    require(isinstance(value, str) and 0 < len(value.encode()) <= 16384 and value.count(MARKER) == 1,
            "original-review-text-required")
    return {"textSHA256": digest(value.encode()), "textBytes": len(value.encode())}


class Observation(common.Observation):
    def __init__(self):
        super().__init__()
        self.review = None
        self.message = None
        self.entered_review = None
        self.input_message = None
        self.turn_failure = None
        self.unbound_turn_starts = 0

    def bind_turn(self, result):
        require(result.get("reviewThreadId") == self.thread, "inline-owned-review-required")
        turn = result.get("turn", {})
        require(isinstance(turn, dict) and opaque_id(turn.get("id")) and self.turn is None,
                "invalid-owned-review-turn")
        self.turn = turn["id"]
        self._flush()

    def event(self, row):
        require(not ("method" in row and "id" in row), "unexpected-server-request")
        method, params = row.get("method"), row.get("params", {})
        require(isinstance(params, dict), "invalid-notification")
        if method not in {"thread/started", "item/started", "item/completed", "turn/started", "turn/completed"}:
            return
        if self.thread is None or (method != "thread/started" and self.turn is None):
            require(len(self.pending) < 128, "early-event-budget")
            self.pending.append(row)
            return
        if method == "thread/started":
            require(params.get("thread", {}).get("id") == self.thread, "unowned-thread-event")
            return
        require(params.get("threadId") == self.thread, "unowned-thread-event")
        if method.startswith("turn/"):
            turn = params.get("turn", {})
            # ReviewTask forwards its internal child's TurnStarted payload on
            # the parent thread. This notification grants no source authority.
            # Keep all content and completion bound to review/start's own turn.
            if method == "turn/started" and isinstance(turn, dict) and turn.get("id") != self.turn:
                require(opaque_id(turn.get("id")) and self.unbound_turn_starts < 4,
                        "unbound-turn-start-budget")
                self.unbound_turn_starts += 1
                return
            if not isinstance(turn, dict) or turn.get("id") != self.turn:
                self.turn_failure = {"method": method, "itemKind": None, "boundParentThread": True}
            require(isinstance(turn, dict) and turn.get("id") == self.turn, "unowned-turn-event")
            if method == "turn/completed":
                require(not self.done and turn.get("status") == "completed" and turn.get("error") is None,
                        "review-turn-not-completed")
                self.done = True
            return
        if params.get("turnId") != self.turn:
            kind = params.get("item", {}).get("type") if isinstance(params.get("item"), dict) else None
            self.turn_failure = {"method": method, "itemKind": kind if kind in SAFE_ITEMS else "other",
                                 "boundParentThread": True}
        require(params.get("turnId") == self.turn, "unowned-turn-event")
        item = params.get("item", {})
        require(isinstance(item, dict) and item.get("type") in SAFE_ITEMS, "unexpected-native-item")
        require(opaque_id(item.get("id")), "invalid-native-item-id")
        if method != "item/completed":
            return
        kind = item["type"]
        self.item_counts[kind] = self.item_counts.get(kind, 0) + 1
        if kind == "enteredReviewMode":
            require(self.entered_review is None and item.get("review") == INSTRUCTIONS,
                    "original-custom-review-instructions-required")
            self.entered_review = text_evidence(item["review"])
        elif kind == "userMessage":
            content = item.get("content")
            require(self.input_message is None and isinstance(content, list) and len(content) == 1
                    and isinstance(content[0], dict) and content[0].get("type") == "text"
                    and content[0].get("text") == INSTRUCTIONS,
                    "original-native-review-input-required")
            self.input_message = {"itemID": item["id"], **text_evidence(content[0]["text"])}
        elif kind == "exitedReviewMode":
            require(self.review is None, "duplicate-completed-review")
            self.review = text_evidence(item.get("review"))
        elif kind == "agentMessage":
            require("phase" in item and item["phase"] in (None, "commentary", "partial_answer", "final_answer"),
                    "invalid-assistant-phase")
            if item["phase"] is None:
                require(self.message is None, "ambiguous-null-phase-message")
                self.message = {"itemID": item["id"], **text_evidence(item.get("text"))}

    def complete(self):
        require(self.thread is not None and self.turn is not None and self.done and not self.pending
                and self.review is not None and self.message is not None
                and self.entered_review is not None and self.input_message is not None
                and self.entered_review == {key: self.input_message[key] for key in ("textSHA256", "textBytes")}
                and self.review == {key: self.message[key] for key in ("textSHA256", "textBytes")},
                "original-null-phase-review-incomplete")
        return {"nativeReviewCompleted": True, "liveNullPhaseMessageCount": 1,
                "liveReviewAndMessageBytesMatch": True, **self.review,
                "completedItemCounts": self.item_counts, "unexpectedToolRequests": 0,
                "unboundTurnStartsIgnored": self.unbound_turn_starts,
                "unboundTurnSourceAdmission": False, "nativeOriginalInputMatchesEnteredReview": True,
                "inputTextSHA256": self.input_message["textSHA256"], "inputTextBytes": self.input_message["textBytes"]}


def produce(executable, model, root, home, work, lifetime, private_control):
    observation, selector, process = Observation(), selectors.DefaultSelector(), None
    stage = "spawn"
    try:
        process = subprocess.Popen([str(executable), "--no-daemon", "app-server", "--stdio"],
            cwd=work, env=environment(root, home), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        lifetime["producerStopped"] = False
        lifetime["providerLaunchCount"] = 1
        write_json(private_control / "producer-process.json", {"pid": process.pid, "root": str(root)})
        rpc = common.RPC(process, selector, observation)
        stage = "initialize"
        rpc.request("initialize", {"clientInfo": {"name": "spillcheck-fake-review-probe", "version": "1"},
            "capabilities": {"experimentalApi": True}})
        rpc.write({"method": "initialized", "params": {}})
        models = rpc.request("model/list", {"limit": 100, "includeHidden": True})
        require(isinstance(models.get("data"), list) and len(models["data"]) <= 100
                and any(isinstance(item, dict) and item.get("model") == model for item in models["data"]),
                "requested-model-unavailable")
        stage = "thread-start"
        result = rpc.request("thread/start", {"model": model, "allowProviderModelFallback": False,
            "cwd": str(work), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": False,
            "environments": [], "developerInstructions": "Review only the supplied fictional code. Never use tools or read files."})
        observation.bind_thread(result, model, work)
        stage = "review-start"
        observation.bind_turn(rpc.request("review/start", review_parameters(observation.thread)))
        stage = "review-events"
        while not observation.done:
            rpc.pump(rpc.deadline)
        report = observation.complete()
        write_json(private_control / "owned-live-identity.json", {"threadID": observation.thread,
            "turnID": observation.turn, **observation.message, "input": observation.input_message})
        process.stdin.close()
        stage = "normal-shutdown"
        end = time.monotonic() + 8
        while process.poll() is None and time.monotonic() < end:
            rpc.pump(end)
        require(process.poll() == 0, "producer-normal-shutdown-unverified")
        report["normalProducerShutdown"] = True
        stage = "completed"
        return observation, report
    finally:
        try:
            if process is not None:
                stopped = processes.stop_group(process)
                lifetime["producerStopped"] = (process.poll() is not None and not stopped["term_permission_denied"]
                                                and not stopped["kill_permission_denied"])
        finally:
            selector.close()
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    try:
                        stream.close()
                    except OSError:
                        pass
            try:
                write_json(private_control / "producer-diagnostic.json", {"schemaVersion": 1, "stage": stage,
                    "threadBound": observation.thread is not None, "turnBound": observation.turn is not None,
                    "completedItemCounts": observation.item_counts, "reviewCompleted": observation.done,
                    "renderedReviewObserved": observation.review is not None,
                    "nullPhaseMessageObserved": observation.message is not None,
                    "enteredReviewObserved": observation.entered_review is not None,
                    "originalInputObserved": observation.input_message is not None,
                    "producerStopped": lifetime["producerStopped"], "turnFailure": observation.turn_failure,
                    "unboundTurnStartsIgnored": observation.unbound_turn_starts})
            except (OSError, ProbeFailure):
                pass


PASSIVE_CHECKS = {"metadataMatches", "nativeReviewMatchesLiveBytes", "nativeItemIdentityStable",
    "sourceIdentityMatches", "sourceBytesPreserved", "sourceOriginVerified", "intermediateResponseMapping",
    "nullPhasePresent", "originalTimestampVerified", "noToolItems", "targetGapFree", "actualSecondRead",
    "replayStable", "readerShutdownCompletedWithinDeadline", "passive", "networkDenied", "forkDenied",
    "authAbsentAfterReads", "parentNativeSourceOnly", "presentationNotScanned", "onlyExpectedItemKinds"}
INPUT_CHECKS = {"nativeInputMatchesLiveBytes", "nativeInputMatchesEnteredReview", "inputSourceIdentityMatches",
    "inputSourceBytesPreserved", "inputSourceOriginVerified", "userPromptMapping", "inputOriginalTimestampVerified",
    "inputTargetGapFree", "inputReplayStable", "inputNativeIdentityStable", "inputTurnRelationshipVerified",
    "inputTurnRelationshipStable"}
PASSIVE_LIMITS = {"childCoverageEstablished", "signedAcceptanceEstablished", "wholeSessionGapFreeEstablished"}
PUBLIC_PASSIVE_FIELDS = PASSIVE_CHECKS | INPUT_CHECKS | PASSIVE_LIMITS | {
    "schemaVersion", "status", "failureStage", "parserContract", "readerVersion", "producerVersion",
    "reviewItemCount", "reviewSourceCount", "threadReadCalls", "itemReadCalls", "turnReadCalls",
    "threadListCalls", "resumeCalls", "forkCalls", "reviewTextBytes", "reviewTextSHA256",
    "selectionBasis", "liveItemIDEqualsPersistedItemID", "timeEvidence", "allowedItemKindCounts",
    "otherItemKindCount", "gapReasons", "gapDiagnostics", "presentationItemCount", "presentationSourceCount",
    "presentationGapReasons", "presentationGapDiagnostics", "presentationRequiredGapCount",
    "inputItemCount", "inputSourceCount", "totalOriginalSourceCount", "inputTextSHA256", "inputTextBytes",
    "inputTimeEvidence", "inputGapReasons", "inputGapDiagnostics", "inputTurnMatchesReviewTurn", "inputTurnRelation"}


INPUT_DIAGNOSTIC_BOOLEANS = {
    "nativeTurnValid", "nativeTurnMatchesReview", "nativeItemIDValid", "contentIsArray",
    "singleTextBlock", "textPresent", "inputTextBounded", "inputBytesMatch", "inputHashMatches",
    "presentationTurnsMatchReview", "enteredTextMatchesInput", "exitedTextMatchesOutput",
    "inputOutputIDsDistinct", "inputItemTimestampPresent", "inputItemTimestampValid",
    "inputTurnIntervalAvailable", "inputOriginalTimestampAvailable", "outputItemTimestampPresent",
    "outputItemTimestampValid", "outputTurnIntervalAvailable", "outputOriginalTimestampAvailable", "outputMarkerUnique",
    "turnRecordIDsValidAndUnique", "inputRootValid", "inputRootMatchesReview", "reviewRootMatchesReview",
    "inputTurnRelationshipVerified",
}
INPUT_DIAGNOSTIC_COUNTS = {"userItemCount", "contentBlockCount", "inputTextBytes", "enteredItemCount",
    "exitedItemCount", "inputIDOccurrenceCount", "outputIDOccurrenceCount", "inputTurnRecordCount", "reviewTurnRecordCount"}


def public_passive(report):
    result = {key: report[key] for key in sorted(PUBLIC_PASSIVE_FIELDS) if key in report}
    if result.get("inputTurnRelation") not in ("same-review-turn", "native-review-root"):
        result.pop("inputTurnRelation", None)
    if type(result.get("inputTurnMatchesReviewTurn")) is not bool:
        result.pop("inputTurnMatchesReviewTurn", None)
    diagnostic = report.get("inputDiagnostic")
    if isinstance(diagnostic, dict):
        closed = {key: diagnostic[key] for key in INPUT_DIAGNOSTIC_BOOLEANS
                  if type(diagnostic.get(key)) is bool}
        closed.update({key: diagnostic[key] for key in INPUT_DIAGNOSTIC_COUNTS
                       if type(diagnostic.get(key)) is int and 0 <= diagnostic[key] <= 16_384})
        digest_value = diagnostic.get("inputTextSHA256")
        if isinstance(digest_value, str) and re.fullmatch(r"[0-9a-f]{64}", digest_value):
            closed["inputTextSHA256"] = digest_value
        result["inputDiagnostic"] = closed
    return result


def passive_gate(report, message, original_input):
    expected = {"reviewItemCount": 1, "reviewSourceCount": 1, "threadReadCalls": 2,
        "itemReadCalls": 2, "turnReadCalls": 2, "threadListCalls": 0, "resumeCalls": 0, "forkCalls": 0,
        "presentationSourceCount": 0, "presentationItemCount": 2, "otherItemKindCount": 0,
        "reviewTextBytes": message["textBytes"], "inputItemCount": 1, "inputSourceCount": 1,
        "totalOriginalSourceCount": 2, "inputTextBytes": original_input["textBytes"]}
    return (isinstance(report, dict) and all(report.get(key) is True for key in PASSIVE_CHECKS)
        and all(report.get(key) is False for key in PASSIVE_LIMITS)
        and all(report.get(key) is True for key in INPUT_CHECKS)
        and ((report.get("inputTurnRelation") == "same-review-turn" and report.get("inputTurnMatchesReviewTurn") is True)
             or (report.get("inputTurnRelation") == "native-review-root" and report.get("inputTurnMatchesReviewTurn") is False))
        and report.get("gapReasons") == [] and report.get("gapDiagnostics") == []
        and report.get("inputGapReasons") == [] and report.get("inputGapDiagnostics") == []
        and report.get("inputTextSHA256") == original_input["textSHA256"]
        and report.get("inputTimeEvidence") in {"item-completed", "item-started", "matching-turn-interval"}
        and report.get("selectionBasis") == "unique-owned-turn-null-phase-live-bytes"
        and type(report.get("liveItemIDEqualsPersistedItemID")) is bool
        and report.get("timeEvidence") in {"item-completed", "item-started", "matching-turn-interval"}
        and report.get("status") == "native-review-read-and-replayed"
        and report.get("parserContract") == PARSER and report.get("readerVersion") == VERSION
        and report.get("producerVersion") == VERSION
        and report.get("reviewTextSHA256") == message["textSHA256"]
        and all(type(report.get(key)) is int and report[key] == value for key, value in expected.items()))


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--auth-file", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--private-control", type=Path, required=True)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.model) is not None, "invalid-model")
    require(not args.report.exists() and not args.report.is_symlink(), "report-already-exists")
    args.private_control.mkdir(mode=0o700, parents=False, exist_ok=False)
    executable = args.executable.expanduser().resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="spillcheck-native-review-")).resolve()
    home, work = root / "home", root / "work"
    home.mkdir(mode=0o700)
    work.mkdir(mode=0o700)
    hi, ri = home.stat(), root.stat()
    identity, root_identity = (hi.st_dev, hi.st_ino), (ri.st_dev, ri.st_ino)
    lifetime = {"producerStopped": True, "readerStopped": True, "versionProcessStopped": True, "providerLaunchCount": 0}
    report = {"schemaVersion": 1, "passed": False, "fixture": "one-fake-native-inline-review", "model": args.model,
        "signedAppAcceptance": False, "desktopAcceptance": False, "t3Acceptance": False,
        "fullHostAcceptance": False, "detectorReceiptAcceptance": False, "nativeChildCoverageEstablished": False,
        "partialAnswerProducerEstablished": False, "reviewUsesInternalSubSession": True,
        "authRemoved": False, "originalAuthUnchanged": False, "ownedRootRemoved": False}
    original = None
    try:
        inputs, executable_hash = input_hashes(), digest(executable.read_bytes())
        write_json(args.private_control / "input-hashes.json", inputs)
        cleanup = {}
        lifetime["versionProcessStopped"] = False
        try:
            version = live.observe_version(str(executable), environment=environment(root, home), directory=work,
                expected=VERSION, cleanup_report=cleanup)
        finally:
            lifetime["versionProcessStopped"] = (cleanup.get("leaderExited") is True
                and cleanup.get("groupKillPermissionDenied") is False)
        require(version == VERSION and lifetime["versionProcessStopped"], "reader-version-mismatch")
        authentication = private_bytes(args.auth_file, 1024 * 1024)
        original = digest(authentication)
        exclusive(home / "auth.json", authentication)
        del authentication
        exclusive(home / "config.toml", (f'model = "{args.model}"\nreview_model = "{args.model}"\nweb_search = "disabled"\n'
            '[features]\nshell_tool = false\n[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())
        observed, producer = produce(executable, args.model, root, home, work, lifetime, args.private_control)
        report["producer"] = producer
        require(lifetime["producerStopped"], "producer-cleanup-unconfirmed")
        report["authRemoved"] = common.cleanup_auth(home, identity)
        require(report["authRemoved"], "auth-removal-required-before-passive-read")
        private_report = args.private_control / "passive-report.json"
        env = dict(os.environ)
        env.update(environment(root, home))
        env.update({"SPILLCHECK_REVIEW_PROBE_HOME": str(home), "SPILLCHECK_REVIEW_PROBE_THREAD": observed.thread,
            "SPILLCHECK_REVIEW_PROBE_TURN": observed.turn, "SPILLCHECK_REVIEW_PROBE_ITEM": observed.message["itemID"],
            "SPILLCHECK_REVIEW_PROBE_EXECUTABLE": str(executable), "SPILLCHECK_REVIEW_PROBE_REPORT": str(private_report),
            "SPILLCHECK_REVIEW_PROBE_SHA256": observed.message["textSHA256"],
            "SPILLCHECK_REVIEW_PROBE_BYTES": str(observed.message["textBytes"]),
            "SPILLCHECK_REVIEW_PROBE_INPUT_SHA256": observed.input_message["textSHA256"],
            "SPILLCHECK_REVIEW_PROBE_INPUT_BYTES": str(observed.input_message["textBytes"])})
        cleanup = {}
        lifetime["readerStopped"] = False
        try:
            code, _, _ = live.bounded(["/usr/bin/swift", "test", "--scratch-path", str(args.scratch_path),
                "--skip-build", "--no-parallel", "--filter", "CodexReviewLiveTests"], environment=env,
                directory=ROOT, timeout=90, maximum_bytes=MAXIMUM, cleanup_report=cleanup)
        finally:
            lifetime["readerStopped"] = (cleanup.get("leaderExited") is True
                and cleanup.get("groupKillPermissionDenied") is False)
        require(code == 0, "passive-witness-process-failed")
        passive = decode(private_bytes(private_report))
        report["passive"] = public_passive(passive)
        require(passive_gate(passive, observed.message, observed.input_message), "passive-witness-unverified")
        require(digest(executable.read_bytes()) == executable_hash, "executable-changed")
        require(input_hashes() == inputs, "probe-inputs-changed")
        report.update(executableSHA256=executable_hash, probeInputsUnchanged=True, passed=True)
    except ProbeFailure as error:
        report["failureCategory"] = str(error)
    except Exception:
        report["failureCategory"] = "probe-unavailable"
    finally:
        common.finish_cleanup(report, lifetime, original_path=args.auth_file, original_hash=original,
            root=root, home=home, root_identity=root_identity, home_identity=identity)
        report.update(lifetime)
        report["passed"] = (report["passed"] and all(report[key] is True for key in
            ("authRemoved", "originalAuthUnchanged", "ownedRootRemoved", "producerStopped", "readerStopped", "versionProcessStopped")))
        report["privateCleanupPending"] = not report["ownedRootRemoved"]
        if not report["ownedRootRemoved"]:
            write_json(args.private_control / "cleanup-handoff.json", {"ownedRoot": str(root),
                "authenticationMayRemain": not report["authRemoved"], **lifetime})
        write_json(args.report, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(run(arguments()))
