---
"spillcheck": patch
---

Spillcheck now queues one read at a time for each active Claude conversation or Codex thread. It used to queue another read every time a conversation changed, up to four a second, even while an earlier read still waited, so a busy conversation filled the queue with reads that found nothing new and delayed everything else.
