---
"spillcheck": patch
---

Claude Code 2.1.306 and later save request logs and workflow journals in their transcripts. Spillcheck now recognizes them instead of reporting tens of thousands of "Some content wasn't in a supported format" records, which kept Claude coverage partial and the app busy. A request log larger than 1 MB is still reported, like any oversized record. A workflow agent's structured result is now checked as that agent's final response.
