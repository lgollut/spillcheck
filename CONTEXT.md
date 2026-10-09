# Auditing secrets in agentic sessions

Vocabulary for the application that inventories secrets observed in agentic development sessions.

## Language

**Secret**:
A confidential value used to authenticate access, sign data, or decrypt data. The scope includes API keys, tokens, passwords, private keys, and secret credentials in connection strings.
_Avoid_: Personal data, which refers to a different category.

**Agentic session**:
A development conversation with an agent, including its messages and associated tool calls.
_Avoid_: Project, when referring to a specific conversation.

**Monitoring**:
Ongoing observation and analysis of new agentic-session content for secret occurrences.
_Avoid_: Historical audit, when referring to ongoing collection of new content.

**Historical audit**:
Analysis of previously retained agentic-session content for secret occurrences.
_Avoid_: Monitoring, when referring to analysis of existing history.

**Coverage**:
The scope of agentic-session content the application has actually observed and analyzed, described by agent, content type, and time period.
_Avoid_: Connected, which establishes a working collection route without establishing complete coverage.

**Collection compatibility**:
The assessed ability of a collection route to read and interpret the session content it is intended to collect. Compatibility is distinct from measured coverage and acceptance evidence for a particular environment.
_Avoid_: Supported version, when only an exact release number has been checked.

**Collection degradation**:
A reduction in the routes or required content types that monitoring can analyze while the remaining usable collection continues. The missing scope remains visible as partial coverage.
_Avoid_: Service outage, when only part of collection is affected.

**Connection verification**:
Evidence that an owned collection route delivered its verification event for encrypted capture, scoped to that route's configuration. Remembered verification does not establish recent collection activity or complete coverage.
_Avoid_: Coverage verification.

**Acceptance evidence**:
Recorded test results establishing which agent environments, collection routes, and content types were exercised successfully.
_Avoid_: Compatibility guarantee for untested environments.

**Agent host**:
The CLI or application through which an agentic session runs or is presented. The host is distinct from the agent that produces the session content.
_Avoid_: Agent, when referring only to its host application.

**Collection route**:
An authorized way for Spillcheck to receive or read content from an agentic session. Several routes can observe the same session without creating separate occurrences of the same content.
_Avoid_: Agent host, which describes where the session runs or is presented.

**Tool output**:
Content returned by a tool during an agentic session, including results and errors.
_Avoid_: Model response, when referring to a tool result.

**Model response**:
A message produced by the model during an agentic session, whether intermediate or final.
_Avoid_: Tool output, when referring to an assistant message.

**Occurrence**:
A specific appearance of a suspicious value in session content, with its location and source.
_Avoid_: Secret, when counting multiple appearances of the same value.

**Detection**:
A signal identifying a value as a probable secret in an occurrence, together with the evidence supporting it.
_Avoid_: Active secret, which assumes validity that the signal has not established.

**False positive**:
A detected occurrence that the user has determined does not contain a secret in its context.
_Avoid_: Remediated secret, which assumes an actual secret and a remediation action.

**Confirmed secret**:
A detected occurrence that the user has confirmed contains a secret in its context. This review does not establish whether the value is still usable.
_Avoid_: Active secret, which implies validity that has not been checked.

**Obsolete value**:
A secret value the user has acknowledged as rotated or revoked. A later appearance of that exact value retains this classification, based on the user's acknowledgement rather than verification by the application.
_Avoid_: False positive, which concerns whether an occurrence contains a secret.

**Secret inventory**:
The central list of detected secrets and their associated occurrences, available for the user to browse.
_Avoid_: Alert log, when referring to browsable secret records.

**Context excerpt**:
The portion of a message or tool output surrounding an occurrence that helps explain its appearance.
_Avoid_: Conversation, when only a portion of its content is retained.

**Remediation**:
An action to address a secret exposure, or the instructions needed to carry out that action.
_Avoid_: Rotation, when the action does not replace a secret.

**Rotation**:
Replacing a secret and invalidating its previous value.
_Avoid_: Masking, which only changes a value's visibility.

**Revocation**:
Invalidating a secret value without requiring a replacement value.
_Avoid_: Deletion, which removes data from the inventory without establishing invalidation.
