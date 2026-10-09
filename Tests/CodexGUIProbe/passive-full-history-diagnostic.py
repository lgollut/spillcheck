#!/usr/bin/env python3
"""Inspect documented passive full-history reads of two exact owned GUI sources."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

MAX_BYTES = 8 * 1024 * 1024
MARKER = "SPILLCHECK_GUI_CHILD_PROMPT"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--authorized-home", type=Path, required=True)
    parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    project, home = args.project.resolve(), args.authorized_home.resolve()
    selections = {}
    for role in ("parent", "child"):
        data = (project / (role + "-identity.json")).read_bytes()
        if len(data) > 8192:
            raise ValueError("owned-identity-manifest-limit")
        value = json.loads(data)
        if value["nativeIdentitySource"] != "own-runtime-CODEX_THREAD_ID" or Path(value["workingDirectory"]).resolve() != project or Path(value["storeCandidate"]).resolve() != home:
            raise ValueError("runtime-selection-or-store-mismatch")
        selections[role] = value["nativeThreadID"]
    if selections["parent"] == selections["child"]:
        raise ValueError("native-child-identity-not-distinct")
    report = {"passed": False, "sourceHost": "official-codex-GUI", "phase0Passed": False,
        "scope": "exact-selected-parent-and-child-passive-public-history-only-after-producer",
        "noUnrelatedHistoryEnumeration": True, "noOriginalSourceArchive": True,
        "noProviderTurnsOrSettingsChanges": True, "productionGUICollectionEnabled": False}
    with tempfile.TemporaryDirectory(prefix="spillcheck-exact-full-history-") as temporary:
        private = Path(temporary)
        private.chmod(0o700)
        environment = {"PATH": "/usr/bin:/bin", "HOME": temporary, "CODEX_HOME": str(home),
            "TMPDIR": temporary, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
        profile = "(version 1)(allow default)(deny network*)(deny process-fork)"
        command = ["/usr/bin/sandbox-exec", "-p", profile, str(args.executable.absolute())]
        version = subprocess.run(command + ["--version"], cwd=private, env=environment, capture_output=True, timeout=10)
        version_text = version.stdout.decode().strip()
        if version.returncode or not version_text.startswith("codex-cli ") or len(version.stdout) > 1024:
            raise ValueError("unrecognized-passive-reader")
        report["actualReaderVersion"] = version_text.removeprefix("codex-cli ")
        child = subprocess.Popen(command + ["app-server", "--stdio", "-c", "analytics.enabled=false", "-c", 'otel.exporter="none"'],
            cwd=private, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        for pipe in (child.stdout, child.stderr):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ)
        serial, buffer, total, stderr_bytes = 0, bytearray(), 0, 0
        deadline = time.monotonic() + 30

        def request(method, params):
            nonlocal serial, buffer, total, stderr_bytes
            serial += 1
            child.stdin.write((json.dumps({"id": serial, "method": method, "params": params}) + "\n").encode())
            child.stdin.flush()
            while time.monotonic() < deadline:
                while b"\n" in buffer:
                    line, _, remaining = buffer.partition(b"\n")
                    buffer = bytearray(remaining)
                    value = json.loads(line)
                    if "method" in value and "id" in value:
                        raise ValueError("unexpected-provider-authorization-request")
                    if value.get("id") != serial:
                        continue
                    if "error" in value:
                        raise ValueError("controlled-passive-method-error:" + method + ":" + str(value["error"].get("code")))
                    return value["result"]
                for key, _ in selector.select(timeout=min(0.1, max(0, deadline - time.monotonic()))):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(data)
                    if total > MAX_BYTES:
                        raise ValueError("passive-read-byte-budget")
                    if key.fileobj is child.stderr:
                        stderr_bytes += len(data)
                    else:
                        buffer.extend(data)
            raise ValueError("passive-read-deadline")

        def verify(thread, expected):
            return thread.get("id") == expected and Path(thread.get("cwd", "")).resolve() == project and Path(thread.get("path", "")).resolve().is_relative_to(home)

        def item_summary(items):
            known = {"userMessage", "agentMessage", "commandExecution", "subAgentActivity", "collabAgentToolCall", "mcpToolCall", "dynamicToolCall", "reasoning", "plan"}
            types = {}
            prompt_ids, all_ids = set(), set()
            marker_anywhere = False
            for item in items:
                kind = item.get("type", "other")
                types[kind if kind in known else "other"] = types.get(kind if kind in known else "other", 0) + 1
                encoded = json.dumps(item)
                marker_anywhere |= MARKER in encoded
                if isinstance(item.get("id"), str):
                    all_ids.add(item["id"])
                    if kind == "userMessage" and MARKER in encoded:
                        prompt_ids.add(item["id"])
            return {"itemTypes": types, "requestedPromptMarkerAnywhere": marker_anywhere,
                "requestedPromptMarkerOnNativeUserMessage": bool(prompt_ids)}, all_ids

        try:
            request("initialize", {"clientInfo": {"name": "spillcheck-scoped-passive-contract-diagnostic", "version": "1"}, "capabilities": {"experimentalApi": True}})
            child.stdin.write(b'{"method":"initialized","params":{}}\n')
            child.stdin.flush()
            parent = request("thread/read", {"threadId": selections["parent"], "includeTurns": False})["thread"]
            if not verify(parent, selections["parent"]):
                raise ValueError("exact-parent-native-source-unverified")
            cursor, seen, linked = None, set(), False
            for _ in range(16):
                page = request("thread/items/list", {"threadId": selections["parent"], "cursor": cursor, "limit": 64, "sortDirection": "asc"})
                for entry in page["data"]:
                    item = entry["item"]
                    if item.get("type") in ("subAgentActivity", "collabAgentToolCall") and selections["child"] in [item.get("agentThreadId")] + item.get("receiverThreadIds", []):
                        linked = True
                cursor = page.get("nextCursor")
                if not cursor:
                    break
                if cursor in seen:
                    raise ValueError("parent-pagination-loop")
                seen.add(cursor)
            if not linked:
                raise ValueError("original-parent-child-link-unverified")
            full = request("thread/read", {"threadId": selections["child"], "includeTurns": True})["thread"]
            if not verify(full, selections["child"]):
                raise ValueError("exact-child-native-source-unverified")
            items = [item for turn in full.get("turns", []) for item in turn.get("items", [])]
            report["threadReadIncludeTurns"], full_ids = item_summary(items)
            report["threadReadIncludeTurns"]["turnCount"] = len(full.get("turns", []))
            turns = request("thread/turns/list", {"threadId": selections["child"], "limit": 64, "sortDirection": "asc", "itemsView": "full"})
            turn_items = [item for turn in turns["data"] for item in turn.get("items", [])]
            report["threadTurnsListFullItems"], turn_ids = item_summary(turn_items)
            report["threadTurnsListFullItems"]["pageComplete"] = turns.get("nextCursor") is None
            page = request("thread/items/list", {"threadId": selections["child"], "cursor": None, "limit": 64, "sortDirection": "asc"})
            report["threadItemsList"], item_ids = item_summary([entry["item"] for entry in page["data"]])
            report["threadItemsList"]["pageComplete"] = page.get("nextCursor") is None
            report.update(passed=True, nativeParentChildRelationshipVerified=True,
                fullReadAndFullTurnsHaveSameNativeItemIDs=full_ids == turn_ids,
                fullReadAndFirstItemPageHaveSameNativeItemIDs=full_ids == item_ids,
                sourceBytesRead=total, stderrBytesDiscarded=stderr_bytes)
        except (ValueError, KeyError) as failure:
            reason = str(failure)
            report["reason"] = reason if reason.startswith("controlled-passive-method-error:") else "controlled-exact-passive-read-failure"
        finally:
            selector.close()
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            report["ownedReaderStopped"] = True
            report["ephemeralReaderWorkspaceRemoved"] = True
    if args.output:
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
