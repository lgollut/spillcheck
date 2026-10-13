#!/usr/bin/env python3
"""Signed native MCP, HookPrompt, Plan and local-image scanning, receipts, cold restore and reread."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


web = load("native_signed_lifecycle", Path(__file__).with_name("run-app-codex-web-results.py"))
inventory, lifecycle, setup, shared = web.inventory, web.lifecycle, web.setup, web.shared
ROOT, require = shared.ROOT, shared.require
mcp = load("native_signed_mcp", ROOT / "Tests/CodexMCPSourceProbe/run.py")
hook = load("native_signed_hook", ROOT / "Tests/CodexHookPromptProbe/run.py")
plan = load("native_signed_plan", ROOT / "Tests/CodexPlanProbe/run.py")
media = load("native_signed_local_media", ROOT / "Tests/CodexLocalMediaProbe/run.py")
PROFILES = {"mcp": "owned-signed-codex-mcp", "hook-prompt": "owned-signed-codex-hook-prompt",
    "plan": "owned-signed-codex-plan", "local-image": "owned-signed-codex-local-media"}
REPLAY_CONTROL = "native-content-replay"
PARSER, DETECTOR = web.PARSER, web.DETECTOR
STATE_DIGESTS = ("receiptDigests", "sourceKindDigests", "sourceTimeDigests", "conversationLabelDigests")
TARGET_DIGESTS = ("targetSourceDigests", "targetResultDigests", "targetReceiptDigests")
INITIAL_DIGESTS = ("initialReceiptDigests", "initialSourceKindDigests", "initialSourceTimeDigests", "initialConversationLabelDigests")
RUNNER_INPUTS = tuple(dict.fromkeys(("Tests/AppAcceptance/run-app-codex-native-content.py",
    "Tests/AppAcceptance/run-app-codex-plan.py", "Tests/CodexPlanProbe/run.py",
    "Tests/AppAcceptance/run-app-codex-local-media.py", "Tests/SpillcheckCoreTests/CodexLocalMediaLiveTests.swift",
    *media.build_support.DEPENDENCIES,
    *mcp.SOURCE_INPUTS, *(str(p.relative_to(ROOT)) for p in hook.SOURCE_INPUTS),
    *web.RUNNER_INPUTS, *lifecycle.RUNNER_INPUTS)))
REQUIRED_CHECKS = (web.REQUIRED_CHECKS - {"oneOwnedPublicSearchCompleted",
    "exactNativeResultBytesHaveFullCurrentDetectorReceipts", "coldForcedExactAuditRereadsSamePositiveNativeResultBytes"}) | {
    "oneOwnedNativeFixtureCompleted", "exactNativeTargetBytesHaveFullCurrentDetectorReceipts",
    "coldForcedExactAuditRereadsSameNativeTargetBytes", "exactOwnedDescriptorUnchanged",
    "independentProducerChildrenStopped", "descriptorDiscoveryReaderStopped"}
MEDIA_CHECKS = {"fakeImageRemovedBeforeSignedReads", "exactMediaExclusionPersistedAndReplayed"}
owned_home, remove_auth, source_snapshot = web.owned_home, web.remove_auth, web.source_snapshot


def expected_segments(kind):
    require(kind in ("mcp", "hook-prompt", "local-image"), "fixed-fixture-required")
    if kind == "local-image":
        texts = {"/content/0/text": media.PROMPT}
    elif kind == "hook-prompt":
        texts = {"/fragments/0/text": hook.fixture.REASON}
    else:
        # Fixed fixture coordinates, independent of the production JSON walker.
        value = mcp.fixture.RESULT["structuredContent"]
        texts = {"/result/content/0/text": mcp.fixture.RESULT["content"][0]["text"],
            "/result/structuredContent/type": value["type"],
            "/result/structuredContent/caption": value["caption"],
            "/result/structuredContent/content/0/type": value["content"][0]["type"],
            "/result/structuredContent/content/0/caption": value["content"][0]["caption"],
            "/result/structuredContent/content/0/encrypted_content": value["content"][0]["encrypted_content"],
            "/result/structuredContent/content/0/a~1b~0": value["content"][0]["a/b~"],
            "/result/structuredContent/resource/blob": value["resource"]["blob"],
            "/result/structuredContent/printed": value["printed"],
            "/result/structuredContent/error": value["error"],
            "/result/structuredContent/status": value["status"]}
        require(sorted(texts) == mcp.EXPECTED_POINTERS, "fixed-mcp-coordinates-required")
    return [{"pointer": pointer, "textSHA256": hashlib.sha256(text.encode()).hexdigest(),
        "textBytes": len(text.encode())} for pointer, text in sorted(texts.items())]


def validate_descriptor(value, kind):
    require(kind in PROFILES and isinstance(value, dict) and set(value) == {
        "schemaVersion", "fixtureKind", "threadID", "turnID", "itemID", "producerVersion", "hookRunID", "segments"}
        | ({"imageSHA256"} if kind == "local-image" else set()),
        "fixed-native-descriptor-required")
    segments = value["segments"]
    if kind == "plan":
        require(isinstance(segments, list) and len(segments) == 1 and isinstance(segments[0], dict)
            and set(segments[0]) == {"pointer", "textSHA256", "textBytes"}
            and segments[0]["pointer"] == "/text"
            and isinstance(segments[0]["textSHA256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", segments[0]["textSHA256"]) is not None
            and type(segments[0]["textBytes"]) is int and 1 <= segments[0]["textBytes"] <= 16384,
            "bounded-owned-plan-bytes-required")
        require(plan.native_id(value["turnID"]) and plan.opaque_id(value["itemID"])
            and all(32 < ord(character) < 127 for character in value["itemID"]), "owned-plan-identity-required")
    else:
        require(segments == expected_segments(kind), "fixed-native-bytes-required")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
        and value["fixtureKind"] == kind and mcp.native_id(value["threadID"])
        and mcp.opaque_id(value["turnID"]) and mcp.opaque_id(value["itemID"])
        and value["producerVersion"] == mcp.VERSION
        and (mcp.opaque_id(value["hookRunID"]) if kind == "hook-prompt" else value["hookRunID"] == ""),
        "owned-native-identity-and-bytes-required")
    if kind == "local-image":
        require(media.base.opaque_id(value["turnID"]) and media.base.opaque_id(value["itemID"])
            and value["imageSHA256"] == media.digest(media.png_fixture()), "fixed-local-image-required")
    return value


def plan_descriptor(observed, public):
    """Keep the expected bytes independent of the production parser."""
    require(isinstance(observed.plan, dict), "owned-plan-identity-required")
    value = observed.plan
    descriptor = validate_descriptor({"schemaVersion": 1, "fixtureKind": "plan", "threadID": observed.thread,
        "turnID": observed.turn, "itemID": value.get("itemID"), "producerVersion": plan.VERSION, "hookRunID": "",
        "segments": [{"pointer": "/text", "textSHA256": value.get("textSHA256"),
            "textBytes": value.get("textBytes")}]}, "plan")
    require(public.get("nativePlanCompleted") is True and public.get("normalProducerShutdown") is True
        and shared.exact_int(public.get("completedPlanCount"), 1)
        and shared.exact_int(public.get("unexpectedToolRequests"), 0)
        and public.get("planTextSHA256") == value["textSHA256"]
        and shared.exact_int(public.get("planTextBytes"), value["textBytes"]), "completed-owned-plan-required")
    return descriptor


def descriptor_bytes(value):
    validate_descriptor(value, value.get("fixtureKind"))
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(len(data) <= 8192, "descriptor-budget")
    return data


def completed_checks(checks, fixture=None):
    required = REQUIRED_CHECKS | (MEDIA_CHECKS if fixture == "local-image" else set())
    return required <= checks.keys() and all(value is True for value in checks.values())


def runner_hashes():
    return {name: shared.preflight.hash_file(ROOT, name, [0]) for name in RUNNER_INPUTS}


def worker_command(binary, root, name, *, home, descriptor, reader, version, fixture):
    require(name in ("worker1", "worker2") and fixture in PROFILES, "fixed-worker-and-fixture-required")
    require(home == root / "home" and descriptor == root / "native-content-descriptor.json",
        "owned-direct-home-and-descriptor-required")
    command = shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker",
        "--acceptance-no-profile-catchup", "--acceptance-recovery-native-content",
        "--acceptance-native-content-descriptor", str(descriptor),
        "--codex-profile", PROFILES[fixture], "--codex-version", version, "--codex-home", str(home),
        "--codex-executable", str(reader), "--codex-interface", "standalone-cli",
        "--codex-authorized-host", "standalone-cli", "--codex-authority", "codex-public-native-v1"]
    return command + (["--acceptance-allow-history-request"] if name == "worker1" else [])


def producer_lifetime():
    return {"producerStopped": True, "providerLaunchCount": 0, "childrenStopped": True,
        "descriptorReaderStopped": True}


def refresh_children(kind, root, control, lifetime):
    # Each independent group must be absent; a stopped producer is insufficient.
    lifetime["childrenStopped"] = False
    if not lifetime["producerStopped"]:
        return False
    try:
        if kind == "mcp":
            stopped = mcp.confirm_mcp_stopped(control, lifetime)
        elif kind in ("plan", "local-image"):
            # These fixtures forbid tool requests; its app-server process group is the
            # only producer group and produce() confirms that group stopped.
            stopped = True
        else:
            stopped = hook.callbacks_stopped(hook.callback_rows(root, completed=False))
        lifetime["childrenStopped"] = stopped is True
    except Exception:
        pass
    return lifetime["childrenStopped"]


def all_source_processes_stopped(lifetime):
    return all(lifetime.get(key) is True for key in
        ("producerStopped", "childrenStopped", "descriptorReaderStopped"))


def prepare_fixture(kind, root, home, work, control, model):
    require(kind in PROFILES, "known-fixture-required")
    control.mkdir(mode=0o700)
    if kind == "mcp":
        script = ROOT / "Tests/CodexMCPSourceProbe/fixture.py"
        shared.write_new(home / "config.toml", mcp.fixture_configuration(model, script, control))
    elif kind == "hook-prompt":
        (root / "callbacks").mkdir(mode=0o700)
        shared.write_new(work / "fixture.py", (ROOT / "Tests/CodexHookPromptProbe/fixture.py").read_bytes())
        command = "exec " + shlex.join([sys.executable, str(work / "fixture.py"), "hook"])
        shared.write_json(home / "hooks.json", {"hooks": {"Stop": [{"hooks": [{"type": "command",
            "command": command, "timeout": 3, "statusMessage": "Spillcheck fake native input probe"}]}]}})
    if kind == "local-image":
        shared.write_new(work / "fixture.png", media.png_fixture())
    if kind != "mcp":
        shared.write_new(home / "config.toml", (f'model = "{model}"\nweb_search = "disabled"\n'
            '[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())


def run_producer(kind, executable, home, work, root, model, lifetime, control):
    lifetime["childrenStopped"] = False
    try:
        if kind == "local-image":
            observed, public = media.produce(executable, model, root, home, work, lifetime, control)
            require(public.get("nativeLocalImageInputCompleted") is True and public.get("normalProducerShutdown") is True
                and public.get("finalReplyExact") is True and shared.exact_int(public.get("unexpectedToolRequests"), 0),
                "completed-genuine-native-local-image-required")
            return {"threadID": observed.thread, "turnID": observed.turn, "liveItemID": observed.user_item}, public
        if kind == "plan":
            observed, public = plan.produce(executable, model, root, home, work, lifetime, control)
            return plan_descriptor(observed, public), public
        if kind == "mcp":
            observed, public = mcp.produce(executable, model, root, home, work, lifetime, control)
            require(public.get("nativeMCPCompleted") is True and public.get("normalProducerShutdown") is True
                and shared.exact_int(public.get("completedMCPCount"), 1)
                and shared.exact_int(public.get("unexpectedToolRequests"), 0)
                and public.get("protocolTextAndOpaqueBusinessResultMatched") is True,
                "completed-genuine-native-mcp-required")
            require(mcp.confirm_mcp_stopped(control, lifetime, require_invocation=True), "mcp-child-unconfirmed")
            descriptor = {"schemaVersion": 1, "fixtureKind": kind, "threadID": observed.thread,
                "turnID": observed.turn, "itemID": observed.mcp["itemID"], "producerVersion": mcp.VERSION,
                "hookRunID": "", "segments": expected_segments(kind)}
            return validate_descriptor(descriptor, kind), public
        identity, public = hook.produce(executable, root, lifetime, control)
        require(hook.identity_gate(identity, root) and all(public.get(key) is True for key in (
            "normalOneHookReviewObserved", "normalTrustObserved", "postTrustDetailsObserved", "normalProducerShutdown",
            "ownRuntimeIdentityRecorded", "hookDefinitionUnchangedAfterTrust", "reasonAbsentHumanPrompts"))
            and shared.exact_int(public.get("callbackCount"), 3)
            and shared.exact_int(public.get("oneShotBlockCount"), 1)
            and shared.exact_int(public.get("activeContinuationCount"), 1), "completed-genuine-stop-continuation-required")
        return identity, public
    finally:
        refresh_children(kind, root, control, lifetime)


def discover_hook_descriptor(executable, home, root, control, identity, scratch_path, lifetime):
    # Metadata discovery after auth removal; the signed worker independently
    # verifies the actual native item on the same response it normalizes.
    require(not (home / "auth.json").exists() and not (home / "auth.json").is_symlink()
        and all_source_processes_stopped(lifetime), "auth-and-source-shutdown-required-before-discovery")
    report_path = control / "passive-report.json"
    descriptor_path = root / "native-content-descriptor.json"
    env = dict(os.environ)
    env.update(hook.common.environment(root, home))
    env.update({"SPILLCHECK_HOOK_PROBE_HOME": str(home), "SPILLCHECK_HOOK_PROBE_THREAD": identity["threadID"],
        "SPILLCHECK_HOOK_PROBE_SELECTION": str(control / "owned-native-selection.json"),
        "SPILLCHECK_HOOK_PROBE_EXECUTABLE": str(executable), "SPILLCHECK_HOOK_PROBE_REPORT": str(report_path),
        "SPILLCHECK_HOOK_PROBE_DESCRIPTOR": str(descriptor_path)})
    stopped = {}
    lifetime["descriptorReaderStopped"] = False
    try:
        code, _, _ = shared.live.bounded(["/usr/bin/swift", "test", "--scratch-path", str(scratch_path),
            "--skip-build", "--no-parallel", "--filter", "CodexHookPromptLiveTests"], environment=env,
            directory=ROOT, timeout=90, maximum_bytes=hook.MAXIMUM, cleanup_report=stopped)
    finally:
        lifetime["descriptorReaderStopped"] = (stopped.get("leaderExited") is True
            and stopped.get("groupKillPermissionDenied") is False)
        refresh_children("hook-prompt", root, control, lifetime)
    require(code == 0 and all_source_processes_stopped(lifetime), "descriptor-reader-shutdown-unconfirmed")
    public = hook.common.decode(hook.common.private_bytes(report_path))
    require(hook.passive_gate(public), "genuine-hook-descriptor-discovery-unverified")
    raw = mcp.private_bytes(descriptor_path, 8192)
    descriptor = validate_descriptor(mcp.decode(raw), "hook-prompt")
    require(raw == descriptor_bytes(descriptor) and descriptor["threadID"] == identity["threadID"],
        "exact-owned-native-hook-descriptor-required")
    return descriptor, hook.public_passive(public)


def media_descriptor(value):
    require(isinstance(value, dict) and set(value) == {"schemaVersion", "threadID", "turnID", "itemID",
        "producerVersion", "textSHA256", "textBytes", "imageSHA256"}, "fixed-local-image-descriptor-required")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
        and media.base.opaque_id(value["threadID"]) and re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", value["threadID"]) is not None
        and media.base.opaque_id(value["turnID"]) and media.base.opaque_id(value["itemID"])
        and value["producerVersion"] == media.VERSION and value["textSHA256"] == media.digest(media.PROMPT.encode())
        and type(value["textBytes"]) is int and value["textBytes"] == len(media.PROMPT.encode())
        and value["imageSHA256"] == media.digest(media.png_fixture()), "owned-native-identity-and-fixed-bytes-required")
    return validate_descriptor({"schemaVersion": 1, "fixtureKind": "local-image",
        "threadID": value["threadID"], "turnID": value["turnID"], "itemID": value["itemID"],
        "producerVersion": value["producerVersion"], "hookRunID": "", "segments": expected_segments("local-image"),
        "imageSHA256": value["imageSHA256"]}, "local-image")


def remove_image(work):
    image = work / "fixture.png"
    require(media.digest(media.base.private_bytes(image)) == media.digest(media.png_fixture()), "image-fixture-changed")
    image.unlink()
    require(not image.exists() and not image.is_symlink(), "image-removal-unconfirmed")
    return True


def discover_media_descriptor(executable, home, root, control, identity, scratch_path, lifetime):
    image = root / "work/fixture.png"
    require(not (home / "auth.json").exists() and not (home / "auth.json").is_symlink()
        and not image.exists() and not image.is_symlink() and all_source_processes_stopped(lifetime),
        "auth-image-and-source-shutdown-required-before-discovery")
    report_path = control / "passive-report.json"
    descriptor_path = root / "local-media-descriptor.json"
    env = dict(os.environ)
    env.update(media.base.environment(root, home))
    for key, value in {"HOME": str(home), "THREAD": identity["threadID"], "TURN": identity["turnID"],
        "LIVE_ITEM": identity["liveItemID"], "EXECUTABLE": str(executable), "REPORT": str(report_path),
        "TEXT_SHA256": media.digest(media.PROMPT.encode()), "TEXT_BYTES": str(len(media.PROMPT.encode())),
        "IMAGE_SHA256": media.digest(media.png_fixture()), "DESCRIPTOR": str(descriptor_path)}.items():
        env["SPILLCHECK_LOCAL_MEDIA_PROBE_" + key] = value
    stopped = {}
    lifetime["descriptorReaderStopped"] = False
    try:
        code, _, _ = shared.live.bounded(["/usr/bin/swift", "test", "--scratch-path", str(scratch_path),
            "--skip-build", "--no-parallel", "--filter", "CodexLocalMediaLiveTests"], environment=env,
            directory=ROOT, timeout=90, maximum_bytes=media.base.MAXIMUM, cleanup_report=stopped)
    finally:
        lifetime["descriptorReaderStopped"] = (stopped.get("leaderExited") is True
            and stopped.get("groupKillPermissionDenied") is False)
        refresh_children("local-image", root, control, lifetime)
    require(code == 0 and all_source_processes_stopped(lifetime), "descriptor-reader-shutdown-unconfirmed")
    public = media.base.decode(media.base.private_bytes(report_path))
    require(media.passive_gate(public), "genuine-local-image-descriptor-discovery-unverified")
    raw = media.base.private_bytes(descriptor_path, 8192)
    original = media.base.decode(raw)
    descriptor = media_descriptor(original)
    require(raw == json.dumps(original, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() and descriptor["threadID"] == identity["threadID"]
        and descriptor["turnID"] == identity["turnID"], "exact-owned-native-image-descriptor-required")
    fields = media.PASSIVE_CHECKS | set(media.COUNTS) | media.LIMITS | {"status", "parserContract", "readerVersion",
        "producerVersion", "textSHA256", "textBytes", "suppliedImageSHA256", "liveItemIDMatchesNative", "timestampBasis",
        "gapReasons", "gapDiagnostics"}
    return descriptor, {key: public[key] for key in sorted(fields)}


def deliver(helper, root, native, fixture, lifetime):
    require(fixture in PROFILES, "known-fixture-required")
    cleanup = {}
    lifetime["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "codex", "--interface", "standalone-cli", "--profile-id", PROFILES[fixture]],
            environment=dict(os.environ), directory=ROOT, timeout=5, maximum_bytes=1024,
            input_bytes=inventory.initial_history_request(native), cleanup_report=cleanup)
    finally:
        lifetime["stopped"] = cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
    require(code == 0 and output.strip() == b"{}" and lifetime["stopped"], "helper-lifetime-unconfirmed")

def state(report):
    value = report.get("recoveryNativeContentState")
    if (report.get("recoveryNativeContentEnabled") is not True or report.get("recoveryNativeContentFailure") is not None
            or not isinstance(value, dict) or value.get("measured") is not True or value.get("truncated") is not False
            or value.get("cleanInventory") is not True or value.get("parserContract") != PARSER
            or value.get("fixtureKind") not in PROFILES
            or value.get("nativeKindEvidence") != "same-response-native-content-descriptor"
            or value.get("detectorVersion") != DETECTOR or not shared.exact_int(value.get("payloadRowCount"), 0)
            or any(type(value.get(key)) is not bool for key in
                ("initialStoreEmpty", "allObservedTargetSourcesCommitted", "nativeTargetVerified"))):
        return None
    for key in (*STATE_DIGESTS, *TARGET_DIGESTS, *INITIAL_DIGESTS):
        values = inventory.digest_values(value.get(key))
        if values is None or len(values) > 128:
            return None
    if not set(value["targetReceiptDigests"]).issubset(value["receiptDigests"]):
        return None
    for key in ("receiptCount", "sourceCount", "sessionCount", "conversationLabelCount", "observedTargetSourceCount",
                "committedTargetSourceCount", "batchCount", "nativeReadCount"):
        if type(value.get(key)) is not int or not 0 <= value[key] <= 128:
            return None
    if (value["receiptCount"] != len(value["receiptDigests"])
            or value["sourceCount"] != len(value["sourceKindDigests"])
            or len(value["sourceTimeDigests"]) != value["sourceCount"]
            or value["conversationLabelCount"] != len(value["conversationLabelDigests"])
            or len(value["targetSourceDigests"]) != value["observedTargetSourceCount"]
            or len(value["targetResultDigests"]) != value["observedTargetSourceCount"]
            or len(value["targetReceiptDigests"]) != value["committedTargetSourceCount"]):
        return None
    for key, maximum in (("targetSegmentCount", 128), ("targetTextBytes", 16384)):
        if type(value.get(key)) is not int or not 0 <= value[key] <= maximum:
            return None
    for key in ("readerVersions", "producerVersions"):
        if (not isinstance(value.get(key), list) or len(value[key]) > 128
                or any(not isinstance(item, str) or not 0 < len(item) <= 256 for item in value[key])):
            return None
    if value["fixtureKind"] == "local-image":
        excluded = inventory.digest_values(value.get("expectedExcludedGapDigests"))
        if (value.get("onlyExpectedExcludedMedia") is not True or excluded is None
                or type(value.get("excludedGapEventCount")) is not int or not 0 <= value["excludedGapEventCount"] <= 128
                or type(value.get("expectedExcludedGapCount")) is not int or value["expectedExcludedGapCount"] not in (0, 1)
                or len(excluded) != value["expectedExcludedGapCount"]
                or ((value["excludedGapEventCount"] == 0) != (value["expectedExcludedGapCount"] == 0))):
            return None
    return value


def ready(report):
    return (inventory.source_ready(report) and report.get("gapReasons") == [] and state(report) is not None
        and shared.exact_int(report.get("valueCount"), 0) and shared.exact_int(report.get("occurrenceCount"), 0)
        and all(shared.digest_set(report, key, empty=True) is not None for key in shared.DIGEST_KEYS))


def fresh(report, fixture):
    value = state(report)
    return (ready(report) and value["fixtureKind"] == fixture
        and (fixture != "local-image" or value["expectedExcludedGapCount"] == value["excludedGapEventCount"] == 0)
        and value["initialStoreEmpty"] is True and value["nativeTargetVerified"] is False
        and value["allObservedTargetSourcesCommitted"] is False
        and all(value[key] == [] for key in (*STATE_DIGESTS, *TARGET_DIGESTS, *INITIAL_DIGESTS))
        and all(value[key] == 0 for key in ("receiptCount", "sourceCount", "sessionCount", "conversationLabelCount",
            "observedTargetSourceCount", "committedTargetSourceCount", "batchCount", "nativeReadCount",
            "targetSegmentCount", "targetTextBytes"))
        and value["readerVersions"] == value["producerVersions"] == []
        and all(shared.digest_set(report, key, empty=True) == set() for key in
            (*shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests")))


def scanned(report, version, descriptor):
    value = state(report)
    return (ready(report) and value["fixtureKind"] == descriptor["fixtureKind"]
        and (value["fixtureKind"] != "local-image" or (value["expectedExcludedGapCount"] == 1 and value["excludedGapEventCount"] >= 1))
        and value["sessionCount"] == value["conversationLabelCount"] == 1
        and value["receiptCount"] == value["sourceCount"] > 0
        and value["observedTargetSourceCount"] == value["committedTargetSourceCount"] == 1
        and value["allObservedTargetSourcesCommitted"] is True and value["nativeTargetVerified"] is True
        and 0 < value["batchCount"] <= 128 and 0 < value["nativeReadCount"] <= 128
        and value["targetSegmentCount"] == len(descriptor["segments"])
        and value["targetTextBytes"] == sum(segment["textBytes"] for segment in descriptor["segments"])
        and value["readerVersions"] == [version] and value["producerVersions"] == [descriptor["producerVersion"]])


def stable_store(before, after):
    left, right = state(before), state(after)
    return (left is not None and right is not None and ready(after)
        and shared.manifest_digest(before) is not None and shared.manifest_digest(before) == shared.manifest_digest(after)
        and all(left.get(key) == right.get(key) for key in ("expectedExcludedGapCount", "expectedExcludedGapDigests"))
        and all(left[key] == right[key] for key in ("fixtureKind", "receiptCount", "sourceCount", "sessionCount", "conversationLabelCount"))
        and all(inventory.digest_values(left[key]) == inventory.digest_values(right[key]) for key in STATE_DIGESTS)
        and all(shared.digest_set(before, key, empty=True) == shared.digest_set(after, key, empty=True)
            for key in shared.DIGEST_KEYS))


def cold_restored(before, after):
    value = state(after)
    # Consumed identities come from durable capture_receipts. Only successfully
    # processed observations reset with the worker process; neither may be lost
    # or newly manufactured while restoring the store before any native read.
    consumed = shared.digest_set(before, "recoveryConsumedCaptureDigests")
    return (stable_store(before, after) and value["initialStoreEmpty"] is False
        and value["observedTargetSourceCount"] == value["committedTargetSourceCount"] == value["batchCount"] == value["nativeReadCount"] == 0
        and value["nativeTargetVerified"] is False and value["allObservedTargetSourcesCommitted"] is False
        and all(value[key] == [] for key in TARGET_DIGESTS)
        and value["targetSegmentCount"] == value["targetTextBytes"] == 0
        and value["readerVersions"] == value["producerVersions"] == []
        and all(inventory.digest_values(value[initial]) == inventory.digest_values(state(before)[current])
            for initial, current in zip(INITIAL_DIGESTS, STATE_DIGESTS))
        and consumed is not None and shared.digest_set(after, "recoveryConsumedCaptureDigests") == consumed
        and shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests", empty=True) == set())


def replayed(baseline, cold, after, version, descriptor):
    replay = after.get("recoveryNativeContentReplay")
    if (not scanned(after, version, descriptor) or not stable_store(baseline, after)
            or not inventory.new_single_processed_capture(cold, after) or not isinstance(replay, dict)
            or not all(replay.get(key) is True for key in ("controlConsumed", "queued", "cleanBatches",
                "allExpectedSourcesObserved", "completeProgress", "completionObserved", "workCompleted",
                "successfulReadMatched", "nativeTargetReadAfterControl"))
            or type(replay.get("batchCount")) is not int or not 0 < replay["batchCount"] <= 128
            or type(replay.get("bytesRead")) is not int or replay["bytesRead"] <= 0
            or not shared.exact_int(replay.get("expectedSourceCount"), state(baseline)["sourceCount"])
            or not shared.exact_int(replay.get("observedSourceCount"), state(baseline)["sourceCount"])):
        return False
    capture, audit = inventory.digest_values([replay.get("captureDigest")]), inventory.digest_values([replay.get("auditDigest")])
    return (capture is not None and audit is not None and capture.isdisjoint(audit)
        and capture == (shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
            - shared.digest_set(cold, "recoverySuccessfullyProcessedCaptureDigests", empty=True))
        and all(inventory.digest_values(state(baseline)[key]) == inventory.digest_values(state(after)[key]) for key in TARGET_DIGESTS)
        and all(state(baseline)[key] == state(after)[key] for key in ("targetSegmentCount", "targetTextBytes")))


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", choices=sorted(PROFILES), required=True)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build")
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
    require(args.fixture in PROFILES and args.expected_version == mcp.VERSION, "pinned-native-fixture-required")
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
    # The HookPrompt reader also enforces this exact owned-root prefix.
    prefix = "spillcheck-native-" + {"hook-prompt": "hook", "local-image": "local-media"}.get(args.fixture, args.fixture) + "-"
    with shared.AcceptanceArtifacts(prefix, args.output) as artifacts:
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
            "producerProcessHandoff": str(root / "producer-control/producer-process.json"),
            "nativeContentDescriptor": str(root / "native-content-descriptor.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False,
            "fixtureKind": args.fixture, "independentChildren": {"mcp": "MCP-process",
                "hook-prompt": "recorded-Stop-callbacks", "plan": "no-tools-producer-process-group",
                "local-image": "no-tools-producer-process-group"}[args.fixture],
            "protectionCleanupReportField": "ownedProtectionCleanupPending", "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-one-owned-native-content-scan-and-replay", "passed": False,
            "startedAtUnixSeconds": time.time(),
            "candidateBundleSHA256": args.expected_bundle_sha256, "readerVersion": args.expected_version,
            "candidateManifestSHA256": manifest_hash,
            "producerVersion": args.expected_version, "fixtureKind": args.fixture,
            "model": args.model, "providerLaunchCount": 0,
            "selectedThreadCount": 0, "syntheticInitialQueueAdmission": True,
            "initialAdmissionKind": "exact-selected-source-historical-audit", "providerHookDispatchEstablished": False,
            "personalHistoryRead": False, "personalConfigurationChanged": False, "rawProviderOutputRetained": False,
            "webCallsExpected": 0, "toolCallsExpected": 0 if args.fixture in ("plan", "local-image") else 1,
            "receiptSeedingUsed": False, "knownSecretRecallEstablished": False,
            "secondDetectorScanEstablished": False, "attachmentContentScanned": False, "localAudioAcceptance": False,
            "systemNotificationDeliveryEstablished": False,
            "fullCodexAcceptance": False, "T3Acceptance": False, "desktopAcceptance": False,
            "sideChatCoverageEstablished": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "savedProfileRecoveryEstablished": False,
            "schemaMigrationEstablished": False, "providerUpgradeEstablished": False, "crashRecoveryEstablished": False,
            "checks": {}}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready, auth_removed, successful, final = False, True, False, {}
        source_lifetime, helper_lifetime, version_cleanup = producer_lifetime(), {"stopped": True}, {}
        source, native, descriptor_hash, phase = None, None, None, "reader-version"
        descriptor_path = root / "native-content-descriptor.json"
        control = root / "producer-control"
        version_stopped = False
        try:
            try:
                version = shared.live.observe_version(reader, environment=mcp.environment(root, home),
                    directory=work, expected=args.expected_version, cleanup_report=version_cleanup)
            finally:
                version_stopped = (version_cleanup.get("leaderExited") is True
                    and version_cleanup.get("groupKillPermissionDenied") is False)
            checks["readerVersionObservedBeforeProvider"] = version == args.expected_version
            require(version_stopped, "version-process-lifetime-unconfirmed")
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
            prepare_fixture(args.fixture, root, home, work, control, args.model)
            phase = "one-fake-native-source"
            require(owner.process.poll() is None, "fresh-owner-lost")
            try:
                produced, producer_report = run_producer(args.fixture, reader, home, work, root,
                    args.model, source_lifetime, control)
            finally:
                refresh_children(args.fixture, root, control, source_lifetime)
                if all_source_processes_stopped(source_lifetime):
                    auth_removed = remove_auth(home, home_identity)
            require(all_source_processes_stopped(source_lifetime) and auth_removed,
                "producer-child-or-auth-cleanup-unconfirmed")
            if args.fixture == "hook-prompt":
                phase = "exact-native-hook-descriptor-discovery"
                descriptor, discovery = discover_hook_descriptor(reader, home, root, control, produced,
                    args.scratch_path, source_lifetime)
                report["descriptorDiscovery"] = discovery
            elif args.fixture == "local-image":
                checks["fakeImageRemovedBeforeSignedReads"] = remove_image(work)
                phase = "exact-native-local-image-descriptor-discovery"
                descriptor, discovery = discover_media_descriptor(reader, home, root, control, produced,
                    args.scratch_path, source_lifetime)
                report["descriptorDiscovery"] = discovery
                shared.write_new(descriptor_path, descriptor_bytes(descriptor))
            else:
                descriptor = produced
                shared.write_new(descriptor_path, descriptor_bytes(descriptor))
            native = descriptor["threadID"]
            descriptor_hash = shared.preflight.hash_file(root, descriptor_path.name, [0])
            report.update(selectedThreadCount=1, producer=producer_report)
            source = source_snapshot(home, home_identity, native)
            shared.write_json(root / "owned-source-private.json", {"nativeIdentitySource": {
                "mcp": "own-app-server-native-MCP-item", "plan": "own-app-server-native-plan-item",
                "hook-prompt": "own-runtime-session-and-exact-native-hook-item",
                "local-image": "own-native-local-image-item-after-two-authless-passive-reads"}[args.fixture],
                "nativeID": native, "home": str(home), "source": source, "descriptorSHA256": descriptor_hash})
            checks["oneOwnedNativeFixtureCompleted"] = True
            checks["temporaryAuthRemovedBeforeSignedReads"] = auth_removed
            checks["descriptorDiscoveryReaderStopped"] = source_lifetime["descriptorReaderStopped"]
            checks["sourcePinnedBeforeSignedRead"] = True
            def launch(name):
                require(owner.process.poll() is None, "fresh-owner-lost")
                require(refresh_children(args.fixture, root, control, source_lifetime)
                    and all_source_processes_stopped(source_lifetime), "source-children-live-before-signed-read")
                worker = setup.ReportProcess(worker_command(binary, root, name, home=home, descriptor=descriptor_path,
                    reader=reader, version=version, fixture=args.fixture))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                return worker

            phase = "fresh-full-native-source-scan"
            worker1 = launch("worker1")
            empty = worker1.wait_report(root / "worker1-report.json", lambda value: fresh(value, args.fixture),
                "fresh-empty-worker-unavailable")
            checks["noReceiptsOrSourcesBeforeInitialAdmission"] = True
            deliver(helper, root, native, args.fixture, helper_lifetime)
            baseline = worker1.wait_report(root / "worker1-report.json", lambda value:
                scanned(value, version, descriptor) and inventory.new_single_processed_capture(empty, value),
                "native-source-full-scan-receipts-unverified", timeout=75)
            checks["exactNativeTargetBytesHaveFullCurrentDetectorReceipts"] = True
            baseline = inventory.finish_worker(worker1, root, "worker1", lambda value:
                scanned(value, version, descriptor) and stable_store(baseline, value))
            checks["initialWorkerNormalShutdown"] = True
            require(refresh_children(args.fixture, root, control, source_lifetime), "source-children-live-after-initial-read")
            checks["sourceUnchangedAfterInitialRead"] = source_snapshot(home, home_identity, native) == source
            phase = "cold-restart-and-exact-reread"
            worker2 = launch("worker2")
            cold = worker2.wait_report(root / "worker2-report.json", lambda value:
                cold_restored(baseline, value), "full-receipts-not-restored-before-reread")
            checks["fullReceiptsAndSourceStateSurviveColdRestart"] = True
            replay = cold.get("recoveryNativeContentReplay")
            require(isinstance(replay, dict) and replay.get("controlConsumed") is False
                and replay.get("queued") is False and cold.get("recoveryProcessingStopped") is False,
                "fresh-replay-control-required")
            shared.write_new(root / REPLAY_CONTROL, token)
            replay_result = worker2.wait_report(root / "worker2-report.json", lambda value:
                replayed(baseline, cold, value, version, descriptor), "cold-native-source-reread-unverified", timeout=75)
            checks["coldForcedExactAuditRereadsSameNativeTargetBytes"] = True
            checks["replayPreservesExactFullReceiptsWithoutDuplicates"] = True
            final = inventory.finish_worker(worker2, root, "worker2", lambda value:
                replayed(baseline, cold, value, version, descriptor))
            if args.fixture == "local-image":
                checks["exactMediaExclusionPersistedAndReplayed"] = True
            checks["twoDistinctWorkersNormalShutdown"] = len({worker.process.pid for worker in workers}) == 2
            checks["finalQueueEmptyWithoutGaps"] = ready(final)
            require(refresh_children(args.fixture, root, control, source_lifetime), "source-children-live-after-cold-read")
            checks["sourceUnchangedAfterColdReplay"] = source_snapshot(home, home_identity, native) == source
            checks["exactOwnedDescriptorUnchanged"] = shared.preflight.hash_file(root, descriptor_path.name, [0]) == descriptor_hash
            successful = all(checks.values())
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError,
                subprocess.SubprocessError, mcp.ProbeFailure, hook.ProbeFailure, plan.ProbeFailure, media.base.ProbeFailure) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            report["providerLaunchCount"] = source_lifetime["providerLaunchCount"]
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            refresh_children(args.fixture, root, control, source_lifetime)
            if all_source_processes_stopped(source_lifetime) and owned_home(home, home_identity):
                try:
                    auth_removed = remove_auth(home, home_identity)
                except (OSError, RuntimeError):
                    auth_removed = False
            normal = shared.safe_creator_cleanup(shutdowns,
                helper_stopped=helper_lifetime["stopped"] and all_source_processes_stopped(source_lifetime) and version_stopped,
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
            checks["independentProducerChildrenStopped"] = source_lifetime["childrenStopped"]
            checks["descriptorDiscoveryReaderStopped"] = source_lifetime["descriptorReaderStopped"]
            checks["originalFreshCreatorCleanupPassed"] = (owner_report.get("createdFreshVault") is True
                and owner_report.get("cleanupPassed") is True)
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped and all_source_processes_stopped(source_lifetime)
                and helper_lifetime["stopped"] and version_stopped and all(row["groupStopped"] for row in shutdowns) and bool(groups)
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
                "observedTargetSourceCount": value["observedTargetSourceCount"] if value else None,
                "targetSegmentCount": value["targetSegmentCount"] if value else None,
                "targetTextBytes": value["targetTextBytes"] if value else None,
                "fullReceiptCount": value["receiptCount"] if value else None,
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons")}
            report["passed"] = successful and "unmetGate" not in report and completed_checks(checks, args.fixture)
            report["signedNativeContentReceiptRestartAndReplayEstablished"] = report["passed"]
            report["finishedAtUnixSeconds"] = time.time()
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        # Unexpected finalization failures can also reach here after a launch.
        # The retained run artifacts, not this fallback, describe exact cleanup.
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "runner-unavailable", "cleanupEstablished": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
