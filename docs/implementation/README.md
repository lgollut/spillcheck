# Recorded implementation evidence

Published reports are redacted copies of the development acceptance evidence. They retain measured results, pass/fail status, test scopes, and recorded limitations. Personal identity and machine-specific path metadata has been replaced with placeholders.

- `<HOME>` identifies a user's home directory, and `<PROJECT_ROOT>` identifies the checkout.
- `<TMPDIR>` and `<TMPDIR_ALIAS>` identify a temporary base and its alternate spelling. Separate tokens preserve the recorded path-alias checks.
- `<RUN_001>` and the other numbered run tokens identify temporary artifacts consistently across related fields.
- `<ARCHIVE_ID>` replaces a generated local archive directory name.
- `<TEAM_ID>` and `<SIGNING_IDENTITY>` replace personal Apple signing details where they appear in documentation.
- `<CLAUDE_EXECUTABLE>` replaces the local path of the Claude executable used by a run.
- `<NATIVE_SESSION_001>` and `<NATIVE_ITEM_001>` through `<NATIVE_ITEM_010>` replace provider-native session and item identifiers. Like the run tokens, they identify related records consistently.
- `<OWNED_GUI_PROJECT>` replaces the disposable project directory selected in a provider GUI, and `<CHILD_TRANSCRIPT>` replaces a native child session's transcript path.

Recorded commands containing placeholders need values from your own environment before they can be rerun. The reports describe the tested versions and development setup; their results do not establish compatibility with other versions or platforms.
