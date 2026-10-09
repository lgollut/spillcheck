# Signed app acceptance

These drivers run the signed development app with its bundled scanner and production vault in a disposable directory. Run commands from the repository root after `make app`.

Check Claude ingestion, all five content types, encrypted storage, process memory, and shutdown cleanup:

```sh
python3 Tests/AppAcceptance/run-app-pipeline.py \
  --output .build/acceptance/app-pipeline.json
```

`--app` selects another signed app bundle. The default is `.build/app/Build/Products/Debug/Spillcheck.app`. The driver creates a synthetic transcript and exits after the app's timed acceptance run.

Check Codex collection against one to four exact, newly owned synthetic T3 threads:

```sh
python3 Tests/AppAcceptance/run-app-codex-pipeline.py \
  --thread OWNED_SYNTHETIC_THREAD_ID \
  --output .build/acceptance/codex-app-pipeline.json
```

Repeat `--thread` for each selected thread. `--home` and `--executable` select the original provider store and Codex reader. This driver uses the default built app and the measured tuple of Codex reader 0.161.0, producer 0.160.1, and T3 0.0.46-nightly.20261007.2761. It reads the selected threads with profile discovery disabled. It does not create provider sessions.

Keep a synthetic inventory open for manual native review and viewing checks:

```sh
python3 Tests/AppAcceptance/run-app-workflow.py \
  --ready .build/acceptance/workflow-ready.json \
  --output .build/acceptance/workflow.json \
  --duration 3600
```

`--app` selects the signed bundle, and `--duration` bounds the run to 30 through 7200 seconds. The private ready file identifies the disposable source, app report, and process. Viewing uses real macOS authentication. Complete authentication in the system prompt and quit the app normally to finish cleanup. The report checks termination and cleanup; manual workflow outcomes require separate review.

The drivers create separate production Keychain items for their disposable vaults. `Tests/Support/acceptance_artifacts.py` removes each owned directory after the test passes and the app confirms vault cleanup. Failed runs retain their exact vault and manifest for diagnosis. Use `--help` to inspect options without launching an app.
