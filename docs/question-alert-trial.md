# Question alerts during active work

The owner selected a five-second delay on 2026-10-11. The experimental implementation shipped in macOS 0.1.44 and the hosted trial was enabled after installation. Phone display is not yet verified. The hosted payload now preserves the established attention message for installed phone workers.

## Local implementation

- Keep question state separate from run state. Continuing work or a finished run does not, by itself, prove a question was answered or dismissed.
- Start a five-second delay only after observing an actual question request. Recheck that exact request before dispatch; suppress it if a matching answer or dismissal is known.
- Send at most one alert for each distinct question request. Repeated observations and ordinary working updates do not create another alert.
- Use explicit request identifiers for answers and dismissals. An asynchronous question tool returning is not an answer.
- Keep prompts, question text, options, and answers out of persisted diagnostics and hosted notification events.

Accepted `request_user_input_async` results supply call ID and bounded question count through the existing `PostToolUse` hook. Each question item has a distinct request identity. A read-only SQLite expression returns only identities and timestamps from exact structured reply envelopes. An unreadable answer source withholds new alerts. Question events never update dashboard run rows, counts, grouping, or final-reply previews.

Existing conversation watches, temporary coverage, device enrollment time, mute, internal-review exclusions, retries, and retention still apply. Watching a parent does not automatically watch its children. Local pending requests and answer deduplication expire after one hour. Hosted request records persist for seven days; new alerts older than ten minutes are suppressed, and unanswered requests expire after one hour. Answers arriving before opens create tombstones, preventing delayed outbox events from reviving answered questions.

Question notifications retain the distinct `question` delivery kind and deduplication identity, but use the established attention message on the wire. Existing installed phone workers allowlist message bodies; a new body can be accepted by the push provider and silently rejected by the worker. The sender-to-worker regression test executes actual server payloads through the actual push handler for every notification kind. A titled question displays **Needs your attention.** without requiring a phone worker update.

## Observed trial results

The owner reviewed and trusted a temporary metadata-only probe. On this conversation, it captured `UserPromptSubmit` and matching `PreToolUse` and `PostToolUse` events for `request_user_input_async`. The tool-call identifier matched between both tool hooks. The after hook arrived approximately 0.18 seconds after the before hook. A read-only run-status check afterward still reported `inProgress`.

The owner reported that the resulting preference card was not visible. These events therefore establish tool execution only. They do not establish a visible, actionable question, and no live answer or dismissal signal was verified. Ordinary subsequent user messages produced `UserPromptSubmit` events, but that is not proof that a particular question was answered.

The owner then identified visible, answered questions in **TF** and **WD**. Their read-only thread histories show question IDs with matching `request_user_input_async` structured replies, both in runs still marked `inProgress`. The current rollout filenames map stable chats to their resumed history IDs. The exact SQL expression now used by the observer returned matching request IDs and timestamps from both histories without selecting question text or answer values into the app.

Native tests cover the five-second delay, resumed identities, continued work and completion, repeated hooks, matching/partial answers, source failure, discovery timing, malformed replies, identity validation, and stripping sensitive content. Embedded PostgreSQL tests cover separate run state, deduplication, dispatch during work/after completion, quick answers, answers before opens, historic events, disabled activation, and strict input validation. Tests use fixtures and mocked push transport.

The live October 11 test opened on the server about 5.44 seconds after observation and produced one accepted push while the run remained working. The owner did not confirm phone receipt. On October 12, the worker regression reproduced the question payload being dropped before `showNotification`. Two additional live questions opened and resolved, with no retained delivery jobs. At that check, this chat had no individual watch and global coverage had expired at midnight. A valid phone test requires active coverage before the question is asked.

After the owner re-enabled global coverage, two more requests each produced one accepted push about six seconds after observation. The owner reported no phone display for either. This separates the expired-coverage issue from the incompatible message body. Phone receipt must still be verified after the payload repair is deployed.

## Integration boundary

[Codex hooks](https://learn.chatgpt.com/docs/hooks) describe tool invocation and output hooks. [The App Server documentation](https://learn.chatgpt.com/docs/app-server) describes `serverRequest/resolved` for answered or cleared `item/tool/requestUserInput` requests on an active transport connection. It does not establish resolution coverage for desktop `request_user_input_async` cards through an independent observer. Status Watchr's separate App Server checks hook trust and does not start or resume desktop conversations.

The new path stores request and resolution state separately from the existing `needs_you` lifecycle. The accepted async result's hook path is confirmed through the installed companion by a live hosted question record. Provider acceptance alone does not prove device display.

This trial covers accepted structured async questions and explicit structured replies. Plain-text questions, blocking `request_user_input`, automatic card dismissal, cancellation without a structured reply, and manual approvals are not covered by this new path. Do not claim every unanswered or dismissed request is known. A request dismissed without a structured reply can still alert; this pilot limitation needs a real dismissal test. Questions first asked while observation is stopped are not recovered as new alerts. Stopping the observer discards unannounced questions; the outbox retains already queued normalized events.

## Authorized rollout sequence

Publishing and activation require fresh approval. Source-only publication does not produce a Sparkle update.

1. Back up the private database. Apply [migration 009](../database/migrations/009_question_requests.sql) **before** deploying this hosted bundle, because dispatch selects the new request column.
2. Deploy the hosted API and retry function. Keep `WATCHR_QUESTION_ALERTS_ENABLED` unset or false initially. Deploying alone does not enable question alerts.
3. Publish and install a signed native update. The existing trusted `PostToolUse` companion hook is sufficient; this trial does not change hook definitions or trust records. Confirm normal completion monitoring still works.
4. Enable the native trial with `defaults write com.kylbutlr.statuswatchr questionAlertsEnabled -bool true` while the app is stopped through an owner-authorized action. Start the updated app normally, then set hosted `WATCHR_QUESTION_ALERTS_ENABLED=true` through an authorized configuration update.
5. Verify a fresh, visible question through the updated receiver, first answered within five seconds and then left unanswered during continued work. Verify exactly one provider dispatch and actual phone receipt. Check finished-run behavior and the dismissal limitation. Preserve queued-follow-up completion suppression and dashboard grouping.

Do not stop or replace a running installed app without the owner's explicit authorization. No preview server is needed for local tests.

## Disable the pilot

Set hosted `WATCHR_QUESTION_ALERTS_ENABLED=false` first, then disable the native setting with `defaults write com.kylbutlr.statuswatchr questionAlertsEnabled -bool false`, applying it on the next authorized app start. The hosted flag rejects new question events and suppresses undelivered question jobs at dispatch. Keep the additive migration and question-aware handler so offline question events remain safely ignored. Existing completion behavior is preserved without a database rollback. Notifications already in flight cannot be recalled.

Do not deploy an older hosted bundle while question jobs or question outbox events remain: it predates their separate kind. A full code rollback needs explicit queue reconciliation first. The diagnostic probe's temporary hook definitions have been removed, preserving unrelated hooks and settings.
