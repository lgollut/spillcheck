# Milestone 5: native user workflow

The workflow gate passed on the available Mac. The real signed-app walkthrough and the rebuilt development app regression both passed. Distribution is deferred at the user's request.

## Observed native behavior

The disposable signed app used production Keychain protection and synthetic Claude records. Its initial inventory grouped one exact value across five occurrences covering user prompt, intermediate response, final response, successful tool output, and tool error. Values, raw excerpts, and source identifiers remained masked before authentication.

The user authenticated successful Reveal requests and canceled a separate displayed request. Cancel produced the explicit canceled state with all content masked. After deleting the owned synthetic source, authenticated context viewing still showed the retained excerpt and identifier. Direct source opening showed an honest unverified-route fallback. The terminal command appeared only after authentication and was displayed without execution.

Per-occurrence false-positive and confirmed-secret review updates persisted. The false-positive filter excluded the confirmed entry; restoring all reviews restored it. Rotation acknowledgement was distinct from review. Content removal left only the keyed obsolete marker, with no Reveal control. Explicit forgetting removed that marker.

With macOS notifications denied, a new detection still appeared and the app showed the disabled indicator. After enabling only Spillcheck's notification permission, a different new synthetic value generated a notification. The user clicked it and the correct entry opened with its value and context masked. Alert text uses controlled type, provider, and conversation labels; notification navigation opens inventory details.

Window close masked an authorized value and left the app running. Normal Quit finished with an empty queue, no raw content caches, no diagnostics, successful scoped vault cleanup, and removal of the owned temporary directory. [The final walkthrough report](m5-app-workflow.json) records those shutdown results. Its `passed` field covers termination, queue, ciphertext inspection, and cleanup; the manual observations above have the separate scopes described here.

Five helper attempts while paused returned only the controlled empty JSON response and added no capture or occurrence. Warm wall time, including process startup, was 15.7–30.1 ms. [Paused evidence](m5-paused-hook.json) preserves the measurements. An earlier test incorrectly required zero stdout; [the initial result](m5-paused-hook-initial.json) preserves that assertion error. The helper's protocol intentionally returns `{}` followed by a newline.

Five attempts after Quit returned the same response in 18.7–20.4 ms while their stdin remained open. They exited before reading input and did not recreate storage. [After-Quit evidence](m5-after-quit-hook.json) records these checks.

## Automated checks and fixes

[The final core run](m6-full-tests.json) passed 212 tests across 30 suites, including the actual signed-scanner bundle check. [The controller probe](m5-native-workflow-probe.json) passes 21 checks, including late authentication after occurrence changes within one entry, lifecycle invalidation, notification cancellation/count revisions, and owned-command cancellation. It uses injected authorization and notification backends, so it does not replace the native observations. [The setup probe](m5-agent-setup-probe.json) passes seven disposable-profile scenarios without provider sessions or credentials.

The occurrence selection callback now clears caches and terminal commands, invalidates pending private-key work, and retires source commands. Runtime guards check the exact occurrence before and after awaits. Unique occurrence accessibility IDs contain only app-owned UUIDs and controlled action names. A thrown notification-permission request now rereads macOS settings and preserves a concrete denied or allowed result.

[The rebuilt-app regression](m5-final-app-workflow.json) used a verified development installation. Revealed context immediately became masked when another occurrence's Open conversation action was selected. Its review control saved only the selected occurrence. After restoring Spillcheck's notification permission to denied, a different synthetic value appeared with the disabled-notifications indicator. Normal Quit completed with an empty queue, no raw caches or diagnostics, clean ciphertext, and scoped cleanup. The controller probe separately exercises a thrown permission request and late authorization completions.

[The development-install check](m6-development-install.json) also recorded successful login registration and unregistration, ending off. Actual logout/login launch was not tested. Discovery showed Codex 0.161.0 as found but unconnected, and the currently installed Claude 2.1.294 as unsupported. No existing agent hooks were installed or edited.

## Reproduce

On an unlocked Mac with the development app provisioned:

```sh
swift test
scripts/build-app.sh
python3 Tests/NativeWorkflowProbe/run.py
python3 Tests/AgentSetupProbe/run.py
python3 Tests/AppAcceptance/run-app-workflow.py \
  --output docs/implementation/m5-app-workflow.json \
  --ready .build/implementation/m5-workflow-ready.json
```

The ready file identifies only the owned disposable source and report. Authenticate only in macOS. Complete the masked/reveal/cancel/context, review/filter, acknowledgement/removal/forgetting, notification, and pause/window checks, then Quit normally. Keep the exact manifest if cleanup fails. Do not rebuild a bundle while that bundle is running an acceptance check.

Launch at login is off by default. The installed development copy initially reported unavailable; an explicit registration succeeded, followed by successful unregistration. Actual login launch and distribution upgrade behavior remain unverified. Direct Desktop opening, macOS 14 execution, hardware without Touch ID, and Developer ID distribution remain unverified. The user authorized deferring distribution and the two unavailable platform checks; this does not establish release readiness.
