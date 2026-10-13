---
"spillcheck": patch
---

Fix Claude history catch-up repeatedly rejecting large batches without saving progress. Read dense transcripts in smaller resumable batches and recognize permission-setting records from setup sessions so they no longer cause false format warnings.
