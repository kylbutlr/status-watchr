# Internal Codex review filtering

Status Watchr observes conversations and normal subagents, not Codex's internal Guardian review threads. A conversation named `Guardian review` remains visible if its metadata identifies it as an ordinary conversation.

## Collection and filtering

The Mac observer classifies reviews from `threads.thread_source = 'guardian_review'` or the structured `source.subagent.other = 'guardian'` value. It never infers the classification from a title or message. Reviews are excluded before the 100-thread discovery limit. Older schemas without either classification field retain their previous behavior, because there is no verified type signal.

Hook events must resolve to an observable local thread before generating activity. Unknown or temporarily unavailable identities wait for history recovery. Review hooks are ignored. Normal subagents remain eligible.

The observer also reads identifiers of classified reviews, including archived ones, to hide activity already uploaded by older builds. It queues authenticated `local/threads/excluded` reports in batches of at most 100 UUIDs through the existing offline outbox. Reports contain only the IDs, a deterministic event ID, and fixed protocol metadata. They contain no review titles, messages, prompts, tool inputs, outputs, or final-reply previews.

Exclusion reports are sent before older queued activity. If classification delivery is rejected, the batch stops so old review activity is not replayed ahead of its exclusion. A failed/offline report remains queued under the existing seven-day outbox rule.

## Hosted behavior and retention

Migration 007 adds an ID-only `internal_review_threads` registry. Reports are idempotent. Registered threads are excluded from feed pages, counts, timelines, watch settings, subsequent activity ingestion, and notification dispatch, including already queued notifications. The snapshot revision changes when the registry changes, so a conditional refresh cannot keep the old feed indefinitely.

Already stored session/event history and watch preferences are not deleted by classification. Existing 30-day activity retention still applies. Unsent review notification jobs are canceled atomically with classification, and the dispatcher independently checks exclusions before sending. Exclusion IDs can expire after 37 days only when no corresponding session remains. The Mac's metadata database and review threads are never modified.

## Rollout

1. Back up the private database and apply [migration 007](../database/migrations/007_internal_review_exclusions.sql).
2. Deploy the updated API and notification sender.
3. Publish the signed Mac update through the existing release workflow.
4. Let the updated observer report classified IDs. Confirm the live feed and counts no longer include internal reviews, and test one ordinary watched completion on the phone.

Production migration, deployment, and native publication require release approval. Local fixture verification does not establish installed-app or phone behavior. Older Mac builds cannot prevent new review activity on their own; the native update is required for complete filtering.
