# Private pilot rollout: September 20, 2026

## Database backup and migration

Verified in the owner's signed-in Google Chrome session through native app controls. Browser-tab discovery did not expose Chrome, but native Chrome accessibility worked. Do not treat that discovery failure as a Neon login failure or ask the owner to use the internal browser.

- Project: Status Watchr, `restless-thunder-91056628`.
- Original production branch: [`br-misty-sky-akqqkw5q`](https://console.neon.tech/app/projects/restless-thunder-91056628/branches/br-misty-sky-akqqkw5q).
- Database: `neondb`, PostgreSQL 18.
- Created a manual snapshot named `production at 2026-09-21 06:13:23 UTC (manual)`. Neon reported successful creation. The snapshot has **no automatic expiry**.
- Verified recoverability with Neon's multi-step restore, which created a separate [verification branch, `br-fragrant-snow-akk8myjr`](https://console.neon.tech/app/projects/restless-thunder-91056628/branches/br-fragrant-snow-akk8myjr). No production connection migration, branch replacement, or one-step restore was performed.
- Read-only SQL found 418 `agent_sessions` rows and 595 `agent_events` rows on both the restored branch and original production. Both initially had only those two public tables. This proves snapshot restoration and matching counts, not a row-by-row content checksum audit.
- Production schema inspection confirmed `turn_id`, `last_event_at`, and the indexes from migrations 002 and 003. None of migration 004's four tables existed.
- Applied [migration 004](../database/migrations/004_personal_notifications.sql) to the original production branch in an explicit transaction. Neon showed all statements executed successfully, including COMMIT.
- Post-migration query verified four new pilot tables, the `notification_delivery_due` index, and unchanged activity counts: 418 sessions and 595 events. Zero existing sessions/events met the documented 30-day deletion thresholds at verification time.

The snapshot and restored verification branch retain existing private activity metadata, including titles. They remain in the same Neon project. Application retention does not delete these backup copies. Schedule their explicit cleanup after the pilot is accepted; do not silently delete the recovery point or verification branch.

## Operational notes

- The Intel Homebrew installer was stopped after explicit approval. ARM Homebrew installed `pg_dump`, `pg_restore`, and `psql` 18.6, with ARM64 executable architecture verified. No database server was installed or started. This backup used Neon's native snapshot and isolated restoration, not a local `pg_dump` archive.
- The migration was pasted, inspected, and only then executed. A later clipboard paste for a read-only verification query unexpectedly inserted unrelated text. That draft was **not executed**. Direct accessibility text replacement corrected it, and the exact SQL was inspected before running. Prefer direct text replacement in this shared workstation's SQL editor.
- Existing production-only VAPID configuration remains present and secret. Pre-deployment verification found the published web deployment still at `6aaed654812cd80009ba6245`, and the built signed appcast exactly matched the live feed.
- The staged private 0.1.13 / 1013 companion passed deep strict signature verification again. Installed build remained 1012. No native replacement or public native release occurred during the database steps.

## Authorized private web deployment

- Deployed source commit `0149aaf` to the existing private site after current approval. [Deployment `6ab0cd842d703b0949f78657`](https://app.netlify.com/projects/statuswatchr/deploys/6ab0cd842d703b0949f78657) is published and reports `ready`. The preceding deploy `6aaed654812cd80009ba6245` remains the web rollback reference; rolling back web code would not reverse the additive database migration.
- Verified the deployed `api` and `notification-retry` functions. The latter is registered with the every-minute schedule. Deployment activates the documented retention policy; do not describe retention as inactive after this checkpoint.
- Production function logs show five duration reports at 06:25, 06:26, 06:27, 06:28, and 06:29 UTC on September 21. All are informational, with no error-level entries, timeout marker, or fixed maintenance-error message in the retrieved window. This verifies scheduled execution, not push delivery or a production expired-row deletion test.
- Live health reports database/password configuration. Anonymous sessions, notification settings, and collector reads all returned 401. These checks alone do not prove database connectivity.
- The owner's existing Chrome session loaded 100 historical sessions and the selected activity timeline from the live database. The In progress filter displayed its empty state. Notification device settings loaded with the enable-device control available and the test control disabled before enrollment. No desktop notification permission or subscription was created.
- The existing Mac Keychain ingest credential authenticated empty requests to both collector and event ingestion. Both returned validation status 400, without creating test events or fake collector-health records. No credential value was printed or saved to source.
- The live appcast still exactly matches the pre-deployment feed, SHA-256 `a8a718e805224bf701ccbe606624d145c600d1e92e10f7b1d8bda5764d880200`. This was not a public native release. No Git push or PR occurred.

## Native replacement and next gate

The owner confirmed quitting Status Watchr. A fresh process check verified it had exited before replacement. The installed build 1012 was moved intact to the ignored `build/installed-1012-backup/Status Watchr.app` backup, and the staged build was copied to `/Applications/Status Watchr.app`. The installed bundle reports version 0.1.13 / build 1013, passes deep strict signature verification, and matches the staged executable SHA-256 `2742b9579ff6bd334c9f4117fdce53c9e488f3ec0c1ac2abefe2def9f6880a22`. It was reopened and its running process verified. This remains local-certificate signing, not Developer ID signing or notarization.

Native computer control again timed out while selecting the newly installed menu-bar app. No alternate system-control workaround was used. The observer does not automatically start at app launch; the owner has been asked to click Start. The live dashboard in Chrome still reports **Mac monitoring not verified** at this checkpoint. Confirm real source health and queue delivery after Start, before the locked-iPhone completion test. Physical iPhone enrollment and delivery remain unverified. Preserve the previous app, snapshot, and restore-verification branch until the pilot is accepted.

The owner subsequently reported that the toggle button has no visible text, although pressing it turns Status Watchr on and off. This is an unresolved native UI defect, not a verified cause of the missing heartbeat. An inspection attempt after that report also timed out. A screenshot of the open menu, with the token concealed, was requested to reproduce the exact label defect before making a speculative styling change.

## Build 1014: delivery recovery prepared

The owner's screenshot confirmed active local scanning, a blank toggle label, and rejected deliveries. A read-only replay of the disk queue through the hosted validator found 11 empty titles. All 11 matched local inventory rows with a null name and empty title. The inventory's null-only fallback preserved empty strings, while the server requires a nonblank title. The drainer stopped on the first rejection, blocking later events. A minimal fixture failed with `Invalid title`; the same fixture with a safe placeholder passed.

- Added shared title preparation that prefers nonblank name/title metadata, uses `Untitled task` otherwise, and respects the server's 500 UTF-16-unit limit without splitting graphemes. No prompt-derived fallback.
- Existing queued events are prepared in memory before delivery. IDs, source timestamps, and original files are preserved until acknowledgment. A newer heartbeat replacing a file while a request is in flight is not deleted.
- Rejected/unreadable events remain on disk while other events in the batch continue. Authentication, throttling, and server failures stop the batch and back off. The existing seven-day expiry is unchanged.
- Delivery errors now distinguish HTTP categories without printing response bodies or credentials. The hosted 400 response can mean validation or storage failure, so the UI does not falsely attribute it to credentials.
- The unnamed-inventory regression failed before the fix and passed afterward. Final native run discovered 39 tests: 38 passed, one live-source opt-in check skipped. Web typecheck, all 67 web tests, build, and diff whitespace checks passed.
- A read-only Swift-to-TypeScript contract check prepared all 38 queued events at that checkpoint, and all 38 passed the actual server validator. No events were transmitted and no queue files were changed by that check. This is not proof of hosted database acceptance or queue drainage.
- The toggle now uses explicit primary-colored text with a minimum label width and the standard bordered style used by the other controls. Isolated native renders show both Start and Stop. The original label failure was not reliably reproduced outside the menu-bar environment; installed-menu verification remains required. Error text now wraps rather than truncates. Impeccable's mechanical check found no findings for the changed view.
- Prepared locally signed 0.1.14 / build 1014 under `build/private-pilot-1014/Status Watchr.app`; deep strict signature verification passed. This is not notarization. Installed build 1013 remains running pending the owner's quit/replacement confirmation. No hosted deployment, public native release, credential change, queue deletion, Git push, or PR was performed for this repair.

Next: confirm app exit, preserve build 1013, install/reopen build 1014, inspect the actual toggle label, start monitoring, and verify live queue drainage before phone testing.

## Build 1014 installed: September 21

After the owner confirmed quitting, a process check verified Status Watchr had exited. Build 1013 was preserved intact at ignored `build/installed-1013-backup/Status Watchr.app`. Build 1014 was installed at `/Applications/Status Watchr.app`, deep strict signature verification passed, and the executable matched staged SHA-256 `399cf85337f8c9d315b95576f4bbcb34334f6b72c15c0ac0ecf3d514652986e5`. Version 0.1.14 / build 1014 was verified and the app reopened; its running process was confirmed.

The queue contained 39 files at the post-install baseline. No queue or credential files were changed by installation. The owner has been asked to click Start and confirm the actual menu label. Live drainage and phone delivery remain pending; a stale dashboard heartbeat is not proof the new observer has started. Both earlier installed bundles remain recoverable. No hosted deployment or public native release accompanied this replacement.

## Live delivery verified after Start

The owner confirmed monitoring was on. Read-only queue counts at 07:03:51 and 07:04:53 UTC on September 21 both returned zero, down from the 39-file post-install baseline. No manual queue removal or replay to production was performed. The owner's Chrome dashboard showed newly received `Untitled task` records, a fresh run-history health indicator, and this Status Watchr conversation advancing to In progress with a newly received start event. Its timeline includes recovered completion and start events. This verifies installed Mac-to-hosted delivery and recovery, not phone notification presentation.

The dashboard still reports attention hooks need review. Native button-label visibility has not been explicitly confirmed by the owner. Next acceptance gate: enroll the actual iPhone Home Screen app, verify its generic test notification, then watch a conversation and verify a real completion on the locked phone. No desktop subscription or watch preference was enabled during browser inspection.
