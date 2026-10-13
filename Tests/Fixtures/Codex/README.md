Recorded synthetic Codex public-history and cursor fixtures support the adapter regression tests. Personal working-directory metadata uses generic `/Users/test-user/test-project` paths. Native thread, turn, item, and cursor identities, timestamps, and provider-generated text remain intact. These recordings establish only the exact provider and reader versions tested; they do not prove compatibility with later versions.

The constructed current-protocol regressions in `CodexAdapterTests` follow the installed Codex 0.162.1 public TypeScript schema generated on October 10, 2026 with `codex app-server generate-ts --experimental --out <disposable-directory>`, using an empty disposable `CODEX_HOME`. No conversation store or credentials were read for this schema check. `v2/ThreadItem.ts` declares `dynamicToolCall.contentItems` and nullable `success`. `v2/DynamicToolCallOutputContentItem.ts` declares `inputText`, `inputImage`, and `inputAudio`. `FunctionCallOutputBody.ts` declares a string or typed content-block array. These are schema-derived regressions, not recordings of genuine provider runs or full acceptance evidence.

Dynamic tool tests cover success and failure text, the original legacy `/content` locations, current `/contentItems` locations, exact UTF-8 extraction by the production network-denied scanner, missing terminal payloads, excluded binary content, unknown required blocks, and stable replay. Function outputs retain original text rather than parsing JSON-looking strings or guessing an error status from wording.

`CodexPlanContentTests` constructs native `plan` items from the same pinned 0.162.1
schema and the upstream proposed-plan split regression at commit
`092d3acd6bec3e3a14bdc7e7a2810ab628ab759d`. These tests preserve the plan's separate
native identity and `/text` bytes; no final-answer phase is inferred. Their
synthetic encrypted recovery and replay checks are separate from the opt-in
genuine source probe in `Tests/CodexPlanProbe` and from signed-app acceptance.
