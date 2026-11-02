---
"spillcheck": patch
---

Make the Coverage report cheaper to refresh when many gaps have been recorded. It now finds the newest gaps through an index instead of reading and sorting every one from the past week each time it updates.
