---
"spillcheck": minor
---

Spillcheck now uses its own bundle identifier, `com.spillcheck.app`, instead of `com.leakret.app`. macOS treats it as a new app, so an existing installation can't open its vault. Remove the agent connections in the old version, then move `~/Library/Application Support/Spillcheck` aside and set Spillcheck up again. If the old version won't open, delete the Claude Code and Codex hook entries whose status message starts with "Spillcheck hook" or "Leakret hook" by hand, because the new version can't recognize them. Notification permission, launch at login and onboarding start fresh; remove the old Spillcheck entry from Login Items in System Settings.
