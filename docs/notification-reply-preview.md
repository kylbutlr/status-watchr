# Watched notification details

Publishing this source branch alone does not update phone notifications. The database migration, hosted deploy, and signed Mac release are separate steps.

## What changes

- The notification displays the watched conversation title when available.
- A recent completed turn can include a short prose excerpt from its final agent answer. Code fences, headings, tables, and block quotes are skipped. Missing or unfamiliar answer data falls back to `Run finished.`
- The Mac reads only a validated Codex rollout path under its local sessions directory and only for the exact completed turn. The excerpt is capped at 180 UTF-16 units. The full answer is not added to Status Watchr's activity history.
- The local outbox holds the excerpt until ingestion; the hosted notification job holds it for retries, then clears it when the push provider accepts delivery. The job is deleted after seven days. The encrypted Web Push payload carries the excerpt to the enrolled device. Titles and excerpts can contain sensitive client information and appear on the lock screen or paired watch.
- The push payload retains its previous generic body for older installed service workers. An updated worker displays the title and excerpt. App Switchr still controls whether automatic cloud work proceeds.

## Publication sequence

1. Before any hosted write, make and verify a production database backup. Apply [migration 006](../database/migrations/006_notification_reply_preview.sql), then verify the new nullable `reply_preview` column exists. It is additive; old functions can keep using the table.
2. Publish the web/functions bundle only after the migration. Verify the deployed service worker and Functions versions, and check that existing watch and device settings remain intact.
3. Build, sign, notarize, publish, and install a monotonically versioned Mac release through the repository's verified release workflow. A source push alone does not update the installed Mac companion.
4. On a real iPhone with the Home Screen app, confirm a watched completion shows the correct conversation title and excerpt. Also check a completion without a final answer, a failed run, an attention alert, a test alert, App Switchr Off then On, and notification tap behavior. Verify lock-screen presentation with the user's intended iOS preview settings.

## Rollback

If a preview exposes unwanted content, stop new delivery by turning off notifications or revoking the enrolled device, then redeploy the prior web/functions build and install the prior signed Mac build. A push already accepted by the provider cannot be recalled. The nullable database column can remain during rollback; do not drop it while a queued job or newer function may use it.
