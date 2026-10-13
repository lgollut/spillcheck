#!/usr/bin/env python3
"""One public native search: signed full scan receipts, cold restart and exact reread."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import time

spec = importlib.util.spec_from_file_location("web_inventory_lifecycle", Path(__file__).with_name("run-app-codex-inventory-state.py"))
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)
lifecycle, setup, shared = inventory.lifecycle, inventory.setup, inventory.shared
ROOT, require = shared.ROOT, shared.require
PROMPT = """This is a disposable Spillcheck source-format test using public documentation only.
Perform exactly one built-in web search for: site:developers.openai.com Codex app-server
Do not open results, read files, invoke shell or MCP tools, or create subagents.
After the search returns, finish exactly SPILLCHECK_WEB_PROBE_DONE.
"""
PROFILE = "owned-signed-codex-web-results"
REPLAY_CONTROL = "web-result-replay"
PARSER = "codex-content-contract-v16"
DETECTOR = "betterleaks-1.9.0+stdlib-1+leakret-native-1+mapping-1"
PUBLIC_QUERY = "site:developers.openai.com Codex app-server"
STATE_DIGESTS = ("receiptDigests", "sourceKindDigests", "sourceTimeDigests")
WEB_DIGESTS = ("webSourceDigests", "webResultDigests", "webReceiptDigests")
RUNNER_INPUTS = ("Tests/AppAcceptance/run-app-codex-web-results.py",
    "Tests/AppAcceptance/run-app-codex-inventory-state.py", "Tests/AppAcceptance/run-app-codex-upgrade.py",
    "Tests/AppAcceptance/run-app-codex-omission-recovery.py", "Tests/AppAcceptance/run-app-codex-recovery.py",
    "Tests/CodexLive/run.py", "Tests/Support/acceptance_artifacts.py",
    "Tests/Support/processes.py", "Tests/Support/inventory_evidence.py",
    "Tests/BetaTrial/preflight.py", "Tests/BetaTrial/trial.py")
REQUIRED_CHECKS = {"readerVersionObservedBeforeProvider", "oneOwnedPublicSearchCompleted",
    "temporaryAuthRemovedBeforeSignedReads", "sourcePinnedBeforeSignedRead", "freshOwnerCreatedVault",
    "noReceiptsOrSourcesBeforeInitialAdmission", "exactNativeResultBytesHaveFullCurrentDetectorReceipts",
    "initialWorkerNormalShutdown", "sourceUnchangedAfterInitialRead", "fullReceiptsAndSourceStateSurviveColdRestart",
    "coldForcedExactAuditRereadsSamePositiveNativeResultBytes", "replayPreservesExactFullReceiptsWithoutDuplicates",
    "twoDistinctWorkersNormalShutdown", "finalQueueEmptyWithoutGaps", "sourceUnchangedAfterColdReplay",
    "temporaryAuthenticationRemoved", "ownedProviderHomeRemoved", "creatorCleanupAuthorizedAfterNormalSourceShutdown",
    "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped", "noAppDiagnosticsOrOutput",
    "readerExecutableUnchanged", "candidateAndProductionInputsUnchanged", "candidateManifestBytesUnchanged",
    "runnerAndLibraryBytesUnchanged", "originalAuthenticationFileUnchanged"}


def completed_checks(checks):
    return REQUIRED_CHECKS <= checks.keys() and all(value is True for value in checks.values())


def runner_hashes():
    return {name: shared.preflight.hash_file(ROOT, name, [0]) for name in RUNNER_INPUTS}


def worker_command(binary, root, name, *, home, native, reader, version):
    require(name in ("worker1", "worker2"), "fixed-worker-required")
    native = shared.canonical_id(native)
    require(home.parent == root and home.name == "home", "owned-direct-home-required")
    command = shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker",
        "--acceptance-no-profile-catchup", "--acceptance-recovery-web-results", "--acceptance-web-source", native,
        "--codex-profile", PROFILE, "--codex-version", version, "--codex-home", str(home),
        "--codex-executable", str(reader), "--codex-interface", "standalone-cli",
        "--codex-authorized-host", "standalone-cli", "--codex-authority", "codex-public-native-v1"]
    return command + (["--acceptance-allow-history-request"] if name == "worker1" else [])


def producer_command(executable, work):
    return [str(executable), "--no-daemon", "--search", "-a", "never", "exec",
        "--skip-git-repo-check", "--json", "-s", "read-only", "-C", str(work), "-"]


class _ObjectPairs(list):
    pass


class _WebItem(dict):
    """Keep the exec wrapper identity distinct from its flattened native web identity."""
    exec_item_id = None


def exec_event(line):
    # rust-v0.162.1 serializes ThreadItem.id before flattened WebSearchItem.id.
    # This exception applies to that one path and shape, never to thread ownership.
    def decode(value, path=()):
        require(len(path) <= 32, "producer-json-depth")
        if isinstance(value, _ObjectPairs):
            require(len(value) <= 256, "producer-object-budget")
            keys = [key for key, _ in value]
            seen, duplicates = set(), set()
            for key in keys:
                if key in seen:
                    duplicates.add(key)
                seen.add(key)
            if duplicates:
                identities = [item for key, item in value if key == "id"]
                types = [item for key, item in value if key == "type"]
                require(path == ("item",) and duplicates == {"id"} and len(identities) == 2
                    and types == ["web_search"] and keys[:3] == ["id", "type", "id"]
                    and isinstance(identities[0], str) and re.fullmatch(r"item_[0-9]{1,8}", identities[0]) is not None
                    and isinstance(identities[1], str) and 0 < len(identities[1].encode()) <= 4096
                    and not any(character.isspace() or ord(character) < 32 for character in identities[1]),
                    "duplicate-json-key")
                result = _WebItem()
                result.exec_item_id = identities[0]
                pairs = value[1:]  # Retain the separate native id; no ordinary last-wins decoding.
            else:
                result, pairs = {}, value
            for key, item in pairs:
                require(key not in result, "duplicate-json-key")
                result[key] = decode(item, path + (key,))
            return result
        if isinstance(value, list):
            require(len(value) <= 1024, "producer-array-budget")
            return [decode(item, path + (index,)) for index, item in enumerate(value)]
        return value
    return decode(json.loads(line, object_pairs_hook=_ObjectPairs))


def producer_identity(output):
    """Exec telemetry selects the new thread; the signed parser witnesses actual results."""
    require(isinstance(output, bytes) and 0 < len(output) <= 2 * 1024 * 1024, "producer-output-budget")
    identities, web, turns, final = [], [], 0, []
    for line in output.splitlines():
        event = exec_event(line)
        require(isinstance(event, dict), "producer-event-shape")
        kind = event.get("type")
        require(kind in ("thread.started", "turn.started", "item.started", "item.updated", "item.completed", "turn.completed"),
            "unexpected-producer-event")
        if kind == "thread.started":
            identities.append(shared.canonical_id(event.get("thread_id")))
        elif kind == "turn.completed":
            turns += 1
        elif kind.startswith("item."):
            item = event.get("item")
            require(isinstance(item, dict) and item.get("type") in ("reasoning", "agent_message", "web_search"),
                "unexpected-producer-tool")
            if kind == "item.completed" and item["type"] == "web_search":
                require(isinstance(item.get("id"), str) and bool(item["id"]), "search-item-identity-required")
                action = item.get("action")
                require(item.get("query") == PUBLIC_QUERY and isinstance(action, dict) and action.get("type") == "search"
                    and action.get("query", PUBLIC_QUERY) in (None, PUBLIC_QUERY)
                    and action.get("queries", [PUBLIC_QUERY]) in (None, [PUBLIC_QUERY]), "exact-public-search-query-required")
                web.append(item["id"])
            elif kind == "item.completed" and item["type"] == "agent_message":
                final.append(item.get("text"))
    require(len(identities) == 1 and turns == 1 and len(web) == 1
        and final and final[-1] == "SPILLCHECK_WEB_PROBE_DONE", "one-completed-public-search-required")
    return identities[0]


def run_producer(executable, home, work, root, lifetime):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SPILLCHECK_")}
    environment["CODEX_HOME"] = str(home)
    selector, output, diagnostics = selectors.DefaultSelector(), bytearray(), 0
    lifetime["stopped"] = True
    process = None
    try:
        process = subprocess.Popen(producer_command(executable, work), cwd=work, env=environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        lifetime["started"] = True
        lifetime["stopped"] = False
        lifecycle.process_handoff(root, "producer-process-private.json", process, "one-public-search-producer")
        process.stdin.write(PROMPT.encode())
        process.stdin.close()
        for pipe in (process.stdout, process.stderr):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ)
        deadline = time.monotonic() + 140
        while selector.get_map():
            require(time.monotonic() < deadline, "producer-deadline")
            for key, _ in selector.select(.05):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.fileobj is process.stdout:
                    require(len(output) + len(chunk) <= 2 * 1024 * 1024, "producer-output-budget")
                    output.extend(chunk)
                else:
                    diagnostics += len(chunk)
                    require(diagnostics <= 65536, "producer-diagnostic-budget")
        require(process.wait(timeout=2) == 0, "producer-failed")
        return bytes(output), diagnostics
    finally:
        try:
            if process is not None:
                result = shared.stop_group(process)
                lifetime["stopped"] = (process.poll() is not None and result.get("term_permission_denied") is False
                    and result.get("kill_permission_denied") is False)
        finally:
            selector.close()
            if process is not None:
                for pipe in (process.stdin, process.stdout, process.stderr):
                    pipe.close()


def owned_home(home, identity):
    return (not home.is_symlink() and home.is_dir()
        and (home.stat().st_dev, home.stat().st_ino) == identity)


def remove_auth(home, identity):
    require(owned_home(home, identity), "owned-home-replaced")
    path = home / "auth.json"
    if path.exists() or path.is_symlink():
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
            "owned-auth-boundary")
        path.unlink()
    return not path.exists() and not path.is_symlink()


def source_snapshot(home, identity, native):
    """Hash only this freshly created home's one exact rollout; never inspect personal history."""
    require(owned_home(home, identity), "owned-home-replaced")
    native = shared.canonical_id(native)
    directory = home / "sessions"
    require(directory.is_dir() and not directory.is_symlink(), "owned-source-unavailable")
    names = shared.preflight.tree_files(directory)
    require(len(names) == 1 and names[0].endswith("-" + native + ".jsonl"), "exact-single-owned-rollout-required")
    descriptor = shared.preflight.opened_file(directory, names[0])
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
            and 0 < info.st_size <= 8 * 1024 * 1024, "owned-rollout-boundary")
    finally:
        os.close(descriptor)
    return {"relativePath": names[0], "sha256": shared.preflight.hash_file(directory, names[0], [0])}


