---
"spillcheck": patch
---

A backlog of captures is analyzed without pauses. The analysis worker waited a quarter of a second after every capture, even when thousands were waiting, which alone added about a quarter of an hour to a backlog of 3,400 captures. It now goes straight to the next capture and waits only when nothing is ready or a capture could not be claimed.
