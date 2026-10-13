# Completion confirmation regression

## Reproduction on October 11, 2026

The installed companion was verified as 0.1.40, sourced from `c293468`. The five-second confirmation code remained present. Fixture tests reproduced completion events becoming notification eligible while a follow-up was already running. These isolated tests do not identify which exact ordering produced the owner's phone alert.

Two weaknesses caused the reproduced failures:

- A Start only invalidated completions already pending at that instant. A delayed Stop or another completion source could create a fresh eligible event afterward.
- A title change could replace a suppressed pending event with a newly constructed eligible event. The title metadata deduplication introduced in 0.1.40 allowed this replacement.

The minimized command was `swift test --jobs 2 --filter CompletionConfirmationTests`, run from `apps/macos`. The delayed-Stop, title-refresh, and lagging-poll tests failed before the fix. A separate first-history-discovery test also failed before its fix.

## Implementation

Remember observed run starts using the existing turn-identity/timestamp ordering helper. A newer start permanently suppresses the previous run's completions for that monitoring period, across Stop hooks and history polls. Older observations cannot reverse the transition. Title refreshes preserve suppression and the original five-second deadline, including the existing final-reply preview when still eligible.

At confirmation, reread both inventory and history. An observed Start missing from that projection prevents the older completion from alerting. Once history catches up, a later genuine finished run remains eligible. Stop and standby clear the in-memory transition state alongside pending confirmation timers.

## Requirement coverage

| Requirement | Native regression evidence |
| --- | --- |
| Idle completion waits at least five seconds | `testIdleCompletionWaitsFiveSecondsAndDoesNotRepeatConfirmedEvents` |
| Queued follow-up suppresses the previous completion | `testCompletionIsHeldBeforeQueuedFollowUpCanResume` |
| Start received before delayed Stop also suppresses | `testFollowUpStartBeforeDelayedStopSuppressesCompletionWithLaggingHistory` |
| Title refresh cannot re-enable an alert | `testTitleRefreshCannotRestoreEligibilityAfterFollowUpStarts` |
| Stale polls cannot undo suppression; latest run still alerts | `testLaggingPollCannotUndoResumeAndLatestCompletionStillAlerts` |
| Start before first history discovery remains authoritative | `testStartSeenBeforeHistoryDiscoverySuppressesOldCompletion` |
| History-only resumption suppresses; recovery remains supported | Existing fresh-metadata, recovered-completion, missing-metadata, and standby/Stop tests |

## Delivery verification

Local validation passed: 10 focused completion tests; 99 native tests passed with five opt-in checks skipped; all 126 web tests, typecheck, and production build passed. The skipped checks cover live metadata and native render artifacts. No interface change was made.

This is a native source fix. No database migration or hosted notification query change is required. It requires an approved native release and installation before it affects the user's companion. Keep source tests, published artifacts, installed version, and physical phone receipt as separate evidence states.

After installing the release, watch a conversation, queue a follow-up before its current pass ends, and verify that the earlier pass produces no phone alert. Then allow the follow-up to finish with no queued prompt and verify one completion alert after at least five seconds. Also verify that a title refresh does not send another alert. Physical delivery remains pending until these installed-app checks are performed.

## Hosted dispatch follow-up after 0.1.41

The owner reported further "Run finished" alerts after updating. The installed bundle was verified as 0.1.41 with source revision `1ca96c1146fc5e08b0ef4221836c5729bb048cbe`. Read-only local turn history showed queued follow-ups starting in the same source second as the preceding completion, including TF. The hosted dashboard showed TF in progress while its latest timeline item was Run finished. This establishes a real ordering pattern, but does not identify the exact delivered phone alert. Completed subtasks alongside running parent conversations remain another possible source; the alert's conversation title has been requested.

The hosted dispatch guard only rejected a completion when another run's start timestamp was strictly later than the completion event. Two integration fixtures reproduced a push being sent while a follow-up was running:

- The old completion and next start share the same source second.
- A delayed Stop arrives after the next run starts, making the old completion timestamp misleadingly later.

The minimized failing command was `npm test -- tests/notification-integration.test.ts -t 'same source second|delayed Stop completion|zero-duration'`. Before the dispatch fix, the two suppression tests failed and the genuine idle completion control passed.

