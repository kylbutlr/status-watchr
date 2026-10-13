# Conversation grouping

The dashboard shows one row for a main conversation. Its subtasks appear in that conversation's activity log, labeled with their existing titles. Parent status, current run and watch identity remain authoritative; a finished subtask cannot turn a working parent into a finished row.

The title repair exposed separate subtask rows that already had independent Codex IDs. Titles are display metadata, never grouping keys. Conversations with the same title remain separate unless Codex supplies a structured parent relationship.

Migration 008 adds an ID-only relationship registry and a shared `conversation_roots` view. Feed grouping happens before status filters, counts and ten-row pagination. Nested subtasks resolve to the highest retained ancestor, with a maximum of 32 links and cycle protection. If no ancestor is retained, the subtask stays visible so activity is not silently lost. Internal reviews remain excluded.

The Mac sends bounded `local/threads/relationships` metadata reports through its existing offline outbox. Backfill includes named, archived and older subtasks outside the 100-thread discovery window. Reports contain only child/parent UUIDs and fixed protocol fields. Future lifecycle events also carry the parent UUID, so an old subtask that resumes can restore an expired relationship. These reports create no lifecycle history or notification jobs. The completion-confirmation and ancestor-idle notification checks are unchanged.

The browser merges page updates by conversation identity, replacing older runs even when their session ID changes. A changed grouping revision resets loaded pages and timeline cache, preventing previously loaded subtask rows from lingering. Aborted responses cannot restore discarded pages or logs.

Activity retention remains 30 days. Unused relationship metadata can expire after 37 days only when no corresponding session or descendant relationship depends on it. Watch preferences remain conversation scoped, including explicitly watched subtasks; a watched subtask can still be opened through the watch list.

## Rollout gates

1. Obtain explicit approval to push, migrate, deploy and publish the native release.
2. Back up the private database and apply [migration 008](../database/migrations/008_conversation_relationships.sql). It is additive; do not deploy the new API before it exists.
3. Deploy the API and dashboard. Existing Mac builds retain their behavior until updated; no relationship is inferred from their titles.
4. Publish a signed Mac update using the [manual release workflow](../.github/workflows/macos-release.yml), then install it through Sparkle. A web deployment alone cannot provide local parent metadata.
5. After the first observer sync, refresh the [private dashboard](https://statuswatchr.netlify.app/). Verify one row for each retained main conversation, subtask entries in its log, correct counts and page loading, and continued suppression of completion alerts while a parent is running.

Local validation on October 11, 2026: 136 web tests passed, typecheck and production build passed; 108 native tests passed with five existing opt-in tests skipped. Regression cases cover nested and orphaned children, cycles, the 32-link bound, shared titles, counts, pagination, metadata retention, future activity and React refresh after backfill. Desktop and 390px phone review used synthetic responses from the real PostgreSQL API test, confirming named child entries in the parent log, pagination, filtering and return navigation. The task-owned preview and browser tab were stopped/closed afterward. This does not establish installed-app or production behavior. Database access/backup must be available before migration; if unavailable, keep rollout pending.

Rollback: redeploy the previous API/dashboard and keep the additive registry/view in place. The previous API rejects relationship reports, so an older native build is required for full rollback of the collector protocol. Keep the previously signed archive and source revision available.
