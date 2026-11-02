---
"spillcheck": patch
---

Captures are analyzed much faster while the Spillcheck window is open. Every analyzed capture re-saved what Spillcheck knew about that agent's collection, even when nothing had changed, so the whole coverage view was rebuilt and laid out again for each capture. With a backlog that kept the app's main thread busy most of the time, and analysis waited for it. Spillcheck now updates the view only when something it shows has changed.
