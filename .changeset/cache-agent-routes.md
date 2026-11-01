---
"spillcheck": patch
---

The Coverage page and the menu bar no longer rebuild each agent's connection state several times per redraw. Building it filters every current coverage limitation, and with thousands of records this kept the main thread busy while the Coverage page was open.
