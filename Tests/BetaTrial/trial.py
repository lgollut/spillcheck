#!/usr/bin/env python3
"""Record content-free daily beta measurements and summarize their denominators."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile

PROVIDERS = ("codex", "claude")
HOSTS = ("cli", "t3", "desktop")
TYPES = ("userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError")
COUNTS = ("expectedItems", "collectedItems", "expectedValues", "collectedValues", "normalizedValues",
    "detectedValues", "visibleValues", "confirmedFindings", "falsePositiveFindings", "unreviewedFindings",
    "duplicateOccurrences", "duplicateAlerts")
SEEDED_COUNTS = COUNTS[:7]
RESOURCES = ("queueDepth", "oldestPendingSeconds", "cpuPercent", "rssMiB", "storageMiB")
MAX_COUNT, MAX_ROWS, MAX_SAMPLES, MAX_BYTES = 10000000, 366 * 30, 4096, 8 * 1024 * 1024
CODEX_SCOPE = "codex-beta-v1"
CLAUDE_SCOPE = "claude-beta-v1"
FULL_SCOPE = "all-providers"
SCOPED_PROVIDERS = {CODEX_SCOPE: "codex", CLAUDE_SCOPE: "claude"}
CODEX_EXCLUSIONS = ("automaticEphemeralSideChats", "encryptedIncomingSubagentInstructions",
    "generalHookInjectedContext", "binaryMediaAnalysis")
CLAUDE_EXCLUSIONS = ("desktopSideQuestions", "claudeChat", "cowork", "remoteCode", "binaryMediaAnalysis")


class Invalid(ValueError): pass


def candidate_digest(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise Invalid("candidateBundleSHA256MustBeLowercaseHex")
    return value


def new_log(bundle_sha256, *, scope=FULL_SCOPE):
    if scope not in (FULL_SCOPE, CODEX_SCOPE, CLAUDE_SCOPE): raise Invalid("scopeMustUseFixedEnums")
    value = {"schemaVersion": 2, "candidateBundleSHA256": candidate_digest(bundle_sha256), "days": []}
    if scope != FULL_SCOPE: value.update(schemaVersion=3, scope=scope)
    return value


def numeric(value, maximum=MAX_COUNT):
    return type(value) in (int, float) and 0 <= value <= maximum and math.isfinite(value)


def valid_row(row):
    required = {"date", "provider", "host", "contentType", "counts", "latencyMilliseconds", "resources"}
    if not isinstance(row, dict) or set(row) != required: raise Invalid("rowSchemaRejected")
    try:
        day = datetime.date.fromisoformat(row["date"])
        if day.isoformat() != row["date"]: raise ValueError()
    except (ValueError, TypeError, RecursionError): raise Invalid("dateMustBeISOCalendarDate")
    if row["provider"] not in PROVIDERS or row["host"] not in HOSTS or row["contentType"] not in TYPES:
        raise Invalid("scopeMustUseFixedEnums")
    counts = row["counts"]
    if not isinstance(counts, dict) or set(counts) != set(COUNTS): raise Invalid("countSchemaRejected")
    if any(type(value) is not int or not 0 <= value <= MAX_COUNT for value in counts.values()):
        raise Invalid("countsMustBeBoundedNonnegativeIntegers")
    if counts["collectedItems"] > counts["expectedItems"]: raise Invalid("collectedItemsExceedExpected")
    stages = [counts[name] for name in ("expectedValues", "collectedValues", "normalizedValues", "detectedValues", "visibleValues")]
    if stages != sorted(stages, reverse=True): raise Invalid("seededStagesMustBeNested")
    if not counts["expectedItems"] and counts["expectedValues"]: raise Invalid("expectedValuesNeedExpectedItems")
    if not counts["collectedItems"] and counts["collectedValues"]: raise Invalid("collectedValuesNeedCollectedItems")
    if counts["collectedItems"] == counts["expectedItems"] and counts["collectedValues"] != counts["expectedValues"]:
        raise Invalid("allCompleteItemsCollectedMustIncludeTheirExpectedValues")
    samples = row["latencyMilliseconds"]
    if not isinstance(samples, list) or len(samples) > MAX_SAMPLES or any(not numeric(n, 86400000) for n in samples):
        raise Invalid("latencySamplesMustBeBoundedMilliseconds")
    resources = row["resources"]
    if not isinstance(resources, dict) or not set(resources) <= set(RESOURCES): raise Invalid("resourceSchemaRejected")
    if any(not numeric(value) for value in resources.values()): raise Invalid("resourcesMustBeBoundedNonnegativeNumbers")
    if "queueDepth" in resources and type(resources["queueDepth"]) is not int: raise Invalid("queueDepthMustBeInteger")
    return row


def row_key(row):
    return tuple(row[name] for name in ("date", "provider", "host", "contentType"))


def validate_log(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] not in (1, 2, 3):
        raise Invalid("logSchemaRejected")
    expected = {"schemaVersion", "days"} | ({"candidateBundleSHA256"} if value["schemaVersion"] >= 2 else set())
    if value["schemaVersion"] == 3: expected.add("scope")
    if set(value) != expected: raise Invalid("logSchemaRejected")
    if value["schemaVersion"] >= 2: candidate_digest(value["candidateBundleSHA256"])
    if value["schemaVersion"] == 3 and value["scope"] not in (CODEX_SCOPE, CLAUDE_SCOPE):
        raise Invalid("scopeMustUseFixedEnums")
    rows = value["days"]
    if not isinstance(rows, list) or len(rows) > MAX_ROWS: raise Invalid("rowLimitExceeded")
    seen = set()
    for row in rows:
        valid_row(row)
        if value["schemaVersion"] == 3 and row["provider"] != SCOPED_PROVIDERS[value["scope"]]:
            raise Invalid("rowOutsideDeclaredScope")
        key = row_key(row)
        if key in seen: raise Invalid("duplicateDailyScope")
        seen.add(key)
    return value


def read_log(path):
    try: file = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError: raise Invalid("logNotInitialized") from None
    try:
        info = os.fstat(file)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_BYTES:
            raise Invalid("logOwnershipTypeOrBudget")
        raw = os.read(file, MAX_BYTES + 1)
    finally: os.close(file)
    if len(raw) > MAX_BYTES: raise Invalid("logByteLimitExceeded")
    try: return validate_log(json.loads(raw))
    except (ValueError, TypeError, RecursionError) as error:
        if isinstance(error, Invalid): raise
        raise Invalid("logJSONRejected") from None


def write_log(path, log, *, create_only=False):
    validate_log(log)
    raw = (json.dumps(log, indent=2, allow_nan=False) + "\n").encode()
    if len(raw) > MAX_BYTES: raise Invalid("logByteLimitExceeded")
    path.parent.mkdir(parents=True, exist_ok=True)
    # Refuse a symlink destination, even though replacing it would not write
    # through the link. A typo must not replace an unrelated user's artifact.
    if path.is_symlink(): raise Invalid("logSymlinkRejected")
    file, name = tempfile.mkstemp(prefix=".beta-trial-", dir=path.parent)
    try:
        with os.fdopen(file, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        if create_only:
            # Publish the complete private file only if no artifact already owns
            # this name. An existing legacy log cannot acquire new provenance.
            try: os.link(name, path)
            except FileExistsError: raise Invalid("logAlreadyExists") from None
        else: os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def record(log, row, bundle_sha256):
    validate_log(log)
    candidate_digest(bundle_sha256)
    if log["schemaVersion"] == 1: raise Invalid("legacyLogIsReadOnly")
    if log["candidateBundleSHA256"] != bundle_sha256: raise Invalid("candidateBundleMismatch")
    valid_row(row)
    previous = [item for item in log["days"] if row_key(item) != row_key(row)]
    return validate_log({**log, "days": sorted(previous + [row], key=row_key)})


def rate(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator,
        "ratio": numerator / denominator if denominator else None}


def percentile(samples, fraction):
    return sorted(samples)[max(0, math.ceil(len(samples) * fraction) - 1)] if samples else None


def metrics(rows):
    counts = {key: sum(row["counts"][key] for row in rows) for key in COUNTS}
    samples = [sample for row in rows for sample in row["latencyMilliseconds"]]
    misses = {"collection": counts["expectedValues"] - counts["collectedValues"],
        "normalization": counts["collectedValues"] - counts["normalizedValues"],
        "detection": counts["normalizedValues"] - counts["detectedValues"],
        "presentation": counts["detectedValues"] - counts["visibleValues"]}
    return {"dailySnapshotCount": len(rows), "counts": counts, "seededItemCollectionRecall": rate(counts["collectedItems"], counts["expectedItems"]),
        "seededValueDetectionRecallInCollectedContent": rate(counts["detectedValues"], counts["collectedValues"]),
        "seededValueEndToEndRecall": rate(counts["visibleValues"], counts["expectedValues"]),
        "precisionAmongReviewedFindings": rate(counts["confirmedFindings"], counts["confirmedFindings"] + counts["falsePositiveFindings"]),
        "unreviewedFindings": counts["unreviewedFindings"], "seededValueMissesByStage": misses,
        "latency": {"sampleCount": len(samples), "p50Milliseconds": percentile(samples, .5),
            "p95Milliseconds": percentile(samples, .95), "method": "nearestRank", "includesPollingDelay": True},
        "resourceObservations": {key: {"sampleCount": len(values), "minimum": min(values), "maximum": max(values)}
            for key in RESOURCES if (values := [row["resources"][key] for row in rows if key in row["resources"]])}}


def summarize(log):
    validate_log(log)
    rows = log["days"]
    days = sorted({row["date"] for row in rows})
    weekdays = [day for day in days if datetime.date.fromisoformat(day).weekday() < 5]
    providers = (SCOPED_PROVIDERS[log["scope"]],) if log["schemaVersion"] == 3 else PROVIDERS
    scopes = [{"provider": provider, "host": host, "contentType": content,
        **metrics([row for row in rows if (row["provider"], row["host"], row["contentType"]) == (provider, host, content)])}
        for provider in providers for host in HOSTS for content in TYPES]
    result = {"schemaVersion": 3 if log["schemaVersion"] == 3 else 2, "measurementScope": "manuallyEnteredDailySnapshots",
        "candidateBundleSHA256": log.get("candidateBundleSHA256"),
        "candidateAttribution": "recordedDigest" if log["schemaVersion"] >= 2 else "legacyUnbound",
        "candidateArtifactVerified": False,
        "trialAcceptanceEstablished": False, "loggedDates": days, "loggedWorkingDays": len(weekdays),
        "minimumFiveWorkingDaysLogged": len(weekdays) >= 5,
        "allSixRoutesHaveSeededObservations": all(any(row["provider"] == provider and row["host"] == host
            and row["counts"]["expectedItems"] > 0 for row in rows) for provider in PROVIDERS for host in HOSTS),
        "unseededRequiredScopes": [{key: scope[key] for key in ("provider", "host", "contentType")}
            for scope in scopes if not scope["counts"]["expectedItems"]],
        "overall": metrics(rows), "byScope": [scope for scope in scopes if scope["dailySnapshotCount"]]}
    if log["schemaVersion"] == 3:
        result.update(declaredScope=log["scope"], requiredProviders=list(providers), requiredHosts=list(HOSTS),
            scopeAttribution="operatorDeclaredAtInitialization",
            sourceClassMembershipVerified=False,
            allRequiredRoutesHaveSeededObservations=all(any(row["provider"] == provider and row["host"] == host
                and row["counts"]["expectedItems"] > 0 for row in rows) for provider in providers for host in HOSTS))
        if log["scope"] == CODEX_SCOPE:
            result.update(includedSourceClasses=["savedMainConversations", "readableNativeSubagentRepliesAndToolResults"],
                excludedSourceClasses=list(CODEX_EXCLUSIONS),
                runtimeUnverifiedContent=["partialAnswerMessages", "localAudioAccompanyingText"])
        else:
            result.update(includedSourceClasses=["savedMainConversations", "readableNativeSubagentConversations"],
                includedContentTypes=list(TYPES), excludedSourceClasses=list(CLAUDE_EXCLUSIONS),
                hostAttribution="operatorDeclaredPerSnapshot")
    return result


def flag(key):
    if key == "rssMiB": return "--rss-mib"
    if key == "storageMiB": return "--storage-mib"
    return "--" + "".join("-" + letter.lower() if letter.isupper() else letter for letter in key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True, help="Local count-only JSON artifact; its path is never logged.")
    commands = parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser("init", help="Create a fresh log bound to one candidate bundle digest; never relabel old data.")
    initialize.add_argument("--candidate-bundle-sha256", required=True)
    initialize.add_argument("--scope", choices=(FULL_SCOPE, CODEX_SCOPE, CLAUDE_SCOPE), default=FULL_SCOPE,
        help="Declare a fresh trial's fixed scope; existing logs are never narrowed.")
    entry = commands.add_parser("record", help="Replace the complete daily scope snapshot, never add it twice.")
    entry.add_argument("--candidate-bundle-sha256", required=True,
        help="Assert the candidate being measured; must match the log's immutable digest.")
    entry.add_argument("--date", required=True)
    entry.add_argument("--provider", choices=PROVIDERS, required=True)
    entry.add_argument("--host", choices=HOSTS, required=True)
    entry.add_argument("--content-type", choices=TYPES, required=True)
    for key in COUNTS: entry.add_argument(flag(key), dest=key, type=int, default=None if key in SEEDED_COUNTS else 0)
    entry.add_argument("--latency-ms", type=float, action="append", default=[])
    for key in RESOURCES: entry.add_argument(flag(key), dest=key, type=int if key == "queueDepth" else float)
    commands.add_parser("summary", help="Emit controlled measurements with explicit numerators and denominators.")
    args = parser.parse_args()
    if args.command == "record":
        stages = [getattr(args, key) for key in SEEDED_COUNTS]
        if any(value is not None for value in stages) and any(value is None for value in stages):
            parser.error("Supply all seven seeded item/value counts together; do not classify unknown stages as zero.")
    try:
        if args.command == "init":
            log = new_log(args.candidate_bundle_sha256, scope=args.scope)
            write_log(args.log, log, create_only=True)
            output = {"initialized": True, "candidateBundleSHA256": log["candidateBundleSHA256"], "dailyScopeCount": 0}
        elif args.command == "record":
            log = read_log(args.log)
            row = {"date": args.date, "provider": args.provider, "host": args.host, "contentType": args.content_type,
                "counts": {key: getattr(args, key) if getattr(args, key) is not None else 0 for key in COUNTS}, "latencyMilliseconds": args.latency_ms,
                "resources": {key: getattr(args, key) for key in RESOURCES if getattr(args, key) is not None}}
            updated = record(log, row, args.candidate_bundle_sha256)
            replaced = any(row_key(previous) == row_key(row) for previous in log["days"])
            write_log(args.log, updated)
            output = {"recorded": True, "candidateBundleSHA256": log["candidateBundleSHA256"],
                "replacedDailyScope": replaced, "dailyScopeCount": len(updated["days"])}
        else: output = summarize(read_log(args.log))
        print(json.dumps(output, indent=2, allow_nan=False))
    except (Invalid, OSError) as error:
        print(json.dumps({"recorded": False, "reason": str(error) if isinstance(error, Invalid) else "localLogUnavailable"}))
        return 1
    return 0


if __name__ == "__main__": raise SystemExit(main())
