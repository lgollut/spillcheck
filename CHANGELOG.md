# spillcheck

## 0.2.0

### Minor Changes

- 639b516: Collect Claude Code and Codex sessions from releases Spillcheck has not been tested
  with, as long as their content can still be read, instead of stopping at an
  unsupported version. CLI and T3 sessions in the same home are collected side by
  side, and Coverage shows each host separately. Desktop app collection stays off.
  
  When some content can't be read, the rest keeps being analyzed: Coverage reports
  partial coverage, unread content is retried for up to seven days, and required
  content that stops being collected triggers a masked notification. Prompts typed while Claude
  is still working are now checked too.
- 509bb01: Add a setup assistant that opens on first launch. It explains how Spillcheck
  works, finds Codex and Claude Code, adds hooks to the agents you choose, and
  confirms each connection with one test session. It then sets alerts and launch
  at login. Settings › General › Run setup again reopens it.
  
  Coverage is the home screen while the inventory is empty, and it shows clearly
  while the last 7 days are being read. Activity indicators no longer flicker.
  Notification and launch-at-login settings update when you return to the app.
  
  Fix detection that could stall while stopping a scanner, which left new
  sessions unscanned. Reading history now ends once history is read, even while
  agents stay active.
