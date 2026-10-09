# Harness compatibility plan

Status: implementation authorized and started October 9, 2026; partial implementation,
with phase 0 and all six phase exit/completion gates still open.
[ADR 0005](adr/0005-observed-collection-compatibility.md) records
the accepted compatibility, concurrency, degradation, recovery, and verification policy.

The [design interview](implementation/harness-compatibility-interview.md) records
the settled product decisions and code findings from the grill-with-docs review.
The sequence below is the authorized implementation brief. The
[October 9 implementation evidence and remaining gates](implementation/harness-compatibility.md)
records measured results and every unmet gate. An open gate is not completion.
The signed genuine Claude 2.1.295 ingestion, native child prompt/final, replay,
encrypted storage and scoped cleanup check now passes. Signed mixed history and
current T3 selected-source live content also pass their required-content checks.
A corrected signed mixed rerun establishes per-producer commitment, one settled
frozen historical audit and zero gaps. Genuine manual GUI tests establish Claude
main live content and settled original-source catch-up, plus Codex live parent
all-five and child four-type content. Claude's passive Mod candidate failed its
main-dispatch positive control; side-chat authority remains unestablished. Codex's
corrected child-prompt fixture stopped because native `send_input` was unavailable.
Signed CLI 2.1.293→2.1.295 upgrade and restart pass 22 predicates. A separate
signed app rebuild and encrypted schema-2→3 migration pass 28, preserving durable
connection proof, shared registration, native identities and exact pending work.
Schema 2 came only from an intermediate build; the shipped schema-1→3 path has
only synthetic setup-probe coverage. A later review fixed queued Claude prompts
(parser contract 5), health incidents that could never settle, and Codex audit
recovery; the signed and genuine runs above predate those fixes.
CLI/T3 host authorization is separate from the immutable registration transport;
shared hooks do not by themselves identify the producer host.
GUI source contracts, six-host concurrency, required-format
restoration and the remaining recovery scopes still require their own evidence.

## Start a fresh implementation session

Use the checkout containing this plan and its linked documents. They are saved
in the working tree and were uncommitted at handoff on October 9, 2026. A new
worktree or clone needs these changes carried across first.

Read this plan, [SPEC](SPEC.md), [CONTEXT](../CONTEXT.md), and
[ADR 0005](adr/0005-observed-collection-compatibility.md) for the agreed behavior.
Before changing collection, read the [interview findings](implementation/harness-compatibility-interview.md)
and [reader guidance](SESSION_READER_REUSE.md) for checkpoint, recovery, identity,
and setup pitfalls. The [measured matrix](implementation/supported-matrix.md)
records existing evidence, including the unverified GUI routes.

All product questions in the interview are answered. GUI source behavior still
needs engineering validation in phase 0. An explicit instruction to implement
this plan supplies the final start confirmation; the earlier conversation is not
needed to reconstruct the decisions.

Opening implementation prompt:

```text
Implement docs/HARNESS_COMPATIBILITY_PLAN.md for Spillcheck in this checkout.
The documented product decisions are agreed; this instruction confirms the
start of implementation.

1. Read the plan, docs/SPEC.md, CONTEXT.md, and
   docs/adr/0005-observed-collection-compatibility.md. Before changing collection,
   read docs/implementation/harness-compatibility-interview.md and
   docs/SESSION_READER_REUSE.md. Use docs/implementation/supported-matrix.md
   as the measured baseline.

2. Begin with phase 0 using genuine disposable sessions created in each official
   GUI. Establish the actual producer, authorized store, passive collection
   route, and native identity. Satisfy its exit gate for all five required
   content types, live collection, and available catch-up before building the
   GUI-dependent setup model. Record the evidence and any missing capabilities.

3. Implement phases 1 through 5 against their exit gates. Resolve engineering
   choices from the repository and official provider documentation. Preserve
   existing encrypted data, owned registrations, and canonical source identities
   throughout configuration migration and upgrade recovery.

4. Complete only when genuine provider runs and signed-app acceptance establish
   all six local host/provider combinations operating concurrently, required
   content coverage, duplicate suppression, restart and upgrade recovery, and
   scoped degradation notifications. Publish new evidence and update the plan,
   coverage matrix, and README to match measured results.

If a required environment or capability is unavailable, record the exact unmet
gate and continue independent work. Report every remaining gate explicitly;
partial implementation does not establish completion.
```

