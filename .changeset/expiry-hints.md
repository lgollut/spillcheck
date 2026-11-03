---
"spillcheck": minor
---

When a value is revealed, Spillcheck now reads what its content says about when it stops working, and says so next to the value: the token's own expiry, a signed link's end date, an expiry field printed next to it (such as a session's `expiresAt`), or a GitHub download link, which GitHub says expires on its own. When that date has passed, or a GitHub download link was last seen more than a day ago, the value is tagged "Expired" or "Probably expired", the review explains why, and No longer works (X) becomes the highlighted answer. A date printed next to a value is only what the output said at the time, since a session can be extended each time it is used, so Spillcheck suggests the answer and never decides it for you.
