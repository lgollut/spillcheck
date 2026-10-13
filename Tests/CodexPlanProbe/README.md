# Native Codex Plan producer

`run.py` supplies the genuine Plan producer used by the
[shared signed native-content runner](../AppAcceptance/run-app-codex-native-content.py)
with `--fixture plan`. The `run-app-codex-plan.py` entrypoint forwards to that
runner. Follow the [signed acceptance instructions](../AppAcceptance/README.md)
for its candidate, authentication and owned-vault requirements.

The producer creates one fake-only app-server session in the caller's private
home and workspace. It requires the pinned `0.162.1` version, Plan mode and the
requested model. Its prompt requests a harmless plan marker and forbids tools,
files, web access and child agents. Missing Plan output, unexpected tool items,
server requests, wrong identities and output-budget failures reject the result.
Plan identity and byte hashes come from the actual native event.

The signed app then checks the original native source, exact `/text` bytes,
`intermediateResponse` classification, full detector receipts, cold restore and
forced reread. Direct parser regressions remain in
[CodexPlanContentTests.swift](../SpillcheckCoreTests/CodexPlanContentTests.swift).
The classification does not claim an upstream Plan phase field.

This module also supplies bounded RPC, private-file and process-cleanup helpers
to the review, hook and local-media producers. Importing it launches nothing.
Calling `produce()` starts the owned provider; the caller must arrange the
private directories, authentication lifecycle and final cleanup. Existing helper
contracts and their tests remain active.

Offline producer checks launch no provider or Keychain operation:

```sh
python3 -m unittest discover -s Tests/CodexPlanProbe -p test_boundary.py -v
```
