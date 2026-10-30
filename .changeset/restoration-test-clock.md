---
{}
---

Three Claude source restoration tests failed whenever the full test suite ran slowly. Their
monitor and reports ran on a fixed fixture time, but gaps were recorded at the wall clock, so
after a few seconds the gaps fell outside the report window. Gaps are now recorded at the time
the monitor observed them. Only tests change, so no app version bump is needed.
