# App Switchr integration

Source behavior. Hosted and installed versions must be verified separately during rollout.

## Behavior

The shared switch controls cloud work. A confirmed Off also suspends the Mac's automatic local observation; an unavailable permission preserves local observation so a transient control outage does not silently discard activity. No new credentials are stored in the browser or native client.

- On: fresh permission enables automatic dashboard/settings refresh, Mac uploads and health reports, and scheduled notification delivery/retention. An Off-to-On observation restarts the Mac's local scan and Codex app-server connection, scans immediately, attempts queued delivery, and refreshes the visible dashboard.
- Off: Mac uploads and health reports stop; automatic local database scans, hook processing, and the Codex app-server child process pause; dashboard and notification-settings polling pause. The scheduled notification/retention function returns before opening Neon. The menu-bar app stays open to check permission. Manual Mac refresh can still inspect local state.
- Pending: missing, invalid, expired, or unavailable configured permission pauses automatic cloud work but resumes local observation. Wall-clock and monotonic expiry prevent a sleeping client or clock rollback from extending its lease.
- Manual dashboard refresh, opening notification settings, changing watches, and explicitly requested notification tests remain available. The Mac refresh button refreshes local observations; it does not bypass the cloud gate.
- Control reads happen every 30 seconds while monitoring is running or the browser is visible. Same-Mac App Switchr notifications invalidate the native lease and request fresh authenticated permission. Maximum accepted lease is 60 seconds. Already-started requests can finish.

The native client uses its existing ingest token to read authenticated `/api/work-state`. The web client uses its existing owner cookie. This endpoint never queries Neon. Automatic event/health uploads are also checked server-side before Neon access; paused uploads receive 503, not an acknowledgment, so the native outbox retains them.

## Boundaries

Control reads and scheduled-function invocations still use Netlify resources. Savings are not measured. Existing retention limits remain: at most 5,000 queued files and seven-day local expiry. Events recovered from a confirmed Off interval update the timeline with `notificationEligible: false`, so they do not create catch-up phone alerts. Events already queued before Off retain their existing notification eligibility. Notification maintenance resumes on its next minute tick. Source capture still depends on the Mac being awake and Status Watchr monitoring being started.

Older native collectors retain/retry rejected uploads but do not suppress the request itself; update the Mac client for full idle-request reduction. A backend outage or deployment missing `/api/work-state` pauses the new native client's delivery until it recovers. Local events stay queued within existing limits. Deploy backend support for `notificationEligible` before distributing the new native observer, or recovered events carrying that field will be rejected.

## Rollout after authorization

1. Deploy the backend and dashboard first. With both optional variables absent, the service returns an active permission to preserve existing operation.
2. Set production-only `APP_SWITCHR_URL=https://kylbutlr-switchr.netlify.app/api/work-state` and secret `APP_SWITCHR_READER_TOKEN` to the existing service reader credential. Configure them together. Never use a VITE prefix or the owner credential. Redeploy to apply them. Partial configuration fails closed.
3. Build a monotonically newer signed Mac release following the repository release process. Verify signature, update feed, and rollback artifact before authorized installation. Do not replace a running app.
4. Verify real On → Off → On with the updated native app and phone dashboard. Confirm no automatic local scans or queue growth while Off, no automatic Neon queries, an immediate scan and queued delivery on On, and no phone alerts for runs completed during Off. Inspect Pending during a temporary service failure without losing queued events.

No migration or new database is required. Turning the integration off means removing both server variables and redeploying; keep the existing local outbox.

## Verification

Automated coverage checks authentication before database access, standby/unavailable/expired permissions, scheduled-maintenance gating, browser activation refresh without repeated transition refreshes, native lease expiry across sleep/clock changes, pausing local scans in confirmed Off, preserving then delivering the same queued event once, and suppressing notifications for recovered Off events. Native UI, real cross-app notification timing, and physical phone notification delivery remain rollout acceptance checks.
