---
"spillcheck": patch
---

Spillcheck no longer polls a quiet Codex conversation every second indefinitely. Each poll rereads the conversation's latest items, and reading them counted as new activity, so the conversation never went quiet. The polls piled up faster than Spillcheck could analyze them and held back everything queued behind them. A conversation now counts as active from the time of its newest item. Polling slows to every 5 seconds after two minutes and stops after an hour, as intended.
