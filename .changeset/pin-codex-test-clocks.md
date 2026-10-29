---
{}
---

Two Codex tests ran their audit or pipeline on the wall clock while their fixture
items were dated 2026-10-08, so they started failing once that date left the
seven-day lookback. Their items are now dated from the same clock. Only tests
change, so no app version bump is needed.
