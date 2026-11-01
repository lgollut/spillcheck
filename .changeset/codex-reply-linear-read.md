---
"spillcheck": patch
---

Spillcheck reads large replies from the Codex reader faster. It searched each reply from the start again after every piece it received, so a page of several hundred kilobytes cost far more CPU than its size.
