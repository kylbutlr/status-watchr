# Temporary all-conversation alerts and mobile navigation

## Additional duration choices (local source, not deployed)

The dropdown now also offers **Until midnight** and **Always on**. Midnight means the next local calendar midnight on the device activating the setting, including daylight-saving transitions. The browser submits a fixed UTC deadline, so later timezone changes do not move it; an invalid/past deadline or one over 26 hours away is rejected. An incorrect device clock/timezone may produce an incorrect deadline or rejection.

Always on persists until explicitly disabled through **Turn Off**, including across page closure/reload. It covers current and newly observed conversations, including individually muted conversations, but does not alter individual watches. It can be noisy if forgotten. Existing App Switchr background-work permissions, device revocation, generic payloads, freshness checks, and bounded retry/retention rules remain in force. Already-dispatched pushes cannot be recalled.

No schema migration is required: the existing timestamp stores PostgreSQL `infinity` for Always on. The API normalizes this to `allAlways: true` and `allUntil: null`; it never sends infinity into JavaScript date parsing. Push TTL stays capped at one hour. Publish matching frontend/API together and refresh older open clients before using Always on, since older clients do not understand this mode. Before rolling back to the older frontend/API, turn global alerts off using the current UI. This source change does not authorize a deployment or production preference change.

Automated coverage includes enable/reload/cancel and failed cancellation, midnight selection, bounded deadline validation, permanent-mode dispatch TTL, pre-activation exclusion, and individual-watch preservation. Real phone presentation remains unverified for these new modes.

Local verification: all 91 tests, TypeScript checks, and production build passed. Calendar-midnight tests also passed under `TZ=America/Los_Angeles`, including spring/fall transition dates. Chrome inspection of the actual component in an isolated, in-memory fixture verified Always on and Turn Off at desktop and 390 × 844, cancellation back to Off, and Until midnight activation showing 12:00 AM without clipping. The fixture sent no pushes or production writes. Impeccable's scoped copy guidance kept the incumbent layout and explicit off action; its detector returned no findings.

Status: deployed to the private pilot on 2026-09-21, including production migration 005. All-conversation alerts were left off after the live settings smoke test. Actual iPhone receipt for this new mode remains pending.

## Owner workflow

At the top of the dashboard, choose 15 minutes, 1 hour (default), or 4 hours and select **Notify for all**. Current and newly observed conversations are covered for completion, failure, and supported attention signals. This is not an alert for every status update. Question detection remains incomplete.

The control shows the stop time and allows early cancellation. Expiry uses server time and works with the dashboard closed. Alerts go to all enrolled devices, including an already enrolled phone when activated from the Mac. At least one enrolled device and configured push are required by the UI. Individual watches are preserved; muted conversations are temporarily covered, and individual watches resume their normal scope when the window ends.

On screens up to 850 CSS pixels wide, tapping a conversation replaces the list with its details. **Back to conversations** restores list position and focus. Filters and loaded history remain intact. Wider screens retain side-by-side list and detail. Device settings are accessible at the top without opening a conversation.

## Safety and data

- New preference stores only owner window start/end timestamps. Cancellation clears them; expiry leaves the last pair until overwritten.
- Delivery jobs also store the event's source timestamp, under the existing seven-day job retention.
- Eligibility is checked both during ingestion and immediately before push dispatch. Turning off global alerts preserves jobs still covered by individual watches. Turning off an individual watch preserves temporary coverage.
- The same delivery identity is used for overlapping global and individual watches. Recent events predating activation and events older than ten minutes do not become catch-up alerts. Newly enrolled devices do not receive pre-enrollment events.
- A new window after expiry does not revive old jobs. Renewal of an active window preserves its original start time.
- Global-only pushes use a provider TTL bounded by the remaining window. Already dispatched/in-flight notifications cannot be recalled, and provider presentation timing is not guaranteed.
- Existing owner-session authentication, same-origin JSON checks, push endpoint allowlist, generic lock-screen copy, and device revocation remain in force. No new prompt, source, terminal, or diff collection; no remote control.

## Verification

Embedded PostgreSQL tests cover defaults, supported/invalid durations, authentication, cross-origin rejection, new conversations, overlapping watch deduplication, pre-window history, cancellation with individual-watch preservation, expiry without browser reconnection, reactivation, mute interaction, and bounded provider TTL. Existing tests still cover lifecycle, attention identity, privacy, device revocation, retries, and retention. Push transport is mocked and no production database is used.

React DOM tests cover on/off, one-hour default, visible automatic expiry, failed save, unchanged individual watches, disabled demo controls, and mobile detail opening with focus/scroll restoration. Layout tests check narrow-screen list/detail exclusivity. Build checks both TypeScript projects.

