# Personal monitor readiness

Date: 2026-09-20, America/Los_Angeles.

Update, 2026-09-28: a local macOS candidate suppresses attention from `PermissionRequest` hooks and generic waiting flags because these do not distinguish Codex Auto-review from a human prompt. The historical checkpoint below describes the earlier implementation, not the current candidate. Manual approval alerts may be missed until a reliable human-waiting signal is available. The candidate is not installed or published.

## Verdict

Update, 2026-09-21: the owner subsequently confirmed in this task that the existing iPhone test notification and watched-completion notification worked. This is owner-reported phone evidence, not an independent device recording or proof of all attention states. The new temporary all-conversation alerts and mobile master/detail navigation are now deployed with migration 005. Authenticated Chrome verified saving/cancelling temporary coverage and immediate mobile detail navigation. Coverage was left off; physical iPhone receipt for the new mode remains pending. See [the update's verification and rollout checklist](temporary-alerts.md). The earlier checkpoint below describes the evidence available at the prior native-install handoff.

**Private web pilot and installed repair build 0.1.14 now deliver live Mac activity.** After the owner started monitoring, the queue drained from its 39-file baseline to zero, confirmed twice. Chrome shows recovered unnamed-task events and this conversation's fresh In progress event. Build 1013 is preserved. Actual iPhone delivery, installed-menu label visibility, and attention-hook coverage remain unverified. Database backup, restore verification, and migration are complete. This is not yet an end-to-end verified phone notification deployment. See the [verified rollout record](pilot-rollout-2026-09-20.md).

Work is isolated on `kylebutler/status-watchr-personal-monitor`, based on fetched `origin/main` at `c67967b`, re-fetched and unchanged during rollout preflight. The primary checkout and the earlier public-foundation worktree were preserved. The approved database backup, migration, private web deployment, and native replacement/reopen have been completed. Native computer control timed out again after installation; the owner has been asked to click Start in the menu-bar app. No push, PR, hook trust change, or public native release was performed. Production-only VAPID configuration is active in the new deployment; browser notification settings loaded successfully, but no physical push delivery has been proven.

## Rollout checkpoint

- Verified existing target: [Status Watchr](https://statuswatchr.netlify.app), Netlify site `eff4eb8f-14e1-4346-a930-0d65eeb5e8c4`. Published deployment is now `6ab0cd842d703b0949f78657`, from local source commit `0149aaf`. The preceding deploy `6aaed654812cd80009ba6245` is the web rollback reference.
- The live signed appcast exactly matched the source appcast, with latest version 0.1.12 / build 1012. No feed or archive was published or modified.
- Installed the prepared `build/private-pilot-1013/Status Watchr.app`, version 0.1.13 / build 1013, signed with the existing Status Watchr Local Code Signing identity. Deep strict signature verification passed for both staged and installed bundles with access to the system trust store. Both executable SHA-256 values match `2742b9579ff6bd334c9f4117fdce53c9e488f3ec0c1ac2abefe2def9f6880a22`. This is not Developer ID signing or notarization. The old 0.1.12 bundle is preserved intact under ignored `build/installed-1012-backup/Status Watchr.app`. The replacement process is running, but observer startup needs the Start button.
- Fixed a macOS Bash `set -u` / empty-array failure in the packaging script and added a regression test. The native README now reflects the actual observer and Web Push design.
- Configured `WATCHR_VAPID_PUBLIC_KEY`, `WATCHR_VAPID_PRIVATE_KEY`, and `WATCHR_VAPID_SUBJECT` for production only, all marked secret. The subject is the existing private site's HTTPS URL. No key values were printed or written to source. The account reports `env_var_scopes.included: false`; the initially requested function-only scope was rejected with HTTP 403 and created no keys. The successful configuration uses the same `builds`, `functions`, and `runtime` scopes as the existing secrets. No billing or plan change was made, and these variables are not exposed through Vite client prefixes.
- Database access is resolved through the owner's signed-in Chrome session. The production snapshot at 2026-09-21 06:13:23 UTC was restored into an isolated verification branch. Both branches had 418 sessions and 595 events. Migration 004 committed on the original production branch; follow-up queries confirmed all four new tables and the delivery index, unchanged activity counts, and no expired activity records at that checkpoint. The snapshot and verification branch remain available with no automatic expiry. The newly deployed scheduled function now activates retention; actual expired-row deletion has not been tested against production records.
- The Intel backup-tool installer was stopped with explicit approval. Native ARM64 PostgreSQL client tools 18.6 are installed and executable. The actual backup/restore proof used Neon snapshots, not a local dump; no local database credential was extracted from Chrome or Netlify.

## Requirement coverage

| Agreed requirement | Implementation and evidence | Remaining acceptance |
| --- | --- | --- |
| Observe work started normally in the Desktop App | New native read-only conversation inventory and turn-history queries. An opt-in native test found this actual conversation and its running/completed history. The separate App Server is no longer the activity authority. | Long-running soak, app upgrades, older schema variants, more than 100 recent conversations. |
| Persistent per-conversation watch | Authenticated Watch/Mute API and UI. SQL and React tests cover future-run preference, failure state, and muting. | Confirm interaction in the deployed iPhone Home Screen app. |
| One completion alert per run | Identity combines conversation, run, outcome, and device, independent of hook/recovery event IDs. Atomic ingestion/job insertion, retry leases, topic/tag reuse. PostgreSQL tests cover duplicates and multiple runs. | Real push delivery and crash-after-provider-acceptance behavior. Exactly-once presentation is not guaranteed. |
| Attention alerts | Reviewed hooks provide approval episodes; observed tool results clear an episode. Identity persists locally across restart. Trust and execution are distinct health states. | Actual hook execution, questions, simultaneous approvals, and denied/cancelled approval paths. Questions are not reliably detected. |
| Accurate lifecycle and timeline | Source-time ordering, terminal-state protection, per-run ranking, late-observation tests, existing filter/timeline tests. | Real failed/interrupted Desktop runs and full event sequences through the deployed path. |
| Useful iPhone monitoring | Home Screen manifest, push-only worker, explicit permission button, generic test notification, device revocation, 15-second dashboard default. | Physical iPhone, locked screen, closed web app, cellular data, Focus behavior. |
| Privacy | Explicit SQLite columns, stripped hook callbacks, normalized hosted allowlist, generic errors and lock-screen text, owner-only local persistence. Sentinel tests cover sensitive fields and malicious push payloads. | Independent security review, host logs, backups, access controls, actual hosted traffic inspection. Titles remain deliberately synchronized and potentially sensitive. |
| Network loss and recovery | Disk queue survives object recreation/restart, bounded retention, capped retry backoff. Hosted transient failures retry; gone subscriptions are revoked. | Full installed-app offline/reconnect test. The Mac's network was not disabled. |
| Retention and credential revocation | Embedded PostgreSQL tests cover physical event/session deletion, mute cleanup, subscription deletion, invalid ingest token, authentication, and same-origin mutations. Five production scheduled-execution duration reports had no error entries. | Production expired-row deletion, backup retention, real token rotation, and push already in flight. |
| Safe native packaging | Existing release flow inspected and left untouched. Native tests and signed 0.1.13 / 1013 build passed. Version exceeds installed and published 0.1.12 / 1012. Deep strict local signature verified. | Native menu rendered review, installed-app validation, Developer ID/notarization for distribution, Sparkle update/rollback verification. |

## Verification performed

- `npm run typecheck` passed. `npm run build` also type-checks both application and function/test projects.
- Web build and all 67 tests across 12 files passed during final rollout checks, including 11 real-SQL tests using embedded PostgreSQL and the added Bash packaging regression. No production database was used and push transport was mocked.
- All 32 native tests passed, including the opt-in metadata-only check against this Mac.
- Live metadata probe passed with the active run and 12 prior completed runs in its sample.
- Read-only hook probe failed as expected: six legacy hooks enabled but untrusted. The new source adds a seventh hook and revised command, neither installed nor trusted by this work.
- Local browser review at 1280×900 and 390×844 covered the notification disclosure, Home Screen guidance, disabled demo controls, finished filter, selected timeline, source-readiness wording, and horizontal overflow. New notification controls measured 44 px tall. No browser console errors were returned. This was desktop browser viewport emulation, not iPhone Safari or actual push delivery.
- Impeccable was used to preserve the incumbent interface while adding clear failure/setup states and phone-sized controls. Its mechanical detector reported existing font/side-accent conventions; those belong to the pinned App Stylr implementation and were not redesigned. The supplied reference URLs resolve to the current App Stylr reference landing page.
- Error/log review removed raw hosted error bodies from native delivery errors and raw database/push errors from API responses/logs. The legacy CLI still prints normalized titles in explicit dry-run output; do not publish that diagnostic output.
- `npm audit` reported two moderate advisories in the development-only Vitest/mocker chain, [GHSA-82fw-gwwq-j7x9](https://github.com/advisories/GHSA-82fw-gwwq-j7x9). Fix requires a major test-runner upgrade. No forced dependency upgrade was performed; no Vitest browser/mock server was exposed.

## What this does not deliver

The earlier universal public product, generic provider adapter, public onboarding/accounts, tenant isolation, and account-free local dashboard are not advanced by this private pilot. The legacy single-owner password and shared ingest token are not a public hosted security design. This branch intentionally does not add remote command execution or phone approval workflows.

## Recommended next steps

1. Backup, isolated restore verification, and the [additive migration](../database/migrations/004_personal_notifications.sql) are complete. Use the owner's actual Chrome session for further console work; no additional Neon login is needed.
2. The private web app/functions are deployed, authenticated Chrome reads work, anonymous reads are blocked, and the every-minute worker is registered. The published native feed is unchanged. Push/PR and native publishing remain separately approval-gated.
3. Build 1014 is installed and monitoring. Queue drainage and fresh hosted lifecycle delivery are verified; confirm the actual Start/Stop label when reviewing the native menu. Use legitimate hook review, never a trust-record bypass.
4. Run the live Mac-to-locked-iPhone completion test over cellular, followed by mute, revoke, retry, failure, and interruption checks. Do not expand public scope based solely on passing local tests.
5. Keep comprehensive attention alerts marked incomplete until actual question and distinct-approval signals are verified without reading conversation contents.
