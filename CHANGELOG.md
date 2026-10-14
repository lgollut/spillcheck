# spillcheck

## 0.2.0

### Minor Changes

- 695a994: Read Claude subagents using their own native session identities and route child tool hooks to their exact transcript. Continue reading complete messages when a bounded read stops before an unfinished transcript line, recognize observed normal-mode control records, and recover affected saved cursors without duplicating existing occurrences. Retain child source selections for bounded retries without mistaking a successful parent read for child recovery.
  
  Add an explicit Settings opt-in for saved local Claude Desktop Code conversations, preserving existing defaults, profiles and connection proof. Show shared-profile collection as provider/profile transport evidence without attributing it to an originating app. Desktop side questions remain unsupported.
- 695a994: Collect prompts, final replies and hook-exposed tool results for explicitly selected Codex sessions, with encrypted duplicate suppression and visible identity conflicts. Select the hook or native-history route before admission and preserve it through replay; keep unrelated native sessions collecting. Label hook timestamps as observation times and explain unavailable intermediate replies, interruptions and storage limits. Automatic desktop side-chat enrollment and genuine side-tool acceptance remain pending.
- 695a994: Collect returned text from native Codex web-search items, with bounded parsing and recoverable coverage gaps. Report shared Codex profile activity without attributing it to an unverified CLI or app host.
  
  Allow explicit opt-in to partial Codex desktop collection from retained native conversations. Preserve existing profile authorization and show the remaining side-chat and encrypted child-input limitations.
  
  Keep missing native subagent instructions visible when a complete public read omits them, without treating inherited prompts as the subagent's original input.
  
  Bind prepared Codex resume commands to the finding's saved profile and home. Refresh commands when that binding changes and reject unmatched profiles instead of using the terminal's default home.
- 695a994: Show collection storage usage and remaining capacity before conversation and Codex hook records reach their limits. Explain capacity rejection separately from delivery failure, preserve duplicate suppression across lowered limits, and keep capacity warnings separate from missing-content reports.
- 662cfe6: Coverage gaps are now grouped by cause instead of listing every source and
  catch-up attempt separately. Each issue shows how many sources and records it
  affects, and one button retries all of its sources; each source can still be
  retried from the issue's details. Reads still in progress and content excluded
  from text analysis by design are summarized below the list.
- 639b516: Collect Claude Code and Codex sessions from releases Spillcheck has not been tested
  with, as long as their content can still be read, instead of stopping at an
  unsupported version. CLI and T3 sessions in the same home are collected side by
  side, and Coverage shows each host separately. Desktop app collection stays off.
  
  When some content can't be read, the rest keeps being analyzed: Coverage reports
  partial coverage, unread content is retried for up to seven days, and required
  content that stops being collected triggers a masked notification. Prompts typed while Claude
  is still working are now checked too.
- 695a994: Report seven-day coverage and recovery accurately, retain historical losses separately from restored reads, and add scoped history retry and content-free diagnostics. Recognize current Codex tool output formats, retry unavailable Claude history, and prevent oversized records from stalling catch-up.
  
  Preserve exact key identities through interrupted vault setup and incomplete cleanup, and resume setup with them on the next launch instead of stopping or creating replacement keys. Require a matching committed store manifest before completing startup. Allow diagnostic export when the vault cannot open, and distinguish unavailable storage from a paused or empty inventory.
- 509bb01: Add a setup assistant that opens on first launch. It explains how Spillcheck
  works, finds Codex and Claude Code, adds hooks to the agents you choose, and
  confirms each connection with one test session. It then sets alerts and launch
  at login. Settings › General › Run setup again reopens it.
  
  Coverage is the home screen while the inventory is empty, and it shows clearly
  while the last 7 days are being read. Activity indicators no longer flicker.
  Notification and launch-at-login settings update when you return to the app.
  
  Fix detection that could stall while stopping a scanner, which left new
  sessions unscanned. Reading history now ends once history is read, even while
  agents stay active.
- 550b326: Unlock once, then reveal freely. Touch ID or your password now unlocks the inventory, the way a password manager does. While it's unlocked, Reveal shows a value, its excerpt and its source without asking again. The value stays revealed as you open its other appearances, and Hide or choosing another value only hides it again. Unlock and Lock sit at the bottom of the sidebar. The app still locks after 5 minutes idle, when the window closes, or when the Mac sleeps or locks.

### Patch Changes

