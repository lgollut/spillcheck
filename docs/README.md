# Documentation

Use these guides for current behavior and ongoing work. Build and first-run
instructions are in the [repository README](../README.md).

| Guide | Use it for |
| --- | --- |
| [Product specification](SPEC.md) | Workflows, privacy rules and acceptance criteria. |
| [Architecture](ARCHITECTURE.md) | Code ownership, collection flow, storage and compatibility contracts. |
| [Design brief](DESIGN_BRIEF.md) | UI behavior, terminology and review scenarios. |
| [Session readers](SESSION_READER_REUSE.md) | Bounded reads, framing, checkpoints and recovery. |
| [Codex beta](CODEX_BETA.md) / [Claude beta](CLAUDE_BETA.md) | Included content, host scope, setup and exclusions. |
| [Beta readiness](BETA_READINESS.md) | Open verification, known issues and trial requirements. |
| [Releasing](RELEASING.md) | Versioning, release commands and distribution requirements. |
| [Architecture decisions](adr/) | Accepted decisions and their rationale. |

[Domain vocabulary](../CONTEXT.md), [contribution rules](../CONTRIBUTING.md) and
the [test guide](../Tests/README.md) live beside the code they describe. Individual
acceptance commands stay with their runners under `Tests/`.

Update the relevant guide when behavior or a decision changes. Keep generated
reports, experiment transcripts, source snapshots and per-run results out of
`docs/`; use ignored output directories for run artifacts. Summarize any lasting
limitation or remaining requirement in the scope or readiness guide. Remove
superseded plans instead of maintaining parallel instructions.
