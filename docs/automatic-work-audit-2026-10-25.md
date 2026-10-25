# Automatic work and Neon audit, October 25, 2026

Status: focused draft patch, not deployed. Full validation is deferred at the owner's request while an existing Worldrawn preview remains running. No monitoring, notification, production configuration, compute setting, snapshot, or existing branch was changed.

## Findings and current deployment

- Refreshed Git refs before creating `kylebutler/idle-work-audit` without upstream tracking, from `origin/main` at `f6ed2477dd8f98db192767036e589d6592e6aece`. GitHub reported only the remote `main` branch and no open PRs at audit start. Reviewed the local branches/worktrees and earlier polling and retry work, including [the October 21 optimization merge](https://github.com/kylbutlr/status-watchr/commit/bb2c47d42bae53d89287719aa3bafb01a4df70eb). Older local branches do not establish running jobs.
- Netlify's current published production deploy is [6adb5d738bb4fa76caba84dc](https://app.netlify.com/projects/statuswatchr/deploys/6adb5d738bb4fa76caba84dc), published October 23 at 13:13:37 UTC. It is a manual deploy with no recorded commit ref. The previous Git-backed production deploy records `3074f794e10e4f35ad25d3ad2e538a3754e1b778`.
- The live function inventory contains exactly `api`, `notification-retry` (`* * * * *`), and `retention-scheduled` (`17 */6 * * *`), all Node.js 24. The accessible Netlify site inventory was checked for names/repository bindings matching Status Watchr; no duplicate matching site was found. This does not inventory other hosting accounts or external cron services.
- Public production JavaScript and CSS exactly match the existing local build artifacts: `index-e3iOfvGk.js`, 237,603 bytes, SHA-256 `87942ab163a3ca1de8ed42855bb903ab8ecfdc224c90a70c8a28f85d67966541`; `index-BW_micE2.css`, 33,810 bytes, SHA-256 `0b6441711b6a44e22698685a48dc10848552c3f1cb788a5229ff92fd65383bb4`. These are static asset sizes, not activity response sizes or transferred gzip bytes. Exact deployed backend bundle/source byte parity was not established.
- Strongly consistent production Blobs reads found retry `initialized: true`, zero `wakes/` receipts, and no `watchr-collector-health-v1/mac` record. There is no current external wake backlog or missing initialization marker. An empty health record does not prove that the installed observer is stopped or broken.
- Read-only [Neon branch inventory](https://console.neon.tech/app/projects/restless-thunder-91056628/branches) shows production and the retained snapshot branch, both idle. [Production compute](https://console.neon.tech/app/projects/restless-thunder-91056628/branches/br-misty-sky-akqqkw5q/computes) is `ep-royal-surf-akihqxa1`, suspended, with a 0.25 to 8 CU autoscaling range and scale to zero enabled after five minutes of inactivity. The Console reports last activity/suspension four days ago. The settings dialog was canceled without edits. No SQL editor or database connection was opened.
- The shared App Switchr Blob has revision 101, desired `active`, and `activeUntil: 2026-10-22T01:00:00Z`. The verified Switchr snapshot logic therefore resolves it to Standby at audit time. Desired active is not an unexpired permission lease. This read verifies stored state, not successful authentication by every deployed consumer. Netlify marks the database URL and Switchr reader token as secrets; management-API values could not verify the live connection target or reader authentication. Failed requests using those returned values are not evidence of broken production credentials.
- One native Status Watchr process is present (PID 94644). Its existence does not prove monitoring is started. No local Status Watchr preview/collector/server was started by this audit. The standalone ten-second retry loop uses embedded PGlite, not Neon, and is not a separate Netlify process. No duplicate hosted loop was identified in the reviewed configuration. Other machines remain outside this inventory.

## Actual database access paths

The table describes current source paths, supported by deployment inventory and the production observations above. It does not claim a production SQL trace.

| Trigger | Work before PostgreSQL | Database access when applicable | Source |
| --- | --- | --- | --- |
| Minute notification tick | Database configuration and Switchr gate; external initialization marker and wake receipts | Missing initialization queries pending deliveries and persists recovery receipts before marking complete. After initialization, empty/future-only receipts do not obtain SQL. A due receipt drains eligible jobs and reconciles its next deadline. | [retry handler](../netlify/functions/notification-retry.mts), [wake recovery](../netlify/functions/lib/notification-wakes.ts#L47) |
| Due delivery | Durable receipt exists; database factory is lazy | Atomic `UPDATE` leases at most ten eligible rows using `FOR UPDATE SKIP LOCKED`; completion/actionability, authorization, device, and expiry checks precede sending. Acknowledgement, retry deadline, or device revocation then writes SQL. | [delivery code](../netlify/functions/lib/notifications.ts#L105) |
| Notification-producing ingest | Authentication, Switchr gate, normalized input; per-invocation durable wake before notification transaction | Review-exclusion read, ingestion transaction, immediate eligible delivery, and wake settlement. A killed/post-commit request retains recovery intent; a failed send does not reject an accepted event. | [ingestion](../netlify/functions/api.mts#L367) |
| Native observation | Local inventory/SQLite/hook work; deduplication; unchanged heartbeat floor of two minutes; permission before outbox upload | Genuine lifecycle events and eligible heartbeat uploads reach `/events` and perform SQL. Every local five-second scan is not an upload or SQL query. Health uploads have a one-minute floor and use Blobs. | [native scans](../apps/macos/Sources/Services/ConnectorController.swift#L620), [outbox and health](../apps/macos/Sources/Services/ConnectorController.swift#L1272) |
| Legacy command-line collector | Own local scan state and event deduplication; unchanged scan uploads have a two-minute floor | Accepted event uploads use the same ingestion SQL path. This compatibility collector does not have all native standby/durability controls. Server rejection still gates uploads while Off. | [collector](../collector/status-watchr.mjs#L244), [server gate](../netlify/functions/api.mts#L104) |
| Dashboard snapshot | Visible, online, valid work permission, sequential scheduler, adaptive unchanged/failure delays | Every accepted conditional GET still runs one revision query. Equal revision returns bodyless `304`, skipping the larger snapshot query. A changed revision runs the snapshot query too. Snapshot pages contain ten sessions and their latest events. Two-hour stale crossings change the revision. | [API revision and snapshot](../netlify/functions/api.mts#L154), [client scheduler](../src/App.tsx#L340), [backoff](../src/polling.ts) |
| Selected timeline | Visible/online guard; selection or changed snapshot revision | One query returns at most 100 events. It is not downloaded with every unchanged poll. | [timeline API](../netlify/functions/api.mts#L289), [timeline client](../src/App.tsx#L296) |
| Notification settings | Ten-minute timer, focus/pageshow/visibility, permission/online/in-flight guards | Three SELECTs: watches/latest metadata, devices, active all-conversation preference. Mutations immediately read settings back; temporary expiry also has a local timer. | [settings client](../src/Notifications.tsx#L37), [settings API](../netlify/functions/lib/notification-api.ts#L13) |
| Health, auth status, work state | Configuration/authentication, Switchr HTTP/Blobs, or health Blobs | No application PostgreSQL query on `/health`, `/auth/session`, `/work-state`, or collector-health reads/writes. Constructing `neon()` elsewhere is not itself an executed query. | [early API routes](../netlify/functions/api.mts#L97), [health storage](../netlify/functions/lib/collector-health.ts) |
| Six-hour hosted retention | Switchr gate | Six DELETE statements retain the existing seven-day delivery/question, 30-day activity, and guarded 37-day relationship/exclusion rules. No deletion query is run on idle minute retry ticks. | [retention](../netlify/functions/retention-scheduled.mts#L4) |
| Standalone server | Process lock, local database, non-overlapping ten-second retry loop | Receipts and SQL use the local filesystem and PGlite; six-hour retention is local. This loop does not add Neon queries to the hosted deployment. | [server](../server/start.ts#L24), [local SQL adapter](../server/database.ts), [runtime storage](../netlify/functions/lib/runtime-store.ts) |

The push service worker has only push and notification-click handlers, with no periodic polling or background sync ([source](../public/sw.js)). Independent visible clients each have their own reads. A `304` saves payload and the snapshot query, but does not remove the revision query or provide cross-client query sharing. No shared cache, leader election, or longer polling interval is introduced by this patch.

## Consumption and attribution

The owner supplied these Consumption V2 measurements; this audit did not independently rerun that API:

| UTC period | CU-hours |
| --- | ---: |
| September 17 through 30 | 36.448 |
| October 1 through 24 | 43.377 |
| October 19 | approximately 2.21 |
| October 20 | approximately 2.43 |
| October 22 through 24 combined | 0.023 |

Netlify independently confirms [the October 21 compute-optimization deployment](https://app.netlify.com/projects/statuswatchr/deploys/6ad8e8f2ec0c9c934a176774), published 16:32:06 UTC. Later deployments retained the three-function inventory. That timing, the present initialized/empty retry store, the expired Switchr cutoff, and the suspended compute are consistent with low recent activity. They do not isolate the optimization's causal savings from Standby, closed dashboards, observer state, or workload changes. There is no historical client/request/SQL trace in this audit to attribute the October 19 and 20 peaks.

Keep these units separate:

- Scheduled invocation: a Netlify function execution. The minute expression implies up to 1,440 scheduled opportunities per full day, not 1,440 PostgreSQL queries. [Netlify schedules run automatically only for published deploys](https://docs.netlify.com/build/functions/scheduled-functions/).
- SQL query: an actual driver execution. Initialized no-work retry ticks, health checks, and Switchr control reads avoid this boundary. An unchanged dashboard request does not.
- Compute wake: a connection/query can activate a suspended Neon compute. Queries against an already active compute are not separate cold wakes. More activity can extend the time before suspension. [Neon compute lifecycle](https://neon.com/docs/introduction/compute-lifecycle).
- CU-hours: compute capacity integrated over running time, including the inactivity tail, with actual autoscaling and plan accounting. Request counts and payload bytes cannot be converted directly to billed usage. [Neon consumption metrics](https://neon.com/docs/guides/consumption-metrics).

No measured production CU-hour reduction, dollar saving, or payload-byte saving is claimed for this patch.

## Focused patch and verification

1. Coalesce overlapping automatic snapshot reads, including scheduler restarts during permission/cadence changes. Previously, returning focus, visibility, and online events could abort/restart requests whose server SQL might still execute. A different filter/auth session still cancels obsolete work; explicit refresh remains available as before.
2. Bound snapshot/health requests at 15 seconds, so coalescing cannot leave an unresponsive read blocking recovery indefinitely. Timeout enters the existing failure/backoff path. This is a failed-request bound, not a longer refresh cadence; normal successful requests keep their existing timing.
3. Skip offline Switchr control requests, while retaining the online listener. On recovery of an expired permission lease, wake consumers even if server state/revision is unchanged. Ordinary valid lease renewals do not reset dashboard backoff.

All notification production/delivery/retry, retention, native collector, and selected polling-interval code remains unchanged.

Measured locally with fake network responses and one Vitest worker:

| Scenario | Before | After |
| --- | --- | --- |
| Four overlapping return triggers during a stalled read | Four snapshot requests, plus the initial page request | One snapshot request, plus the initial page request |
| Visible but offline control checks in the regression window | Three additional attempted control requests | Zero additional attempted control requests |
| Stalled snapshot | No bounded failure in the 15-second fixture window | Failure shown at 15 seconds; a later focus refreshes successfully |
| Hidden tab returns after lease expiry, same active server revision | Consumer did not refresh immediately after renewed permission in the regression | Refreshes after permission recovery |

The initial regression run failed on the duplicate-read, timeout, and offline-control cases. A separate copy of baseline source reproduced the same-revision visibility-return failure as well: one total snapshot request where the return should have produced a second. The final focused run passed **48 tests in seven files in 7.56 seconds**, covering the above, unchanged backoff through ten minutes, hidden/offline/standby and resume, independent clients, immediate manual refresh, filter cancellation/unmount, notification-settings actions/expiry, no-work and future retry ticks, due empty-job reconciliation, failed bootstrap retry, health without SQL, and fail-closed standby gates. Due receipt reconciliation used mocked SQL, not an actual push delivery. Client request reductions are not measured production query or compute reductions.

```sh
export PATH=/Users/kylebutler/.nvm/versions/node/v24.18.0/bin:$PATH
npx vitest run tests/dashboard-request-lifecycle.test.tsx tests/dashboard-compute-budget.test.tsx tests/polling.test.ts tests/compute-budget.test.ts tests/work-switch.test.ts tests/notification-ui.test.tsx tests/notifications.test.ts --maxWorkers=1
```

Pending, explicitly deferred while the owner's Worldrawn preview runs: `npm run typecheck`, complete `npm test` including embedded PostgreSQL delivery/retention tests, and `npm run build`. Rendered browser QA and physical phone delivery were not performed. Existing embedded integration cases exercise interrupted-request recovery, independent producer receipts, retry failures, revocation, expiry, and retention, but were not rerun here. Real concurrent delivery and provider/phone behavior remain unverified by this pass. This is not a full QA or ready-to-merge verdict.

## Deployment and rollback

- Review as a draft. The commit and PR title use `[skip netlify]` to prevent branch/PR deployment; [Netlify documents this skip mechanism](https://docs.netlify.com/deploy/manage-deploys/manage-deploys-overview/). No workflow dispatch, merge, release, or deploy is authorized by this audit.
- When the game preview is stopped, run the deferred checks serially with Node.js 24. Complete a bounded rendered check against disposable local data, including focus/visibility/reconnect, filter changes, timeout recovery, and two clients. A normal notification test remains a separate, explicitly authorized production/device action.
- After separate deployment approval, use the normal reviewed release flow. This patch needs updated web assets only, no migration, native release, secret change, compute setting change, or wake-store reset. If deploying a complete hosted bundle, preserve all three functions and the existing schedules, plus signed update artifacts. Do not use the native release workflow merely to publish these frontend changes, since it also publishes a native release and production deployment.
- Verify the published asset revision, the same function inventory/schedules, and controlled return-event request counts. During naturally authorized monitoring, verify On/Off/resume and actual retry/phone behavior. Compare branch and project Consumption V2 CU-hours after 24 hours and seven days under comparable active/quiet workloads. Do not turn monitoring On solely to manufacture a saving measurement.
- Before an authorized release, record the then-current published deploy as the rollback target. At this audit's checkpoint that target is [6adb5d738bb4fa76caba84dc](https://app.netlify.com/projects/statuswatchr/deploys/6adb5d738bb4fa76caba84dc). If regression appears, separately authorize republishing that previous deploy, or revert this patch in a new reviewed commit and deploy through the normal flow. Existing clients need to reload the restored web assets. There is no database downgrade, deletion, reset, or receipt reinitialization in this rollback.

The task-owned browser tab was closed. The audit started no server/watcher, left the owner's Worldrawn preview untouched, and stopped all its focused test processes. Full validation is the next gate before merge/deployment consideration.
