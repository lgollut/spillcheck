---
{}
---

Five tests failed whenever the full test suite ran slowly. Three Claude source restoration
tests recorded gaps at the wall clock while their reports ran on a fixed fixture time, a
disposable recovery test enqueued on the wall clock into a store with a five-second queue age,
and the scanner cancellation test counted the time to launch its process as part of stopping
it. Each now uses the clock it is checking. Only tests change, so no app version bump is needed.