### Last verification before implementation

The October 9 readiness check built the signed development app and passed 235
core tests in 31 suites, including signed-scanner integration. The signed-app
synthetic ingestion report passed. Local artifacts are
`.build/readiness-build.log`, `.build/readiness-tests.log`, and
`.build/readiness/app-pipeline.json`. These ignored build artifacts are optional
handoff evidence and can be regenerated using the commands in [README](../README.md).
They establish the earlier implementation's regression baseline, not genuine
GUI collection or completion of this plan. No app code changed during the
design interview. Recheck installed app and producer versions when implementation
starts, and keep new acceptance reports separate from historical ones.

## Agreed direction

Spillcheck should continue collecting understood content when Claude Code,
Codex, or T3 upgrades. A version number records the environment and its test
evidence. Collection eligibility depends on the behavior and format the app
needs. Versions with a demonstrated incompatibility can carry an explicit
exclusion with a reason.

Collection on previously untested releases is automatic when the required checks
pass. Missing acceptance evidence alone does not require user opt-in. Recovery
and backward source compatibility are bounded by the seven-day analysis window,
with the existing encrypted queue and no additional raw-content archive.

The first deliverable is Claude Code 2.1.295 working through ordinary owned hook
setup and the signed app, alongside retained 2.1.293 history, without adding
2.1.295 to an exact-version allowlist. Include concurrent Claude CLI and T3 native
sessions within the same authorized home, recording each actual producer version.
This is an intermediate gate. Completion also requires local sessions in the
official Codex GUI and Claude GUI Code tab operating alongside both CLIs and T3.
GUI support cannot remain deferred or depend on choosing one interface per provider.
Ordinary Claude Chat, Cowork, cloud execution, and SSH execution remain outside
this release's scope.

## Current behavior and requirements

Exact-version checks occur in `AgentSetupController`, both hook setup modules,
both adapters, `CodexHistoryClient`, app acceptance configuration, and the live
test runners. Updating only Settings or one adapter would leave other blockers.
`AdapterCoverage.isConnected` also requires exact-version validation today.

The scanner consumes normalized source text. Its pinned executable, rules,
signed hashes, and sandbox are separate from harness compatibility.

Use the existing specification and [session reader guidance](SESSION_READER_REUSE.md)
for required content, bounded reads, durable progress, replay, and source identity.
The specification requires disclosure of validated versions and content types;
it does not require exact-version rejection.

Compatibility checks provide evidence about a particular operation and source.
A successful handshake or decodable JSON alone cannot establish full content
coverage or prove unchanged semantics on every future release.

## 0. Establish GUI collection routes before changing the setup model

Create disposable sessions directly in each official GUI app and establish the
native source, configuration, executable or embedded producer, and collection
operations actually used. Record the GUI app version separately from the native
producer and any external reader. Do not assume a GUI uses the selected CLI
executable or its authorized home.

For Claude Code, investigate the existing hooks and transcript reader first.
For Codex, investigate the existing passive app-server history reader first.
Use the provider parser whenever the actual source contract matches; a GUI host
does not itself require another parser. Test hook delivery, complete source
content, session mapping, bounded reads, and seven-day catch-up independently.
Opening a CLI session in a GUI does not satisfy this gate. Check GUI-created
local child sessions and live-only content such as Claude Code side chats rather
than assuming everything is present in the main persisted transcript. Available
original history bounds recovery; missing history must remain visible.

The required targets are:

| Provider | Required concurrent hosts | Required execution |
| --- | --- | --- |
| Codex | Standalone CLI, T3, official Codex GUI | This Mac |
| Claude Code | Standalone CLI, T3, official Claude GUI Code tab | This Mac |

If a required GUI route cannot expose a required content type, record the exact
limitation and resolve its collection approach before claiming support. Preserve
the existing local analysis and encrypted-storage requirements. Any app-specific
stores needed for the required hosts must be explicitly authorized; arbitrary
multi-account support remains outside the previously agreed scope.

