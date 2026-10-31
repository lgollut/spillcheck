---
"spillcheck": patch
---

Analyzing conversations stays fast in a vault that has been in use for a long time. Every analyzed conversation item used to rewrite Spillcheck's whole record of what it had already analyzed, more than ten megabytes in a large vault, so each item took longer than the last and busy sessions fell behind. It now rewrites only the part of that record the item changed, a few kilobytes. The vault converts to the new layout the first time Spillcheck saves new activity, and nothing is deleted. Versions of Spillcheck from before this change cannot open the converted vault, so going back to one needs a backup of the vault taken beforehand.
