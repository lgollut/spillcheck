---
"spillcheck": patch
---

Claude tool and prompt events from long conversations are no longer reported as lost. Spillcheck matches each tool or prompt event to the conversation rows it has read, and remembers up to 2,048 such calls per conversation. Once a conversation passed that number, it kept the wrong ones, so most new calls were forgotten as soon as they were read. Their events were retried as if the conversation had not been saved yet, then reported as not analyzed, although their content had been analyzed. Spillcheck now remembers the most recent calls.
