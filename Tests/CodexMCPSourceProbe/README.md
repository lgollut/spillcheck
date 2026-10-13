# Native MCP fixture producer

`run.py` and `fixture.py` supply the MCP producer used by the
[shared signed native-content runner](../AppAcceptance/run-app-codex-native-content.py)
with `--fixture mcp`, and by the separate MCP pipeline check. Follow the
[signed acceptance instructions](../AppAcceptance/README.md) for the signed
candidate, authentication and owned-vault requirements.

The producer creates one disposable Codex `0.162.1` app-server thread and requests
one fixed local MCP tool. Its result contains a protocol text block and distinct
business JSON. The business keys `type`, `content`, `resource` and error/status
fields deliberately resemble protocol fields. They remain ordinary result
strings. An automatic text copy of the structured JSON fails the exact native
result check.

The caller's descriptor binds the returned native thread, turn and tool-item
identities. The signed app verifies the eleven exact original strings and JSON
pointers, native MCP type, tool-output classification, full receipts, cold
restoration and forced reread. Direct parser and encrypted pipeline regressions
remain in [CodexMCPStructuredContentTests.swift](../SpillcheckCoreTests/CodexMCPStructuredContentTests.swift).
The signed fixture contains no credential findings; the distinct
[MCP pipeline probe](../CodexMCPPipelineProbe/README.md) checks genuine MCP
content containing a fake credential through Betterleaks and encrypted storage.

The producer retains its 150-second deadline and bounded RPC/output budgets.
The fixture records its own PID, process group and one invocation privately.
`confirm_mcp_stopped()` checks those identities and waits for both the server
and its process group to disappear; it sends no signals to inferred groups.
Callers still own authentication removal, private-root lifetime and reader
shutdown. Failed or uncertain cleanup must preserve the owned handoff.

Optional object-valued request `_meta` remains transport metadata while the
tool name and empty arguments remain exact. Closed diagnostic summaries retain
only allowed counts and shape checks. Unknown names, raw errors, request values
and metadata contents are not exported. Importing these helpers launches nothing.

Offline producer and fixture checks launch no provider and access no
authentication or Keychain:

```sh
python3 -m unittest discover -s Tests/CodexMCPSourceProbe -p test_boundary.py -v
```
