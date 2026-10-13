Shared Python helpers for the app's acceptance tests live here. `processes.py` stops disposable process groups with a bounded grace period, then kills any surviving descendants and reaps the group leader. `Tests/ClaudeLive/run.py` uses it to clean up its provider and acceptance-driver processes.

`acceptance_artifacts.py` retains each failed run's disposable vault and manifest for diagnosis. It removes the owned directory only after the app confirms vault cleanup and the test passes. Signed-app acceptance and resource measurements share this helper.

`inventory_evidence.py` contains the shared report-schema, review/removal and
exact-source replay checks for the Claude and Codex inventory scenarios. Each
runner supplies its own source-readiness check and retains its provider-specific
process controls. The helper only compares report values. Run its offline tests
with `python3 Tests/Tooling/run-python-tests.py --suite Support`.

The Claude upgrade/restart runner also uses `acceptance_journal.py`. Before launching its signed vault owner, it creates a fresh private directory named `<output>.private-diagnostics` beside the requested report. The output parent must already exist as a persistent, canonical directory outside the system temporary directories. Existing journals and symlink destinations are rejected. Other acceptance runners retain their existing behavior.

The journal atomically writes and syncs a private index, bounded copies of the run's fake `claude/projects/**/*.jsonl`, fixed count/enum/Boolean report fields, and validated protection manifest identifiers. Each source generation is immutable until a new index is durable. The 16 MiB source budget permits at most one current and one pending generation, up to 32 MiB during replacement. It does not copy Claude credentials or settings, the run token, process output, encrypted database rows, or key material. The runner requires a synced committed manifest before any provider request. SQLite reads the manifest through a pinned file descriptor without WAL or pathname fallback, after the fresh creator has closed its store. The runner takes a final snapshot before cleanup and persists its final journal state before removing the temporary root. File, byte, directory, ownership, symlink, hardlink, and write failures prevent a passing result. A fully passing run with confirmed creator cleanup removes both its temporary root and journal. Failed or interrupted runs retain the journal.

These copies are diagnostic evidence and must never substitute for original native sources in acceptance checks. Manifest identifiers do not authorize key deletion. Only the original signed creator retains the existing cleanup authority. A crash between the owner's first key effect and the observer's first snapshot can still lose those initial identifiers. The observer samples every 250 ms, so an interruption can also lose source bytes written after its last synced snapshot. This change does not recover artifacts already erased by the earlier reboot or confirm their key cleanup.

Run the constructed journal checks with `python3 -m unittest discover -s Tests/Support -p 'test_acceptance_journal.py'`. They use fake files and an abruptly killed Python observer, without an app, provider, or Keychain access.

`claude_desktop.py` holds the owned-project bootstrap and settings comparisons used
by Desktop, T3 and concurrent Claude acceptance. It also supplies the copied
identity-only helper inside the disposable workspace.
