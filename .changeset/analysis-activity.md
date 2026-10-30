---
"spillcheck": patch
---

Captures keep being analyzed while the screen is locked. macOS naps apps that have no visible window, and Spillcheck did not say it had work waiting, so while the Mac was locked it got almost no processor time: it finished nothing for minutes while agents kept adding captures, and a long absence could let queued captures reach their 24-hour limit. Spillcheck now tells macOS it is busy while monitoring is on and captures are waiting, and stops as soon as the queue is empty. The Mac can still go to sleep as usual.
