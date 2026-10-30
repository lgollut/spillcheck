---
"spillcheck": patch
---

Spillcheck starts by itself after you unlock the Mac, if it was opened while the Mac was locked. Its vault keys can be read only while the Mac is unlocked, so a launch during a lock, for example after an update or a crash, failed to open the vault and stayed stopped until you quit and reopened it. It now opens the vault at the next unlock. Other startup failures still wait for you, as before.
