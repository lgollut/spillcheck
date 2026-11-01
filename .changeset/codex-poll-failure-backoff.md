---
"spillcheck": patch
---

Spillcheck no longer keeps polling a Codex conversation that has been deleted. Reading a deleted conversation fails every time, and Spillcheck kept retrying it every second, which filled the queue with failed work and grew the list of content it could not read. A conversation whose polls keep failing is now polled less and less often, and goes back to its normal pace as soon as a poll succeeds or Codex reports new activity in it.
