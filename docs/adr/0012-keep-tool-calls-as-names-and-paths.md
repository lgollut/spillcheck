# Keep a tool output's call as names and paths

Decision date: 2026-11-02. Status: accepted.

A tool output's appearance names the call that produced it, so a value from a test fixture can be
told apart from one in a `.env` file before deciding ([decision 0010](0010-show-values-while-unlocked.md)).
The call is kept with the appearance's other encrypted references: the tool, the program a shell
command ran (with the subcommand of tools such as git), and the files the call read, changed or
searched. The command line and the call's other arguments are not kept.

- An argument can hold a secret: a password passed to a command, or a search for a token. Removing a
  value's retained content deletes its excerpts, and excerpts mask the other values detected in the
  same output, but nothing would find the value inside a stored command. File paths rarely hold
  secrets, and the program and its files say where the content came from.
- Paths come from the agent's own record when it has one: the file a Claude Code file tool named, or
  Codex's parsed reading of a command. Otherwise only programs known to print files, such as `cat`,
  `sed` or `grep`, contribute their file operands. A pattern, a script or an option's value never
  becomes a path.
- Claude Code writes a call and its result on separate rows, which different polls often read, so the
  collector looks back up to 1 MiB in the transcript for a result whose call it hasn't seen.
- Appearances kept before this decision have no call. While the session is unlocked, the app looks
  for it in the agent's history file, reading at most 32 MiB, and shows it without storing it. Once
  that history is gone, those appearances show no call.
