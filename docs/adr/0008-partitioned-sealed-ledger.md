# Seal the inventory ledger as separately stored segments

Decision date: 2026-10-31. Status: accepted. This changes the on-disk format and
cannot be undone by an older build.

The whole inventory snapshot used to be JSON-encoded, sealed and written into one
`store_state` row by every commit. Nearly all of it is per-source bookkeeping (the
analyzed revisions, content type and content time of each source), and a commit
changes one entry of it. A vault of 20,000 sources rewrote about 15 MB for every
source it analyzed, so the longer a vault had been used the longer each analysis
took, and the long seals made `stateChanged` collisions with notification
delivery likely.

## Decision

The ledger is stored as segments, each sealed on its own:

- a header in `store_state`: layout version, revision, a random 32-byte bucket
  salt and the revision each other segment was last written at;
- three parts in `ledger_parts`: the core (values, occurrences, receipts,
  labels), the notification decisions, and the conversation labels;
- 64 buckets in `ledger_buckets` holding the per-source bookkeeping. A source
  lives in the bucket chosen by HMAC-SHA256 under the salt over its length-framed
  identity.

`InventoryLedger` and `InventorySnapshot` are unchanged. Bookkeeping mutates
through `SourceBookkeeping`, which journals each source it touches. A write seals
the buckets of the journaled sources, each part that differs from the committed
one, and the header. A quiet source seals the header and one bucket, a delivery
seals the notifications part, and a replay seals the header alone. The check
order of `commit` and `mutateLedger`, and the one transaction that writes rows,
outbox, links and checkpoint, are unchanged.

## Integrity

- Every segment has a deterministic binding: owner is the vault, kind is
  `ledgerSnapshot`, and the reference is derived from the vault and the segment's
  slot. A row moved to another slot or vault does not open.
- A segment records the revision it was written at, and the header must name it.
  A bucket restored from an older copy, a missing or misplaced entry or a repeated
  source is `corruptProtectedState`. Open validates the reassembled snapshot as
  before, never writes, and `maxProtectedStateBytes` bounds the sum of all
  segments. The empty ledger already takes about 4 KB of that.
- Commits compare the mirror of the buckets with the journal's changes by count,
  and compaction compares it in full once an hour. A mismatch rewrites every
  bucket. It costs performance only, because buckets are always rebuilt from the
  ledger.

## Conversion and older builds

Opening a vault from before this change writes nothing. Its first ordinary write
converts it in that write's transaction, after decrypting the sealed rows and
comparing them with the ledger. A kill at any point leaves the old row intact or
a complete new layout.

The header is sealed under a different binding than the old row, so an older
build fails to open a converted vault with `protectionUnavailable` ("Protected
storage could not be opened. Monitoring is paused.") rather than misreading it.
Nothing is deleted, but there is no way back except a backup taken before the
first write. This includes other branches and older Debug builds that share a
vault. `probe` counts the new tables as protected data, so missing keys can never
license replacing them.

## Leakage

Someone who can watch the database file sees which rows change and how large each
segment is. A write reveals its kind: a header alone for a replay, plus one bucket
for a quiet source, plus the core and notifications for a finding. Bucket sizes
reveal how many sources it holds. The salt sits in the sealed header, so the
bucket of a known identity cannot be computed from outside. The single row
already revealed the total size and that every commit rewrote it.

## Tuning

The bucket count of 64 is part of the layout. At 20,000 sources a bucket is about
130 KB, so a quiet commit still seals two orders of magnitude less than before;
a vault that grows far past that wants a new layout version with more buckets.
Debug builds with `SPILLCHECK_VERIFY_LEDGER_LAYOUT=1`, which the Makefile and CI
set, read the rows back after every write and require them to match the ledger.
