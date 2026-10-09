---
spillcheck: minor
---

Add a setup assistant that opens on first launch. It explains how Spillcheck
works, finds Codex and Claude Code, adds hooks to the agents you choose, and
confirms each connection with one test session. It then sets alerts and launch
at login. Settings › General › Run setup again reopens it.

Coverage is the home screen while the inventory is empty, and it shows clearly
while the last 7 days are being read. Activity indicators no longer flicker.
Notification and launch-at-login settings update when you return to the app.

Fix detection that could stall while stopping a scanner, which left new
sessions unscanned. Reading history now ends once history is read, even while
agents stay active.