def state(report):
    value = report.get("recoveryWebResultState")
    if (report.get("recoveryWebResultsEnabled") is not True or report.get("recoveryWebResultFailure") is not None
            or not isinstance(value, dict) or value.get("measured") is not True or value.get("truncated") is not False
            or value.get("cleanInventory") is not True or value.get("nativeKindEvidence") != "pinned-codex-results-root"
            or value.get("parserContract") != PARSER or value.get("detectorVersion") != DETECTOR
            or type(value.get("initialStoreEmpty")) is not bool
            or type(value.get("allObservedWebSourcesCommitted")) is not bool
            or not shared.exact_int(value.get("payloadRowCount"), 0)):
        return None
    for key in (*STATE_DIGESTS, *WEB_DIGESTS, "initialReceiptDigests", "initialSourceKindDigests"):
        values = inventory.digest_values(value.get(key))
        if values is None or len(values) > 128:
            return None
    for key in ("receiptCount", "sourceCount", "sessionCount", "observedWebSourceCount", "committedWebSourceCount", "batchCount"):
        if type(value.get(key)) is not int or not 0 <= value[key] <= 128:
            return None
    if (value["receiptCount"] != len(value["receiptDigests"]) or value["sourceCount"] != len(value["sourceKindDigests"])
            or len(value["sourceTimeDigests"]) != value["sourceCount"]
            or len(value["webSourceDigests"]) != value["observedWebSourceCount"]
            or len(value["webReceiptDigests"]) != value["committedWebSourceCount"]):
        return None
    for key in ("resultSegmentCount", "resultTextBytes", "resultPointerBytes"):
        if type(value.get(key)) is not int or not 0 <= value[key] <= 8 * 1024 * 1024:
            return None
    for key in ("readerVersions", "producerVersions"):
        if (not isinstance(value.get(key), list) or len(value[key]) > 128
                or any(not isinstance(item, str) or not 0 < len(item) <= 256 for item in value[key])):
            return None
    return value


