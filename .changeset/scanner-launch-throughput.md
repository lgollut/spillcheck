---
"spillcheck": patch
---

Scan tool results with many fields within the scan deadline. Each string field gets its own scanner launch, and each launch re-checked the scanner files and then waited about 100 ms after the scanner had finished. A structured result with a few hundred fields ran out of its 30 seconds every time, was retried, and was reported as not analyzed. The scanner files are now checked once per result, a launch returns as soon as the scanner exits, and up to four launches run at once. Each field is still scanned on its own, so results are unchanged.
