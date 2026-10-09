#!/usr/bin/env python3
"""Synthetic MCP acceptance fixture. No files, credentials, or network access."""
import json
import sys

TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
for line in sys.stdin:
    try:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "spillcheck-synthetic", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "synthetic_output", "description": "Return only a fixed synthetic test value; fail selects the error case.",
                "inputSchema": {"type": "object", "properties": {"fail": {"type": "boolean"}}, "required": ["fail"], "additionalProperties": False}}]}
        elif method == "tools/call":
            failed = request["params"]["arguments"]["fail"]
            marker = "LEAKRET_M4_MCP_ERROR" if failed else "LEAKRET_M4_MCP_OK"
            result = {"content": [{"type": "text", "text": marker + " " + TOKEN}], "isError": bool(failed)}
        elif method == "ping":
            result = {}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    except (ValueError, KeyError, TypeError):
        continue
