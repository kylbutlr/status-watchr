# Recurring conversation title repair

## Reproduction on October 11, 2026

The production dashboard displayed five visible `Untitled task` headings. A read-only local metadata check found recent subagents with blank `name` and `title`, but populated `source.subagent.thread_spawn.parent_thread_id` and `agent_path`. Parent conversations had authored names. The installed companion was 0.1.39. Its existing inventory only considered `name` and `title`.

The native SQLite/controller regression initially returned `Untitled task` instead of `Project task: performance review`. The embedded PostgreSQL regression also demonstrated that placeholder ingestion replaced a known title. A separate backfill regression initially received HTTP 400 for title repair reports.

## Fix

- Prefer authored conversation names and titles. For an otherwise unnamed subagent, join its parent metadata and use the subtask path's final label. Fall back to the nickname, then short subagent identity. No prompts, previews, message bodies or rollout contents are read to construct titles.
- Check available SQLite columns and safely parse JSON source metadata. Older projections and malformed JSON remain supported. Guardian filtering and the 100-conversation lifecycle discovery limit stay in place.
- Deduplicate lifecycle events by identity and display metadata. When a finished run's title changes, reuse the existing event ID and source timestamp and mark the metadata refresh ineligible for notifications. Stable scans remain deduplicated.
- Preserve known hosted titles across placeholder replay and titleless new turns. No migration is required.
- Repair old unnamed subagents through `local/threads/titles`, authenticated with the existing ingest token. The native title-only query includes archived subtasks outside lifecycle discovery. Deterministic batches use at most 100 titles and at most 12 KiB of encoded title data. The existing outbox handles offline delivery. Hosted repair changes only placeholder titles on terminal rows retained within 30 days, skips known names and classified reviews, and creates no run, timeline event or notification job.

## Validation and rollout

Native tests cover SQLite discovery, parent metadata, archived parents and subtasks, missing projection columns, malformed JSON, missing parent/path, completed-run renaming, unchanged event identity/time, suppressed repair alerts, JSON size limits and offline delivery. The PostgreSQL tests exercise real ingestion, feed and watch queries, title repair, placeholder replay, authentication, validation and unchanged lifecycle/notification history.

The opt-in live native reader resolved an affected local record to `KRMD: 500461 (2): performance review`. This is local source evidence, not an installed-app or production repair.

Final source validation passed: typecheck, production build, all 126 web tests, and 96 native tests. Four other opt-in native checks were skipped; the affected live title check ran and passed. A regression explicitly puts a subagent outside the 100-conversation discovery window and confirms title repair still finds it. No temporary instrumentation or preview process was left running.

Local validation commands:

```sh
cd /Users/kylebutler/Documents/sites/status-watchr
npm run typecheck
npm test -- --maxWorkers=1
npm run build
cd /Users/kylebutler/Documents/sites/status-watchr/apps/macos
swift test --jobs 2
```

Publication remains approval-gated by the repository contract. Deploy the web ingestion changes before installing the new native companion. Then enable monitoring, allow its inventory scan and outbox to finish, and verify the previously untitled rows in the authenticated [production dashboard](https://statuswatchr.netlify.app/). Check current and older finished subtasks and a subsequent run. Confirm that title correction adds no completion notifications. Normal unnamed top-level conversations can still display `Untitled task` when their source has no name or title. Records absent from the local source cannot be reconstructed.

No production database writes, deployment, native release or installation were performed while preparing this fix. No preview server is required for these source and ingestion checks.
