#!/usr/bin/env python3
"""Summarize the controlled journal without exporting HMAC values or private paths."""
import argparse
import collections
import json
import os
from pathlib import Path
import stat
import journal

def summarize(path):
    file = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(file)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > journal.MAX_JOURNAL:
            raise ValueError("controlledJournalOwnershipTypeOrBudget")
        raw = os.read(file, journal.MAX_JOURNAL + 1)
    finally:
        os.close(file)
    if not raw.endswith(b"\n") or raw.count(b"\n") > journal.MAX_ROWS:
        raise ValueError("controlledJournalFramingOrBudget")
    rows = [json.loads(line) for line in raw.splitlines()]
    if not all(journal.valid(row) for row in rows):
        raise ValueError("controlledJournalSchemaRejected")
    events, markers, fields = collections.Counter(), collections.Counter(), {}
    comparisons = collections.defaultdict(lambda: collections.defaultdict(set))
    for row in rows:
        event = row["event"] + "." + row["phase"]
        if row.get("component"): event += "." + row["component"]
        events[event] += 1
        for marker in row.get("text", {}).get("markers", []):
            markers[marker] += 1
            for field, value in row["nativeIdentity"].items():
                if value.get("comparison"): comparisons[marker][field].add(value["comparison"])
        for field, value in row["nativeIdentity"].items():
            if value["present"]:
                fields.setdefault(event, collections.Counter())[field + "." + value["kind"]] += 1
    side_prompt, side_final = comparisons["LEAKRET_PHASE0_MODSIDE_PROMPT"], comparisons["LEAKRET_PHASE0_MODSIDE_FINAL"]
    main = comparisons["LEAKRET_PHASE0_MODMAIN_PROMPT"]["turnId"] | comparisons["LEAKRET_PHASE0_MODMAIN_FINAL"]["turnId"]
    side = side_prompt["turnId"] | side_final["turnId"]
    return {"schemaVersion": 1, "phase0Passed": False, "canonicalSideAuthorityEstablished": False,
        "journalRowCount": len(rows), "journalByteCount": len(raw), "maximumRowBudgetReached": len(rows) == journal.MAX_ROWS,
        "selectedSessionMatchesAllJournalRows": all(row["selectedSessionMatches"] for row in rows),
        "eventCounts": dict(events), "controlledMarkerCounts": dict(markers),
        "nativeFieldPresenceCountsByEvent": {event: dict(value) for event, value in fields.items()},
        "sidePromptAndFinalSharedTurnIDCount": len(side_prompt["turnId"] & side_final["turnId"]),
        "sidePromptAndFinalSharedAgentIDCount": len(side_prompt["agentId"] & side_final["agentId"]),
        "sideAndMainSharedTurnIDCount": len(side & main),
        "distinctTurnIDCountsByControlledMarker": {marker: len(value["turnId"]) for marker, value in comparisons.items()},
        "truncatedTextSummaryCount": sum(row["text"].get("truncated", False) for row in rows),
        "rawProviderTextExported": False, "rawNativeIdentitiesExported": False,
        "remainingGates": ["Exact observed-version API and event semantics", "Genuine side prompt and final dispatch",
            "Native side-to-main affiliation and canonical source authority", "Stable replay/restart/host identity",
            "Owned installation/removal and current unowned settings preservation", "Signed encrypted side ingestion"]}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journal", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = summarize(args.journal)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)

if __name__ == "__main__":
    main()
