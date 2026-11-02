---
"spillcheck": patch
---

A long catch-up pass is no longer abandoned while it is still making progress. Each pass has 110 seconds. A pass that ran out of time used up one of its three retries even when it had analyzed new content, so a large pass was dropped and its remaining history was reported as missed. A pass that analyzed new content now resumes straight away without using up a retry, and skips what it already analyzed. A pass that adds nothing still counts toward the limit.
