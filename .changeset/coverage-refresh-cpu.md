---
"spillcheck": patch
---

Reduce CPU use while coverage gaps are shown. Spillcheck refreshes coverage every second; with many gaps from the past seven days it could keep a full processor core busy during and after catch-up. Coverage status is now prepared once for each change instead of separately for every place that shows it, and a refresh that finds nothing new no longer rebuilds it. Coverage results and available actions are unchanged.