**Exit gate:** each required GUI has an evidenced collection approach for all
five content types, native identity, live observation, and available catch-up.
Record remaining blockers as implementation work rather than treating Desktop
as a permanently optional interface.

## 1. Support concurrent routes and separate their evidence

Add one collection compatibility module in `Sources/SpillcheckCore`, used by setup,
adapters, and the app. Keep provider format recognition inside each adapter.
Expose a small assessment containing the collection route, usable operations,
known format contract, controlled failure reasons, and test-evidence status.

Keep three independent facts:

- Connection: an owned route delivered its verification event and committed it
  encrypted. This does not establish content coverage.
- Compatibility: a required operation and content format can be handled. A
  missing history method can limit catch-up without disabling working live
  content; an unknown content type can limit one source without disabling the
  entire provider.
- Acceptance evidence: the exact environment and content types that passed
  genuine provider and signed-app tests. Runtime checks do not promote a new
  release into this evidence automatically.

Use observed executable versions and per-source producer versions separately.
Historical content may have been produced by older executables. Missing producer
metadata must be represented honestly rather than labeled with today's version.

Settings, Coverage, and the menu bar should show whether collection is operating,
the content or operations that are unavailable, and whether the environment has
full acceptance evidence. An unfamiliar version by itself should not produce
"Stopped: unsupported version". Revise `AdapterCoverage.isConnected` accordingly.

Preserve decoding of existing profiles, coverage records, and encrypted captures.
Version strings and compatibility assessments must not become part of occurrence
identities, source revisions, or replay keys.

Replace the single interface per provider in app setup with concurrent authorized
routes. Migrate existing configuration without losing profile identity, owned
registrations, or verification proof. Keep registration ownership separate from
the hosts using it so adding, repairing, or disabling one host does not remove a
registration another host needs. Assess compatibility, connection, and missing
content per route; aggregate status must preserve each affected scope.

When hosts share the same native store, retain the same canonical profile and
source identities. Do not create a new profile identity just to represent another
host. Where stores differ, establish native mapping and authority explicitly;
never merge unrelated sources merely because their text or titles match.
Settings must represent simultaneous CLI, T3, and GUI collection rather than a
mutually exclusive picker. Show partial coverage when one route fails while
the remaining routes keep operating.

**Exit gate:** one compatibility decision is shared by setup and collection;
tests distinguish connected, compatible, partially covered, unverified, and
incompatible cases without treating an unfamiliar version as a failure.
One incompatible route or required content type must not disable other usable
collection. Persistent status identifies the missing scope independently of
whether the configuration remains verified.

## 2. Complete the Claude path first

Replace exact-version eligibility in `ClaudeHookConfiguration`, `ClaudeHookSetup`,
`ClaudeAdapter`, `AgentSetupController`, and `CollectionConfiguration` with the
shared assessment. Keep owned-hook editing and durable challenge verification.

Recognize the current transcript contract through required identity fields,
timestamps, roles, content blocks, tool-use correlation, and complete JSONL
framing. Extra envelope fields are tolerated. Additional strings inside a
recognized tool-result payload remain scannable content with exact source ranges.
Missing required fields, changed field types, unsupported content blocks,
and ambiguous correlation produce explicit
gaps. Continue to analyze supported content without claiming coverage of skipped
blocks. Preserve exact UTF-8 ranges and all five required content types.

Hooks can arrive before the corresponding transcript content is written. Keep
bounded rereads and complete-record framing; an empty initial read must not
establish completion or substitute hook text as a second source authority.

Treat each row's version as provenance rather than requiring it to equal the
selected executable version. Add mixed-version history fixtures. Where producer
metadata is missing, use an explicit unknown value or provenance representation
that preserves existing persisted data and identities.

Parameterize `Tests/ClaudeLive/run.py` and the acceptance executable with the
observed version. Reports must verify the executable actually used and retain
strict behavioral assertions. An intended baseline can still be checked in a
specific acceptance run without becoming product eligibility logic.

After the GUI collection contract is established, remove the Desktop exclusions
from Claude normalization and active-source setup. Register the GUI route in
runtime with the same native parser where applicable, alongside CLI and T3.
Handle any GUI-specific live content through its evidenced source contract.