Dispatch now resolves a completion job back to its run using the existing notification identity and checks the retained runs immediately before sending. A newer run invalidates the old completion even if that newer run has also finished. Codex UUIDv7 timestamp prefixes distinguish run order independently of delayed Stop times, including when an old Start was never recovered. Only the timestamp prefix is compared because the remaining UUID bits can be random, per [RFC 9562 section 5.7](https://www.rfc-editor.org/rfc/rfc9562.html#section-5.7). Tied UUID timestamps and other run identifiers fall back to source start times, preserving milliseconds for both database strings and Date objects. The completion's own run is excluded from the comparison, so an idle completion with identical start and finish remains eligible.

The guard runs for both initial delivery and persisted retries. If the completed run cannot be identified within the latest 20 retained runs, the old job is dropped because its eligibility can no longer be established. Watch permissions, attention alerts, failure alerts, deduplication, and push retry handling retain their existing checks. No database migration or companion update is required for this hosted change; the native five-second confirmation remains in place.

Final local validation passed: all 132 web tests, including 41 PostgreSQL integration tests, typecheck, and production build. Six new regressions cover the two reproduced ordering failures, zero-duration idle completion, an unrecovered old Start, same-second final completions, and tied UUID timestamps with precise source starts. The last case also caught and corrected Date-to-string millisecond loss before final validation.

The hosted fix was pushed as `81944c2746dcf8d15409428b2d480eb2e643e72d` and published in [production deployment 6acbf03a6d030c3a6a615f0b](https://app.netlify.com/projects/statuswatchr/deploys/6acbf03a6d030c3a6a615f0b). Production health returned 200, unauthenticated sessions returned 401, the page and unchanged 0.1.41 appcast matched the verified build, and the retry function's one-minute schedule was confirmed. Physical phone validation of the same-conversation cases remains pending. The server can reject obsolete jobs only after the newer run has been ingested, and cannot retract a push already accepted by the provider.

## Subtask alert trace after the hosted fix

The owner subsequently reported an alert headed `KRMD: 500458 (3)` and confirmed that its title continued with a subtask name. Read-only inventory and history on October 11 showed the parent still in progress, with completed `mobile_cart_acceptance_review`, `cms_package_fresh_acceptance_review`, and other child conversations. The live dashboard showed the same distinction with all-conversation alerts enabled. The main parent had no new completed turn corresponding to that recent child activity. The installed bundle was 0.1.41, and its running process started after that release binary was built. An exact provider delivery record was not available, so the specific delivered child job remains unattributed.

This was a separate missing relationship check. Both the native five-second confirmation and hosted dispatch compared turns within one conversation. A child that genuinely stopped remained eligible even though its parent was still working. This is why a same-conversation timing fix could not suppress these incremental subtask alerts. The resolved title issue made the relationship visible; titles are not used as authority for notification policy.

The minimized reproduction is `swift test --jobs 2 --filter CompletionConfirmationTests.testSubtaskCompletionStaysQuiet`. It failed before the parent check because the child completion was notification eligible. It passes after the fix, retaining child activity and allowing the parent's final completion after its normal five-second wait.

The companion now reads explicit subagent classification and parent IDs from the existing inventory projection. At confirmation, it follows ancestors and requires their current projected turns to be finished. Working or unavailable ancestors, a Start ahead of the parent's projection, missing parent links, cycles, and excessive ancestry suppress the child completion. Focused read-only lookups include archived ancestors and ancestors outside the 100-conversation discovery window. Each parent's resumed history identity is resolved normally. These relationships remain local; no database migration or new hosted event field is required.

Six new native regression tests cover active-parent suppression and final parent eligibility, title changes after suppression, idle archived parents outside discovery, resumed parent identities, nested subtasks, missing or cyclic links, and live parent Starts preceding projection updates. Previously confirmed and suppressed child completions do not replay when the parent later finishes. Failure and attention handling retain their existing behavior.

Final validation passed: all 16 focused completion tests; 105 native tests passed with five existing opt-in tests skipped; all 132 web tests, typecheck, and production build passed. The opt-in native skips cover live metadata and render artifacts. The live inventory/history and dashboard trace above were separate read-only checks; no interface changes were made.

This fix requires a new native release and installation, in addition to the already deployed hosted guard. Existing provider-accepted notifications cannot be recalled. After installing, verify that a subtask finishing during an active parent produces no phone alert, then verify that the parent's final idle completion produces one. Published and installed behavior remain separate from local fixture proof.