All 78 tests across 13 files and the production build passed. Chrome visual inspection covered the final local demo at 390 × 844 and 1104 × 844 CSS pixels: top-level control, lower conversation selection, immediate detail view, Back/focus restoration, Finished filter, device-settings disclosure, and retained desktop two-pane view. No horizontal clipping was visible in those states. Phone emulation was briefly paused while Chrome was in use, then resumed with permission. Physical iPhone verification remains pending. The local preview disables notification mutations; it does not prove real push delivery for this new mode or rendered on/error states, which have React DOM test coverage only.

The owner previously confirmed the existing phone test and watched-completion notification worked in this conversation. That is owner-reported evidence for the earlier deployment, not verification of the new temporary mode.

Impeccable's scoped adaptation guidance informed the master/detail behavior, 44-pixel controls, and preserved App Stylr treatment. Its detector reported incumbent font/side-accent conventions; no broad visual redesign was attempted.

## Verified private rollout, 2026-09-21

- Owner approved the additive database update and private web deployment. No Git push, PR, credential changes, or native replacement/release was performed.
- Created Neon snapshot `production at 2026-09-21 14:36:02 UTC (manual)`, with no expiry, before migration. The earlier snapshot and its restore-verification branch remain available. The fresh snapshot itself was not restore-tested.
- Applied migration 005 to production branch `br-misty-sky-akqqkw5q`, database `neondb`; the SQL editor confirmed COMMIT. Follow-up checks preserved one watch and one enrolled device, found zero delivery jobs missing source timestamps, and confirmed temporary alerts off and an unwatched test identifier ineligible.
- Published source `5d225d0` as [Netlify deployment 6ab141e35045063f171ff6e2](https://app.netlify.com/projects/statuswatchr/deploys/6ab141e35045063f171ff6e2). Netlify lists both API and scheduled notification-retry functions. This verifies deployment/schedule registration, not a successful scheduled invocation. The prior deployment `6ab0cd842d703b0949f78657` is the rollback target.
- Re-ran typecheck, all 78 tests across 13 files, and production build successfully. Live HTML references the matching JS/CSS assets. Anonymous sessions, notification settings, and collector requests return 401; health returns 200.
- In authenticated Chrome, enabled 15-minute coverage, observed the saved On state and stop time, then cancelled and observed Off. No individual watch was changed. At 390 × 844, the control had no visible clipping; selecting a conversation immediately opened details, and Back returned to the list. Viewport override was reset. Browser warning/error log inspection returned no entries.
- Native appcast matches the existing local feed byte-for-byte, SHA-256 `a8a718e805224bf701ccbe606624d145c600d1e92e10f7b1d8bda5764d880200`. No Mac reinstall is needed.

Remaining verification: locked-iPhone receipt for unwatched/new conversations, cancellation and expiry with the page closed, preservation of individually watched delivery, long-title layout on the physical phone, and scheduled invocation/server error-log evidence. Existing attention-hook readiness still needs review. Do not interpret browser settings success as proof of push presentation.

## Rollout procedure and remaining phone check

1. Chrome narrow-screen rendered QA is complete for the demo states above. Verify enabled/on/error states and the actual Home Screen app on iPhone after deployment; very long production titles remain a device-check item.
2. Obtain explicit approval for a production database update and private web deployment. Verify current production deployment and backup/restore coverage before making changes. Use the owner's Chrome for Neon/Netlify console work.
3. Apply [005_temporary_notifications.sql](../database/migrations/005_temporary_notifications.sql) after 004. It is additive and repeatable. Existing code can continue using the old tables; the new delivery timestamp has a default.
4. Deploy the matching web and API/retry-function bundle together. Do not deploy the new functions before migration 005. No Mac companion replacement, signing, VAPID rotation, native release, push, or PR is part of this step.
5. Verify authenticated settings load with all alerts off and original watches/devices intact. Enable 15 minutes; complete an unwatched conversation and a newly observed conversation. Confirm generic alerts on the locked phone, then cancel and check no further unwatched alerts. Confirm a pre-existing individual watch still alerts. Separately let a window expire with the page closed.
6. Check logs using generic error counts only, never subscription credentials, raw event content, or database URLs.

Rollback: restore the previously verified web/functions deployment and retain the additive schema. The old code ignores global coverage and keeps individual watches. Pending temporary-only jobs fail the old dispatcher's watch check and are removed; jobs for individually watched conversations may still send. Already sent pushes cannot be recalled. Do not drop tables/functions or restore the entire database as an automatic rollback.
