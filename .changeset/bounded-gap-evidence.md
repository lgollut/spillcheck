---
"spillcheck": patch
---

Fix collection stopping after a long history catch-up. Spillcheck kept the record of every capture that noted a gap until the vault's storage limit was reached, and then could not accept any new capture. It now keeps the most recent of these records, trims a vault that is already full when it opens, and keeps collecting.