**Exit gate:** genuine disposable Claude 2.1.295 sessions and the signed app pass
user prompt, intermediate response, final response, successful tool output, and
tool error checks. Also pass mixed 2.1.293/2.1.295 history, replay, empty queue,
encrypted-storage inspection, and cleanup. Existing 2.1.293 fixtures still pass.
Current CLI, T3, and GUI Code sessions run concurrently;
test and record the actual producer used by each host without assuming equality.
A format failure affecting tool output leaves readable prompts and responses
collecting, displays partial coverage, and produces one masked health notification.
Exercise sessions created directly in the GUI, including tool results not repeated
in its visible assistant response. Validate actual GUI-produced history, required
child-session behavior, and live-only content. The GUI's producer can differ from
Claude CLI 2.1.295; its own observed format and acceptance evidence govern it.

## 3. Complete Codex compatibility across CLI, T3, and GUI

Replace executable and configured-version equality checks in
`CodexHistoryClient`, Codex hook setup, and `CodexAdapter`. Validate the actual
reader executable and use the existing bounded initialization and read requests
to assess the operations needed for live reads and historical audit separately.

The initialization opt-in is not proof that every required method exists.
Handle missing methods, rejected parameters, malformed replies, and temporary
read failures distinctly. Probe only authorized profiles and selected sessions,
and retain passive read-only operation. Do not resume sessions or create turns
to assess compatibility. Keep the existing network and process restrictions.

Validate response contracts, IDs, timestamps, phases, tool status, pagination,
and source correlation. Reader version and producer version may differ. The
thread's recorded producer version is provenance, not an exact eligibility key.
Tolerate additive envelope fields and scan additional supported text within
recognized payloads. Report unknown item types as coverage gaps.

Select parsers by provider content format and collection route. Current Claude
CLI and T3 content uses the same native transcript parser. Current normal Codex
CLI and T3 collection uses the same native public-history importer. The optional
`t3VersionedTranscript` alternative parses Codex-native rollout JSONL, not a
T3-owned conversation format; its host-specific name reflects earlier exploratory
work. Clarify internal names while preserving persisted authority identifiers.

Remove the exact T3 nightly-build gate for native provider collection. T3 is
agent-host and acceptance metadata. Its selected executable, authorized home,
hook delivery, and session mapping can differ and must be checked, but those
differences do not imply another conversation parser. Mapping a host conversation
to its native source needs independent evidence. Preserve one canonical authority
per conversation and no silent switch between public history and transcript
collection. Support concurrent CLI and T3 sessions within the same explicitly
authorized provider home and GUI sessions through their evidenced route without
an interface-selection toggle. Authorize any additional native store actually
needed by a required GUI host; arbitrary multiple homes or accounts remain later
scope. Add the GUI route to adapters, active monitoring, setup, and runtime after
its collection contract is established, replacing the existing Desktop exclusions.

Parameterize the Codex acceptance executables and runners to record the actual
reader, producer, and host versions instead of inserting the old tested tuple.

**Exit gate:** current Codex standalone, explicitly selected current T3, and
GUI-created local sessions run concurrently and pass their required content checks without
duplicate occurrences or alerts when the same native session overlaps routes.
Additional fields and different
version metadata work; missing methods and changed essential formats produce
visible scoped limitations. Existing authority and replay tests still pass.

## 4. Make upgrades recover automatically

Detect a changed executable at launch and during monitoring. Invalidate cached
compatibility results and recreate affected readers under the existing
cancellation and generation controls. Refresh observed version metadata and
reassess available operations automatically. Include GUI app updates and embedded
producer changes; update only the affected routes while other hosts continue.

Keep the owned hook registration and provider-owned trust when its configuration
is still valid. Persist Spillcheck's connection verification with the registration
and configuration it covers. Request another synthetic verification only when
the route or its configuration changed, or its connection evidence is no longer valid. A patch
upgrade alone should not require choosing an older executable or reinstalling
hooks.

