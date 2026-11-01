---
"spillcheck": patch
---

Use less CPU while Spillcheck catches up on recent history. Coverage details were rebuilt every second because something was written almost every second, which kept a noticeable share of a processor core busy. The periodic refresh now reuses them for up to five seconds, while the queue count and activity still update every second and anything you do refreshes coverage at once.
