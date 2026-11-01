---
"spillcheck": patch
---

Spillcheck settles recovered coverage much faster while it catches up. Marking an earlier gap as recovered looked through every open gap of the past week for each location, and a catch-up recovers thousands of locations at a time, which kept a processor core busy reading the vault from disk.
