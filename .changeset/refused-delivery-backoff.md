---
"spillcheck": patch
---

When protected storage refuses captures for a while, Spillcheck now retries the affected sources at a slower pace and records one delivery warning per source every five minutes instead of one on every check. This keeps the coverage history from growing quickly during an outage.
