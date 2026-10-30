---
"spillcheck": patch
---

Captures are analyzed faster when many are waiting. Queueing, claiming and finishing a capture, and the once-a-second refresh, each read every queued capture and every work and omission record to check sizes, find expiring items or pick the next capture. The longer the queue grew, the slower each capture became, so a busy session could add captures faster than they were analyzed. These steps now look their rows up through indexes and read a few dozen database pages instead of thousands. The indexes are added once when Spillcheck opens the vault.
