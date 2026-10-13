#!/usr/bin/env python3
"""One fixed fake-credential MCP result. No network, commands, or user data."""
import json
import os
from pathlib import Path
import sys

SERVER = "spillcheck_opaque_fixture"
TOOL = "opaque_business_result"
RESULT = {
    "content": [{"type": "text", "text": "SPILLCHECK_MCP_PROTOCOL_TEXT_42"}],
    "structuredContent": {
        "type": "image", "caption": "SPILLCHECK_MCP_BUSINESS_IMAGE_42 é🙂\r\n",
        "content": [{"type": "encrypted_content", "caption": "ordinary business encrypted label",
                     "encrypted_content": "ordinary business field", "a/b~": "escaped pointer text"}],
        "resource": {"blob": "ordinary business blob"},
        "printed": '{"type":"image","caption":"literal\\nbytes"}',
        "error": "business error", "status": "failed", "exit_code": 7, "isError": True,
    },
    "isError": False,
}

FAKE_TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
RESULT["content"][0]["text"] += " " + FAKE_TOKEN
RESULT["structuredContent"]["caption"] += " " + FAKE_TOKEN
RESULT["structuredContent"]["content"][0]["encrypted_content"] += " " + FAKE_TOKEN
RESULT["structuredContent"]["resource"]["blob"] += " " + FAKE_TOKEN


def exclusive(path, value):
    raw = json.dumps(value, sort_keys=True).encode() + b"\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)


def call_shape(params):
    is_object = isinstance(params, dict)
    value = params if is_object else {}
    return {"paramsObject": is_object, "unknownParamKeyCount": len(set(value) - {"name", "arguments", "_meta"}),
            "nameMatches": value.get("name") == TOOL, "argumentsObject": isinstance(value.get("arguments"), dict),
            "argumentsEmpty": value.get("arguments") == {}, "metaPresent": "_meta" in value,
            "metaObject": isinstance(value.get("_meta"), dict)}


def reply(request):
    method = request.get("method")
    if method == "initialize":
        return {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER, "version": "1"}}
    if method == "tools/list":
        return {"tools": [{"name": TOOL, "description": "Return the one fixed harmless opaque business result.",
                          "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}]}
    if method == "tools/call":
        shape = call_shape(request.get("params"))
        if not (shape["paramsObject"] and shape["unknownParamKeyCount"] == 0
                and shape["nameMatches"] and shape["argumentsEmpty"]
                and (not shape["metaPresent"] or shape["metaObject"])):
            raise ValueError("unexpected-call")
        return RESULT
    if method == "ping":
        return {}
    raise ValueError("unsupported-method")


def main():
    directory = Path(sys.argv[1])
    exclusive(directory / "mcp-process.json", {"pid": os.getpid(), "parentPID": os.getppid(),
                                               "processGroup": os.getpgrp()})
    diagnostic = {"schemaVersion": 1, "requestCount": 0, "methodCounts": {}, "calls": 0,
                  "lastStage": "started", "failureCategory": None}
    def retain():
        temporary = directory / "mcp-diagnostic-next.json"
        exclusive(temporary, diagnostic)
        os.replace(temporary, directory / "mcp-diagnostic.json")
    retain()
    try:
        for _ in range(128):
            line = sys.stdin.buffer.readline(65537)
            if not line:
                diagnostic["lastStage"] = "eof"
                return 0
            if len(line) > 65536:
                diagnostic["failureCategory"] = "request-budget"
                return 1
            request = json.loads(line)
            if not isinstance(request, dict):
                diagnostic["failureCategory"] = "request-object-required"
                return 1
            known = {"initialize", "notifications/initialized", "tools/list", "tools/call", "ping",
                     "resources/list", "resources/templates/list", "notifications/cancelled"}
            method = request.get("method") if request.get("method") in known else "other"
            diagnostic["requestCount"] += 1
            diagnostic["methodCounts"][method] = diagnostic["methodCounts"].get(method, 0) + 1
            diagnostic["lastStage"] = "request-received"
            if method == "tools/call":
                diagnostic["callShape"] = call_shape(request.get("params"))
            retain()
            if "id" not in request:
                if method != "notifications/initialized":
                    diagnostic["failureCategory"] = "unsupported-notification"
                    return 1
                continue
            result = reply(request)
            if method == "tools/call":
                diagnostic["calls"] += 1
                if diagnostic["calls"] != 1:
                    diagnostic["failureCategory"] = "duplicate-call"
                    return 1
                exclusive(directory / "mcp-invocation.json", {"schemaVersion": 1, "calls": 1,
                    "server": SERVER, "tool": TOOL, "argumentsEmpty": True, "result": RESULT})
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            diagnostic["lastStage"] = "response-written"
            retain()
        diagnostic["failureCategory"] = "request-count-budget"
        return 1
    except (ValueError, KeyError, TypeError):
        diagnostic["failureCategory"] = "request-rejected"
        return 1
    finally:
        retain()


if __name__ == "__main__":
    raise SystemExit(main())