Keep encrypted queued work, checkpoints, history continuation, review state,
obsolete-value records, and notification receipts usable across compatible
upgrades. Handle older producer content in the queue and history under its own
format contract. A failed assessment shows a reason and preserves retryable work
within the existing limits. Distinguish transient failure, blocked compatibility,
partial analysis, and irrecoverable loss. Preserve progress through usable content
while separately retaining controlled recovery references for skipped ranges or
items. A parser-contract change must invalidate affected completion shortcuts
and recover eligible omissions even when the original file or thread is unchanged.
Existing processed-source receipts continue to suppress prior analyzed content.

Unresolved omissions remain attributed within the displayed coverage period;
aging out of the recent-gap query is not evidence of recovery. Actual format
incompatibility that impairs collection may cause one masked health notification
per confirmed incident when enabled, including loss of one required content type
while others work. Unaffected routes and readable content continue. An unfamiliar
version, additional optional fields, or intentionally unsupported content alone
does not trigger a failure notification. Keep notification incident identity and
duplicate suppression durable across restart.

**Exit gate:** upgrading a disposable executable while the app is running, then
restarting the app, preserves collection, inventory, and replay behavior. An
incompatible executable exposes a controlled failure; restoration to a compatible
executable recovers without duplicate occurrences or alerts. Exercise one host
upgrading or failing while another host of the same provider remains active.

## 5. Publish evidence and use the app normally

Build the signed development app and run the core suite with signed-scanner
integration, helper tests, setup and workflow probes, and genuine provider runs.
Update existing tests that assert an unfamiliar version must be rejected. Add
behavioral cases for compatible patch/minor/major metadata changes, extra fields,
missing methods, essential format changes, mixed-version histories, and upgrade
recovery. Version-number changes alone do not prove actual compatibility.

Record new reports separately from historical evidence. Update
`implementation/supported-matrix.md`, runner documentation, and README to describe
the accepted contracts and exact measured environments. The release checks remain
open until their own acceptance runs pass.

Then perform an ordinary-use trial with current installed agents: verify hooks,
observe synthetic credentials through normal sessions, check notifications and
authenticated viewing, exercise sleep/lock masking while content is revealed,
and restart to verify catch-up and persistence. Check monitoring and Coverage
after a harness upgrade.

Run a signed-app acceptance session with all six host/provider combinations active.
Exercise independent native sessions as well as one native session observed
through overlapping hosts. Verify all five content types, correct attribution,
bounded queue settlement, one occurrence per native location, and durable alert
suppression across restart. A format failure in one GUI must leave both providers'
unaffected routes operating and produce one masked health notification.

Validate source-opening commands and deep links separately against disposable
GUI sessions, confirming the intended native conversation. Enable only evidenced
routes and retain the authenticated context fallback where opening is unavailable.
Source-opening evidence does not substitute for collection acceptance.

**Completion gate:** the current harnesses work without downgrades; compatible
version changes do not automatically stop collection; an intentionally broken
format degrades only affected collection and triggers one masked notification;
both providers' CLIs, T3 routes, and official GUI apps work concurrently for local
sessions; test evidence and actual coverage remain distinct. Publish required GUI
coverage as supported only after the genuine and signed-app gates pass.

## References for implementation

- [Claude hook reference](https://code.claude.com/docs/en/hooks) describes common
  hook fields, event behavior, and asynchronous transcript writes. It does not
  substitute for validating the transcript content Spillcheck uses as its
  canonical source.
- [Codex initialization schema](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v1/InitializeParams.json)
  defines the experimental opt-in. Assess the methods actually used rather than
  treating this client declaration as a server capability inventory. Check the
  selected executable's schema and behavior during implementation.
- [Claude Desktop reference](https://code.claude.com/docs/en/desktop) documents
  shared local Code settings and hooks. It also states that Code side chats are
  not saved to disk. Validate GUI live content and available history independently.
- [Codex app-server reference](https://learn.chatgpt.com/docs/app-server) describes
  passive stored-history operations. Prove that the selected reader reaches the
  original GUI source and required content, without resuming a session.
- [Collection specification](SPEC.md#collection-and-coverage),
  [reader guidance](SESSION_READER_REUSE.md), and
  [recorded evidence conventions](implementation/README.md) define the existing
  behavior and reporting requirements.
