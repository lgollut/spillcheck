# Ask one question and keep the reason as a label

Decision date: 2026-11-03. Status: accepted.

Review offered six answers: Test or dev only, Not a secret and Needs rotation as buttons, then
Real, but keep it, Already rotated and Already revoked in a menu. They lead to only two outcomes.
Needs rotation moves a value to To rotate. Every other answer moves it to Done, where later appearances
stay quiet. Which answer led there only changes the label the value keeps. A short-lived download token
that had expired showed the cost: the right answer was hidden in the menu as Already revoked, a word that
doesn't say "expired".

Review now asks whether the value needs rotating. Every no carries a reason: not a secret, test or dev
only, no longer works, or real but kept as is. The reason doesn't change where the value goes or whether
it alerts; it names the value in Done.

- Rotated, revoked and expired are shown as one answer, "No longer works". From review it records
  revoked, meaning invalidated without a replacement from the user. From To rotate it records rotated.
  Values marked before this decision keep the raw value they had, and both show as "No longer works".
- The stored values don't change. The vault decodes value decisions and acknowledgements strictly, so a
  new case such as `expired` would make an older build fail to read the whole vault. Recording expiry
  separately would take two releases: one that tolerates unknown values, then one that writes them.
- No longer works stays an obsolete acknowledgement, not a value decision, so
  [decision 0004](0004-remember-obsolete-values.md) still applies. While a value's content is retained,
  its later appearances are kept with their excerpts, like a dismissed value's. Once the content is
  removed, they keep only their source and time.
