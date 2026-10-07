# Remember obsolete values after their retained content is deleted

The user wants later appearances of a rotated or revoked value to be recognized after removing its stored value and context. Keep a keyed exact-value fingerprint and the user's acknowledgement until explicit forgetting or app reset, without retaining the old value, excerpts, or occurrence history in that marker. New appearances of the same value are recorded as obsolete without notifications; different replacement values follow normal detection and alerts.

The acknowledgement is a user assertion, not verified credential invalidation. Deletion alone does not mark a value obsolete. Forgetting its recognition marker means a later new appearance receives ordinary evaluation, while independent processed-source receipts still prevent old history from recreating deleted occurrences.

After retained content is removed, obsolete reappearances keep only their source reference, timestamp, and obsolete label. They do not recreate a retained value or excerpt, so those appearances have no context fallback if the source later disappears.
