# Keep read marks outside the vault

Decision date: 2026-11-02. Status: accepted.

The inbox marks a value unread when it has an appearance newer than the user has seen, and sorts
unread values first. This replaces the "While you were away" summary in the list. Read marks change
every time the user opens a value, so they are stored in the app's preferences, not in the encrypted
ledger.

- A mark is the entry's app-assigned number (the `#12` shown in lists and notifications) and the time
  of the latest appearance seen. Nothing about the value, its context, conversation or project is
  stored, and entry numbers are never reused.
- A baseline time is set when marks are first used, so a backlog that existed before doesn't all
  start out unread.
- Writing the ledger for every selection would reseal inventory state on each click.

Consequences: someone who can read the preferences learns how many entries exist and when the user
last looked at each, which the encrypted ledger would otherwise hide. Losing the preferences only
loses unread marks; every value keeps its decision.
