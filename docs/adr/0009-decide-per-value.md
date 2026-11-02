# Decide once per value

Decision date: 2026-11-02. Status: accepted.

The user decides once per exact value whether it needs rotating, and the decision covers every
appearance of that value, including later ones:

- **Needs rotation**: a real credential still to change at its service. It stays live: a later
  appearance in another conversation alerts as an undecided value's would.
- **Test or dev only**, **Not a secret** and **Accepted risk** dismiss the value. Later appearances
  are recorded and counted, without alerts, catch-up summary counts or a return to review.
- Rotation and revocation remain obsolete acknowledgements
  ([decision 0004](0004-remember-obsolete-values.md)). Acknowledging one replaces a decision, and
  a value acknowledged rotated or revoked takes no decision until the acknowledgement is forgotten.

This replaces the per-occurrence review the specification confirmed earlier. Reviewing appearances
one by one asked the same question many times for one value, had no answer for a real credential
that only works in development, and sent a dismissed value back to review whenever an agent
printed it again.

Like the obsolete marker, a decision is keyed by the value's keyed fingerprint and holds no value,
excerpt or occurrence history. It survives removal of the retained content. Unlike an obsolete
value, a decided value's later appearances are retained again, so they can still be inspected;
only obsolete values keep the metadata-only rule of decision 0004. Forgetting the decision of a
value whose content was removed removes its entry.

A detection whose exact value wasn't located has no fingerprint to recognize again. Its decision is
stored with that result and covers it only.

Decisions are part of the inventory snapshot. A vault written before this decision derives them
from its per-occurrence reviews when it is read: a value with any appearance confirmed as a secret
needs rotation, and a value whose appearances were all marked false positives is not a secret.
Other values stay undecided, and the derived decisions are stored with the next change.
Per-occurrence reviews stay in the snapshot as they were. The app no longer offers them;
acceptance fixtures still use them to build an older vault's state. An older build ignores stored
decisions: it can still open the vault, and drops them when it next writes.