def ready(report):
    return (inventory.source_ready(report) and report.get("gapReasons") == [] and state(report) is not None
        and shared.exact_int(report.get("valueCount"), 0) and shared.exact_int(report.get("occurrenceCount"), 0)
        and all(shared.digest_set(report, key, empty=True) is not None for key in shared.DIGEST_KEYS))


def fresh(report):
    value = state(report)
    return (ready(report) and value["initialStoreEmpty"] is True
        and all(value[key] == [] for key in (*STATE_DIGESTS, *WEB_DIGESTS, "initialReceiptDigests", "initialSourceKindDigests"))
        and all(value[key] == 0 for key in ("receiptCount", "sourceCount", "sessionCount", "observedWebSourceCount",
            "committedWebSourceCount", "batchCount", "resultSegmentCount", "resultTextBytes", "resultPointerBytes"))
        and all(shared.digest_set(report, key, empty=True) == set() for key in
            (*shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests")))


def scanned(report, version):
    value = state(report)
    return (ready(report) and value["sessionCount"] == 1 and value["receiptCount"] == value["sourceCount"] > 0
        and value["observedWebSourceCount"] == value["committedWebSourceCount"] == 1
        and len(value["webResultDigests"]) == 1 and value["allObservedWebSourcesCommitted"] is True
        and 0 < value["batchCount"] <= 128
        and all(value[key] > 0 for key in ("resultSegmentCount", "resultTextBytes", "resultPointerBytes"))
        and value["readerVersions"] == [version] and value["producerVersions"] == [version])


def stable_store(before, after):
    left, right = state(before), state(after)
    return (left is not None and right is not None and ready(after)
        and shared.manifest_digest(before) == shared.manifest_digest(after)
        and all(left[key] == right[key] for key in ("receiptCount", "sourceCount", "sessionCount"))
        and all(inventory.digest_values(left[key]) == inventory.digest_values(right[key]) for key in STATE_DIGESTS)
        and all(shared.digest_set(before, key, empty=True) == shared.digest_set(after, key, empty=True)
            for key in shared.DIGEST_KEYS))


def cold_restored(before, after):
    value = state(after)
    return (stable_store(before, after) and value["initialStoreEmpty"] is False
        and value["observedWebSourceCount"] == value["committedWebSourceCount"] == value["batchCount"] == 0
        and all(value[key] == [] for key in WEB_DIGESTS)
        and all(value[key] == 0 for key in ("resultSegmentCount", "resultTextBytes", "resultPointerBytes"))
        and inventory.digest_values(value["initialReceiptDigests"]) == inventory.digest_values(state(before)["receiptDigests"])
        and inventory.digest_values(value["initialSourceKindDigests"]) == inventory.digest_values(state(before)["sourceKindDigests"]))


def replayed(baseline, cold, after, version):
    replay = after.get("recoveryWebResultReplay")
    if (not scanned(after, version) or not stable_store(baseline, after)
            or not inventory.new_single_processed_capture(cold, after) or not isinstance(replay, dict)
            or not all(replay.get(key) is True for key in ("controlConsumed", "queued", "cleanBatches",
                "allExpectedSourcesObserved", "completeProgress", "completionObserved", "workCompleted", "successfulReadMatched"))
            or type(replay.get("batchCount")) is not int or not 0 < replay["batchCount"] <= 128
            or type(replay.get("bytesRead")) is not int or replay["bytesRead"] <= 0
            or not shared.exact_int(replay.get("expectedSourceCount"), state(baseline)["sourceCount"])
            or not shared.exact_int(replay.get("observedSourceCount"), state(baseline)["sourceCount"])):
        return False
    capture, audit = inventory.digest_values([replay.get("captureDigest")]), inventory.digest_values([replay.get("auditDigest")])
    return (capture is not None and audit is not None and capture.isdisjoint(audit)
        and capture == (shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
            - shared.digest_set(cold, "recoverySuccessfullyProcessedCaptureDigests", empty=True))
        and all(inventory.digest_values(state(baseline)[key]) == inventory.digest_values(state(after)[key]) for key in WEB_DIGESTS)
        and all(state(baseline)[key] == state(after)[key] for key in ("resultSegmentCount", "resultTextBytes", "resultPointerBytes")))


def deliver(helper, root, native, lifetime):
    cleanup = {}
    lifetime["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "codex", "--interface", "standalone-cli", "--profile-id", PROFILE],
            environment=dict(os.environ), directory=ROOT, timeout=5, maximum_bytes=1024,
            input_bytes=inventory.initial_history_request(native), cleanup_report=cleanup)
    finally:
        lifetime["stopped"] = cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
    require(code == 0 and output.strip() == b"{}" and lifetime["stopped"], "helper-lifetime-unconfirmed")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "candidate-manifest", "executable", "auth-file", "output", "private-control"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("expected-bundle-sha256", "expected-version", "model"):
        parser.add_argument("--" + name, required=True)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    require(not args.output.exists() and not args.output.is_symlink() and not args.private_control.exists()
        and not args.private_control.is_symlink() and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}", args.model) is not None, "explicit-model-required")
    app, reader = args.app.resolve(strict=True), args.executable.resolve(strict=True)
    manifest_path = args.candidate_manifest.resolve(strict=True)
    manifest_hash = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    require(manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256)
        and shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
        and shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-signed-candidate-required")
    reader_hash = shared.preflight.hash_file(reader.parent, reader.name, [0])
    inputs = runner_hashes()
    auth_hash = None
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    with shared.AcceptanceArtifacts("spillcheck-cx-web-", args.output) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        home, work = root / "home", root / "work"
        home.mkdir(mode=0o700)
        work.mkdir(mode=0o700)
        home_identity = (home.stat().st_dev, home.stat().st_ino)
        shared.write_new(root / "run-token", token)
        shared.write_new(root / "stop-codex-polling", token)
        shared.write_json(root / "candidate-build.json", manifest)
        shared.write_json(root / "runner-inputs-private.json", inputs)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "producerProcessHandoff": str(root / "producer-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False,
            "protectionCleanupReportField": "ownedProtectionCleanupPending", "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-one-public-CLI-native-web-result-scan-and-replay", "passed": False,
            "startedAtUnixSeconds": time.time(),
            "candidateBundleSHA256": args.expected_bundle_sha256, "readerVersion": args.expected_version,
            "candidateManifestSHA256": manifest_hash,
            "producerVersion": args.expected_version, "model": args.model, "providerLaunchCount": 0,
            "selectedThreadCount": 0, "syntheticInitialQueueAdmission": True,
            "initialAdmissionKind": "exact-selected-source-historical-audit", "providerHookDispatchEstablished": False,
            "personalHistoryRead": False, "personalConfigurationChanged": False, "rawProviderOutputRetained": False,
            "externalQueryContainsTestMarker": None, "receiptSeedingUsed": False, "knownSecretRecallEstablished": False,
            "secondDetectorScanEstablished": False, "systemNotificationDeliveryEstablished": False,
            "fullCodexAcceptance": False, "T3Acceptance": False, "desktopAcceptance": False,
            "sideChatCoverageEstablished": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "savedProfileRecoveryEstablished": False,
            "schemaMigrationEstablished": False, "providerUpgradeEstablished": False, "crashRecoveryEstablished": False,
            "checks": {}}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready, auth_removed, successful, final = False, True, False, {}
        producer_lifetime, helper_lifetime, version_cleanup = {"stopped": True, "started": False}, {"stopped": True}, {}
        source, native, phase = None, None, "reader-version"
        try:
            version = shared.live.observe_version(reader, environment=dict(os.environ, CODEX_HOME=str(home)),
                directory=work, expected=args.expected_version, cleanup_report=version_cleanup)
            checks["readerVersionObservedBeforeProvider"] = version == args.expected_version
            require(version_cleanup.get("leaderExited") is True and version_cleanup.get("groupKillPermissionDenied") is False,
                "version-process-lifetime-unconfirmed")
            # Protection availability is a prerequisite for spending a provider turn.
            # Keep this original creator alive through production and both signed reads.
            phase = "fresh-vault-owner"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready = True
            checks["freshOwnerCreatedVault"] = True
            require(owner.process.poll() is None, "fresh-owner-lost")
            authentication = shared.private_bytes(args.auth_file)
            auth_hash = hashlib.sha256(authentication).hexdigest()
            shared.write_new(home / "auth.json", authentication)
            del authentication
            auth_removed = False
            shared.write_new(home / "config.toml", (f'model = "{args.model}"\nmodel_reasoning_effort = "low"\n'
                'web_search = "live"\n[analytics]\nenabled = false\n').encode())
            phase = "one-public-search"
            require(owner.process.poll() is None, "fresh-owner-lost")
            try:
                output, diagnostic_bytes = run_producer(reader, home, work, root, producer_lifetime)
            finally:
                if producer_lifetime["stopped"]:
                    auth_removed = remove_auth(home, home_identity)
            require(producer_lifetime["stopped"] and auth_removed, "producer-or-auth-cleanup-unconfirmed")
            native = producer_identity(output)
            report.update(selectedThreadCount=1, externalQueryContainsTestMarker=False,
                producerOutputSHA256=hashlib.sha256(output).hexdigest(),
                producerDiagnosticBytes=diagnostic_bytes)
            del output
            source = source_snapshot(home, home_identity, native)
            shared.write_json(root / "owned-source-private.json", {"nativeIdentitySource": "own-exec-thread-started",
                "nativeID": native, "home": str(home), "source": source})
            checks["oneOwnedPublicSearchCompleted"] = True
            checks["temporaryAuthRemovedBeforeSignedReads"] = auth_removed
            checks["sourcePinnedBeforeSignedRead"] = True
            def launch(name):
                require(owner.process.poll() is None, "fresh-owner-lost")
                worker = setup.ReportProcess(worker_command(binary, root, name, home=home, native=native,
                    reader=reader, version=version))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                return worker

            phase = "fresh-full-result-scan"
            worker1 = launch("worker1")
            empty = worker1.wait_report(root / "worker1-report.json", fresh, "fresh-empty-worker-unavailable")
            checks["noReceiptsOrSourcesBeforeInitialAdmission"] = True
            deliver(helper, root, native, helper_lifetime)
            baseline = worker1.wait_report(root / "worker1-report.json", lambda value:
                scanned(value, version) and inventory.new_single_processed_capture(empty, value),
                "native-results-full-scan-receipts-unverified", timeout=75)
            checks["exactNativeResultBytesHaveFullCurrentDetectorReceipts"] = True
            baseline = inventory.finish_worker(worker1, root, "worker1", lambda value:
                scanned(value, version) and stable_store(baseline, value))
            checks["initialWorkerNormalShutdown"] = True
            checks["sourceUnchangedAfterInitialRead"] = source_snapshot(home, home_identity, native) == source
            phase = "cold-restart-and-exact-reread"
            worker2 = launch("worker2")
            cold = worker2.wait_report(root / "worker2-report.json", lambda value:
                cold_restored(baseline, value), "full-receipts-not-restored-before-reread")
            checks["fullReceiptsAndSourceStateSurviveColdRestart"] = True
            replay = cold.get("recoveryWebResultReplay")
            require(isinstance(replay, dict) and replay.get("controlConsumed") is False
                and replay.get("queued") is False and cold.get("recoveryProcessingStopped") is False,
                "fresh-replay-control-required")
            shared.write_new(root / REPLAY_CONTROL, token)
            replay_result = worker2.wait_report(root / "worker2-report.json", lambda value:
                replayed(baseline, cold, value, version), "cold-native-result-reread-unverified", timeout=75)
            checks["coldForcedExactAuditRereadsSamePositiveNativeResultBytes"] = True
            checks["replayPreservesExactFullReceiptsWithoutDuplicates"] = True
            final = inventory.finish_worker(worker2, root, "worker2", lambda value:
                replayed(baseline, cold, value, version))
            checks["twoDistinctWorkersNormalShutdown"] = len({worker.process.pid for worker in workers}) == 2
            checks["finalQueueEmptyWithoutGaps"] = ready(final)
            checks["sourceUnchangedAfterColdReplay"] = source_snapshot(home, home_identity, native) == source
            successful = all(checks.values())
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            report["providerLaunchCount"] = int(producer_lifetime["started"])
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            if producer_lifetime["stopped"] and owned_home(home, home_identity):
                try:
                    auth_removed = remove_auth(home, home_identity)
                except (OSError, RuntimeError):
                    auth_removed = False
            normal = shared.safe_creator_cleanup(shutdowns,
                helper_stopped=helper_lifetime["stopped"] and producer_lifetime["stopped"],
                socket_absent=not (root / "protected-store/capture.sock").exists())
            home_removed = False
            if successful and normal and auth_removed:
                try:
                    require(owned_home(home, home_identity), "owned-home-replaced")
                    shutil.rmtree(home)
                    home_removed = setup.provider_home_absent(home)
                except (OSError, RuntimeError):
                    pass
            authorized = normal and auth_removed
            owner_report, retained, owner_stopped, handoff_failed = inventory.finish_creator(owner, root, token,
                ready_observed=owner_ready, authorized=authorized, groups=groups)
            report.update(originalCreatorRetainedForCleanup=retained, creatorRetentionHandoffWriteFailed=handoff_failed,
                ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True,
                ownedSourceRetainedPrivately=not setup.provider_home_absent(home), temporaryAuthenticationRemoved=auth_removed)
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            checks["temporaryAuthenticationRemoved"] = auth_removed
            checks["ownedProviderHomeRemoved"] = home_removed
            checks["creatorCleanupAuthorizedAfterNormalSourceShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = (owner_report.get("createdFreshVault") is True
                and owner_report.get("cleanupPassed") is True)
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped and producer_lifetime["stopped"]
                and helper_lifetime["stopped"] and all(row["groupStopped"] for row in shutdowns) and bool(groups)
                and all(row.get("term_permission_denied") is False and row.get("kill_permission_denied") is False for row in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            try:
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
                checks["candidateManifestBytesUnchanged"] = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
                checks["runnerAndLibraryBytesUnchanged"] = runner_hashes() == inputs
                checks["originalAuthenticationFileUnchanged"] = (auth_hash is not None
                    and hashlib.sha256(shared.private_bytes(args.auth_file)).hexdigest() == auth_hash)
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            value = state(final)
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "observedWebSourceCount": value["observedWebSourceCount"] if value else None,
                "resultSegmentCount": value["resultSegmentCount"] if value else None,
                "resultTextBytes": value["resultTextBytes"] if value else None,
                "fullReceiptCount": value["receiptCount"] if value else None,
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons")}
            report["passed"] = successful and "unmetGate" not in report and completed_checks(checks)
            report["signedNativeWebResultReceiptRestartAndReplayEstablished"] = report["passed"]
            report["finishedAtUnixSeconds"] = time.time()
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "preflight-rejected", "signedAppLaunched": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
