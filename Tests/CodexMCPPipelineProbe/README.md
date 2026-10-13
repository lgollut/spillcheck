# Genuine MCP result through the production pipeline

This opt-in probe creates one isolated Codex 0.162.1 thread and calls one fixed
stdio MCP tool once. Four original text leaves contain the same fake GitHub token:
protocol text, structured caption, the ordinary `encrypted_content` business
field, and the ordinary `resource.blob` business field. The fixture preserves all
11 original text segments, including CRLF, Unicode, and escaped JSON pointers.
Protocol `isError` is false; nested business status fields remain ordinary text.

Three independent Swift workers use production native reads, normalization,
Betterleaks, and an encrypted store with disposable test keys:

1. `collect` binds the actual returned thread, turn, MCP item, and complete fixture
   before scanning. It requires four exact target occurrences, one value, one
   value payload, four excerpt payloads, one shared source-metadata payload, and
   a full current detector receipt for the target source.
2. `cold` opens the same store and verifies all inventory and receipt commitments
   without creating a history client. It performs zero source reads or scans.
3. `replay` first verifies cold state, then performs a new selected-source
   historical audit. Actual native reads must occur; full inventory and receipts
   remain unchanged, with zero additional detector scans.

The genuine thread may contain readable prompt/final sources. Their full receipts
are measured too: the count is bounded and must equal the source count. The fake
credential is absent from the human prompt and requested final response. Findings
outside the exact MCP target cause failure.

Prepare and run only after review; the commands below perform real actions:

```sh
python3 Tests/CodexMCPPipelineProbe/run.py build \
  --scratch-path .build \
  --build-binding .build/beta-readiness/codex-mcp-pipeline-2026-10-12/build-r1.json

python3 Tests/CodexMCPPipelineProbe/run.py run \
  --scratch-path .build \
  --build-binding .build/beta-readiness/codex-mcp-pipeline-2026-10-12/build-r1.json \
  --executable ~/.local/bin/codex \
  --auth-file ~/.codex/auth.json \
  --model gpt-6-astra \
  --report .build/beta-readiness/codex-mcp-pipeline-2026-10-12/pipeline-r1-report.json \
  --private-control .build/beta-readiness/codex-mcp-pipeline-2026-10-12/pipeline-r1-private
```

The evidence directory must already exist. Build binding, report, and private
control paths must be fresh. Build records all source/test/fixture/package inputs,
all imported runner dependencies, and actual compiled test/resource artifacts.
Those bytes are checked before and after the producer and every worker; changing
inputs requires a new build binding. The scanner executable and rules have fixed
reviewed SHA-256 commitments. The CLI executable is version-checked and hash-bound.

The owned provider root is `/private/tmp/spillcheck-native-mcp-pipeline-*`. Only
the explicitly authorized auth file is copied; personal configuration, trust, and
history are never copied or enumerated. The owned copy is removed after both the
producer group and independently recorded MCP PID/group have exited, before any
worker starts. Original-auth integrity is checked separately so rotation cannot
prevent removal of a safely owned copy. Each worker group and the MCP group are
rechecked after reads. Unconfirmed process cleanup preserves the private root and
an explicit cleanup handoff; no unknown process is killed. Reports contain closed
counts, booleans, versions, and keyed commitments, never native IDs, result text,
credential contents, or the original auth digest.

This proves a bounded CLI MCP scanning and cold-replay path. It does not establish
Keychain, signed-app, desktop, T3, native-child, provider-upgrade, or full-host
acceptance. It uses no fake detector, fabricated native history, or seeded detector
receipt.
The fixed local tool result is genuine provider input; the historical collection
request is deliberately submitted by the test harness.

Offline checks (no provider, scanner, Swift build, or Keychain):

```sh
python3 -m unittest discover -s Tests/CodexMCPPipelineProbe -p 'test_boundary.py' -v
```
