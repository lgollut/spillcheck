---
{}
---

Measure hook-helper delivery deadlines after socket connection and observe responses
without process-wait polling delays. This fixes CI timing failures and makes the
slow-input test wait for connection before delaying EOF. Only tests change, so no
app version bump is needed.
