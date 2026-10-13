# Native review recovery acceptance

This opt-in probe generates one fake inline Codex review, stops the producer,
removes its temporary authentication, then runs the production historical reader,
detector and protected store in three separate Swift test processes.

The original instructions and null-phase reply each contain one copy of a fake
GitHub credential. The native entry and exit presentations repeat these originals.
The required result is one value, two original occurrences and two full receipts,
with both presentation warnings recovered and no presentation copies admitted.

The `queue` worker stops after a real inspection page has been read and its
encrypted continuation has been committed. The `resume` worker reopens that
queue and completes recovery. The `replay` worker verifies the inventory before
any source reads, performs a new historical audit, and requires unchanged
receipts and occurrences without additional detector scans. Every history
request stays within the exact owned parent conversation; one-row pages force
the real pagination paths. The detector uses the pinned Betterleaks executable
and rules. Wrappers count calls without substituting source or detector output.

## Build and run

Use fresh output paths. The build records all production Swift files, test files,
fixtures, package inputs and probe dependencies before and after compilation.
The run refuses changed sources or compiled test artifacts, including between
worker stages. The same inputs must remain frozen through the run.

```sh
python3 Tests/CodexReviewRecoveryProbe/run.py build \
  --scratch-path /absolute/private-output/swift \
  --build-binding /absolute/private-output/build-binding.json

python3 Tests/CodexReviewRecoveryProbe/run.py run \
  --scratch-path /absolute/private-output/swift \
  --build-binding /absolute/private-output/build-binding.json \
  --executable /absolute/path/to/codex \
  --auth-file /absolute/authorized/codex/auth.json \
  --model gpt-6-astra \
  --report /absolute/private-output/report.json \
  --private-control /absolute/private-output/control
```

The authentication file must be explicitly authorized for this run. Its owned
copy exists only in a fresh disposable provider home. The runner removes it
after confirmed producer shutdown and before passive readers start. It removes
the owned root only after every producer and worker process group has stopped.
Uncertain cleanup produces a private handoff instead of an acceptance pass.

Only closed booleans, counts, versions and byte hashes enter the public report.
Source text and native IDs are not exported. Private handoffs contain the
exact owned IDs and encrypted-state commitments needed by the next worker.
No personal history or trust configuration is read.

## Scope

Storage uses random disposable deterministic test keys, not Keychain. This
establishes orderly worker-process restarts with encrypted pending work. It does
not establish crash safety, signed-app acceptance, a Keychain vault, provider or
schema upgrades, desktop/T3 behavior, native subagent input, or full Codex
support. The earlier source-only `CodexReviewProbe` remains unchanged.

Boundary tests require no provider or credentials:

```sh
python3 -m unittest discover -s Tests/CodexReviewRecoveryProbe -p 'test_*.py'
```
