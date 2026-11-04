# Run one catch-up per profile

Decision date: 2026-11-04. Status: accepted.

Every launch, resume and history retry started a new catch-up (historical audit). Earlier unfinished
ones kept running. Their pages interleaved in the queue, and each rewound the per-file positions the
other had saved, because Claude's history cursor rereads from the previous audit's end, or from the
tail, whenever the audit end changes. None finished. On 2026-11-03 the vault held 49 audits, the
last completed catch-up was a day old, and every audit still reported unread history.

A profile now has one catch-up at a time.

- Before a new catch-up of a profile is queued, the profile's other queued catch-up pages are
  removed and their audits are marked superseded. The new audit reads the same files from the
  positions they saved. A page that is being read finishes but queues no next page.
- A retry's reread of one source is not a profile catch-up and keeps its own reads.
- An unfinished audit counts as settled once a later catch-up of the whole profile completes with an
  end at or after its own. That catch-up read everything in its seven-day window, which is all the
  older audit could still recover ([ADR 0005](0005-observed-collection-compatibility.md)).
- A superseded audit's backlog is not listed again while the newer catch-up is still reading it.

Reusing one audit identity with a moving end was rejected. Audit identity keys the frozen read
window, historical summaries and their notifications, and an older build's checks would reject it.
Progress records written before this decision say neither whether they read one source nor whether
they were superseded. A completed catch-up can still settle them, but it cannot itself be one of them.
