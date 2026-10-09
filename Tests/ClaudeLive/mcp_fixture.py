#!/usr/bin/env python3
"""Disposable synthetic MCP output for the actual Claude adapter acceptance run."""
import json
import sys

SECRET = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
for line in sys.stdin:
    try:
        request = json.loads(line)
        method = request.get("method")
        if "id" not in request:
            continue
        if method == "initialize":
            result = {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"spillcheck-synthetic","version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"synthetic_output","description":"Print a synthetic credential for Spillcheck testing","inputSchema":{"type":"object","properties":{"fail":{"type":"boolean"}},"required":["fail"]}}]}
        elif method == "tools/call":
            fail = request.get("params",{}).get("arguments",{}).get("fail",False)
            result = {"content":[{"type":"text","text":f"LEAKRET_M3_MCP_{'ERROR' if fail else 'OK'} {SECRET}"}],"isError":bool(fail)}
        else:
            result = {}
        print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
    except (ValueError,TypeError):
        pass
