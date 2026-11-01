---
"spillcheck": patch
---

Spillcheck no longer rebuilds its coverage report every second while nothing has changed. Each rebuild decrypted up to a few thousand stored records, so the app kept using CPU even when idle.
