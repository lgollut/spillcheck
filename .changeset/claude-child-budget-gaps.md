---
"spillcheck": patch
---

A Claude conversation with many finished agents no longer records a "not fully analyzed" warning about every 250 milliseconds. It is reported only when agents that are not being followed have changed, and at most once every five minutes, and watching such a conversation uses less CPU.
