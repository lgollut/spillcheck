---
"spillcheck": patch
---

New activity is analyzed promptly while history catch-up is running. History got one turn for every four live captures, but a catch-up pass can take nearly two minutes while a live capture takes a fraction of a second, so catch-up held the worker almost all the time and new activity waited in a growing queue. After each catch-up pass, live work now gets as much time as that pass took before catch-up continues.
