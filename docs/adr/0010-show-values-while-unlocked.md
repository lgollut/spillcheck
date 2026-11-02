# Show every value while unlocked

Decision date: 2026-11-02. Status: accepted.

One authentication unlocks a viewing session, and while it lasts every selected value shows with
its context: the value, the selected appearance's excerpt, and its conversation title and project
path. There is no Reveal action per value.

Reviewing a backlog meant selecting a value, choosing Reveal, expanding an appearance and repeating
for the next value. A value on its own also says little: whether a password matters depends on the
`.env.local` or test fixture it came from. Deciding quickly needs the value and its context together.

- Unlocking prompts once, as before. Lock, five idle minutes, closing the window, sleep and macOS
  session lock still end the session.
- Showing content on its own never prompts. Reveals made for a selection may not authenticate, so a
  session that locked or expired meanwhile leaves the content masked.
- Hide values masks content without locking, and it stays masked across selections until shown
  again or the session ends, for example while sharing the screen.

This replaces "context while unlocked, value still hidden" (#17): it kept the friction of a reveal
per value while showing the context around it.