- 744b471: Show which agent is catching up. While Spillcheck reads the last seven days of history, Coverage now marks the agent being read with a "Catching up" indicator in its own row, instead of a banner above the totals that didn't say which agent was working. A wave crosses that agent's days not read yet, and a day fills in as soon as content from it is analyzed. Each agent's seven days now form a single bar instead of a row of checkbox-like squares, and days before the agent was set up are striped.
- 7d9e310: Give each agent its own Settings page. Codex and Claude Code now appear under Agents in the Settings sidebar, with a dot when one needs attention. Each page shows the agent's status and next step first, then the connection test while one is pending, then its executable, profile folder and desktop support, which you edit in place with a Choose button instead of in a separate dialog. Changes take effect when you choose Apply, and the page says when the profile folder can't change because hooks are installed. Collection details and known limits now live only in Coverage, the connection steps are shorter, and buttons no longer end in an ellipsis or get cut off.
- d05004e: Fix Claude history catch-up repeatedly rejecting large batches without saving progress. Read dense transcripts in smaller resumable batches and recognize permission-setting records from setup sessions so they no longer cause false format warnings.
- 695a994: Retry a selected Claude transcript when its original file returns after a temporary absence. Clear only that source's availability warning after a bounded native-identity and readability check; preserve unrelated content, scanner and delivery warnings. Keep newer absence observations and the original warning age so delayed reads cannot report a missing source as recovered.
- 695a994: Explain the Codex beta's side-chat, encrypted subagent-input and hook-context limits in agent settings and coverage. Preserve recorded gaps and partial coverage. Add a separate candidate-bound Codex trial scope that cannot relabel earlier measurements or imply Claude acceptance.
- 695a994: Collect native Codex hook-provided continuation input under its original item identity. Keep unreadable fragments visible as coverage gaps and use neutral input-message labels for text supplied by people, hooks or parent agents.
- 695a994: Keep JSON printed in Codex hook tool-output strings from being mistaken for execution status. Preserve the returned bytes and recognized structured status envelopes, and report an immutable-source conflict when replay would change an older classification.
- 695a994: Recognize Codex local image and audio attachments as excluded media while continuing to analyze accompanying text. Correct only a proven obsolete attachment-format warning; retain unrelated content and scanner failures.
- 695a994: Scan readable strings in native Codex MCP structured results, including business fields named `type` or `content`. Preserve their original locations and keep protocol media and encrypted blocks separate.
- 695a994: Collect native Codex assistant text with an explicit unknown phase or a partial-answer phase. Preserve its original identity and bytes without claiming it is a final answer, retain warnings for malformed phases, and revisit older audits to recover omitted originals.
- 695a994: Scan native Codex proposed-plan text under its original item identity. Recover previously skipped plans on a new audit, preserve surrounding replies, and report unreadable plan content as a coverage gap.
- 695a994: Resolve duplicate Codex review warnings only after verifying the original native source and its full scan receipt. Support explicit input root-turn relationships and bounded input and reply inspection across pages and restarts, preserving ambiguous or incomplete coverage without duplicate appearances.
- 695a994: Keep the original time window of a failed live read and verify every page of its recovery before clearing the warning. Retry only the selected source, preserve unrelated omissions, and keep targeted recovery usable when completed history exceeds the coverage report limit.
- 695a994: Accept Codex's explicit empty-output representation for finished commands. Recover the affected format warning without inventing tool text, findings or scanner receipts.
- 695a994: Recognize Codex duration-only sleep display items without creating false content warnings. Recover only the exact earlier optional format warning; preserve missing-content and scanning failures at the same native item.
- 695a994: Record the Codex reader that actually returned content after an upgrade, while preserving queued work's original configuration. Keep mixed or missing version evidence unknown and reject executable replacement during startup. Give a reinstalled Codex profile a fresh identity when its native home changes, and describe unavailable opening routes without claiming the conversation was deleted.
- c7c7567: Reduce CPU use while coverage gaps are shown. Spillcheck refreshes coverage every second; with many gaps from the past seven days it could keep a full processor core busy during and after catch-up. Coverage status is now prepared once for each change instead of separately for every place that shows it, and a refresh that finds nothing new no longer rebuilds it. Coverage results and available actions are unchanged.
- f4440d9: Show partial coverage explicitly in agent status summaries, even when live reads and catch-up are available.
- 6ccc10b: When values need review, the menu bar icon's drop now turns amber instead of a
  small dot appearing beside the icon. The icon keeps its size and stays centered.
- ee8513c: Make an expanded appearance easier to read. The excerpt is now framed like a code block, with the conversation title, project path and a Clipped tag in its header, and it stays distinct from the row in dark mode. Alert and link status follow as labelled facts, and one row at the bottom holds "Is this a secret?" alongside Open conversation or Resume in Terminal. Conversation headers and the resume sheet now show the agent's mark and name, and the resume sheet shows the command first with a Copy command button.
- 6a276c8: On the setup assistant's Connect step, each agent's test session now opens in
  that agent's own row, so it's clear which agent a command verifies. The first
  agent still waiting opens on its own, and the next one opens once it's
  verified. Chosen agents have a sharper outline that matches their checkbox.
  
  Open at login can now be turned on in setup and in Settings. It was unavailable
  until Spillcheck had been added as a login item once.
