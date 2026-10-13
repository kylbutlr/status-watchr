# Status Watchr for macOS

Status Watchr for macOS is the private local observer. It reads explicit conversation and run metadata from Codex's local SQLite projections, and for recent completed turns it can read a bounded final-reply preview from the local rollout. It supplements this with reviewed lifecycle hooks and sends normalized events to the private dashboard. A separate App Server inspects hook readiness only, not Desktop activity.

It does not upload prompt, reply, approval-body, source-code, terminal, or diff contents. Approved conversation titles and project labels do sync and can be sensitive. The ingest token stays in the macOS Keychain. Known runs are checked every five seconds; discovery defaults to 60 seconds with 15, 30, or 60 second choices. An owner-only disk outbox survives offline operation and app restart.

Unnamed subagents use the parent conversation's existing title and the subtask path label, then the agent nickname or short identity when that metadata is unavailable. Authored names take precedence. Other unnamed conversations use `Untitled task`, never a prompt-derived title. Titles are trimmed and bounded to the server's 500 UTF-16-unit limit. Title changes on finished runs preserve event identity and source time and suppress additional alerts. A separate title-only repair includes archived unnamed subtasks beyond lifecycle discovery; batches contain at most 100 titles and stay below the 16 KiB ingestion limit. The server only repairs placeholder names on retained terminal runs, preserving active and expired history and already known names. See [repair details and rollout gates](../../docs/conversation-title-repair.md).

Pending events from older builds receive the same title preparation in memory before delivery; event IDs and source timestamps remain unchanged. Queue files are removed only after successful delivery (or the documented seven-day expiry). Rejected/unreadable events remain queued while other events in the batch can continue. Authentication, rate-limit, and server failures stop the batch and back off; errors show only safe HTTP status categories, never response bodies.

## Diagnostics

The source resolves resumed task history IDs from the current rollout filename while preserving the original task identity for hosted activity and watches. See the [identity repair and verification boundaries](../../docs/history-identity-repair.md). Only the filename metadata is inspected, never rollout contents.

The private pilot includes [local diagnostic history](../../docs/diagnostics.md), available through **Export diagnostics…** in the status item's right-click menu. It records bounded operational timestamps, error categories, queue counts, recoveries, and numeric SQLite failure details locally, not raw errors or event contents.

## Codex hooks

Enable `Connect Codex hooks` in the menu bar app to add lifecycle hooks to `~/.codex/hooks.json`. Existing hooks are preserved, and disabling the toggle removes only the Status Watchr entries. The hook command sends Codex's structured lifecycle payload to the app over `127.0.0.1`; the app then strips prompt and tool data and forwards the normalized status event with the existing Keychain ingest token.

The hook integration installs `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, `Interrupt`, `SubagentStart`, and `SubagentStop`. Definitions require separate review and trust in Codex; installation alone does not prove execution. Raw hook input is stripped in memory before persistence. A `PermissionRequest` hook is recorded for local diagnostics but does not by itself produce a “Needs you” state or notification, because Codex may send it to Auto-review. Questions are not reliably detected. The observer does not change Codex's existing `notify` command or start or resume agent turns.

The observer also treats a generic `waitingOnApproval` flag as working, not as proof that the owner is needed. Genuine manual approvals may therefore be missed. Reliable attention alerts require a source that distinguishes the human reviewer from Auto-review without reading prompts, tool inputs, or rollout content. Previously persisted hook-derived attention is cleared when this candidate starts.

## iPhone notifications

The private dashboard offers persistent per-conversation watches and Web Push notifications that can show the conversation title and a short final agent answer on the lock screen. Test alerts remain generic; a missing final answer falls back to status copy. On iPhone, install the site to the Home Screen, sign in, and explicitly enable the notification device. Status Watchr does not provide phone replies, approvals, or remote control. See the [notification preview rollout](../../docs/notification-reply-preview.md) and [pilot setup and privacy boundaries](../../docs/personal-monitor.md).

Completion alerts wait at least five seconds before delivery. The observer rereads inventory and the latest turn, including resumed history identities, and enables an alert only if that same turn is still finished. A newer start suppresses the earlier run even when its Stop arrives late. Suppression belongs to the run, so title refreshes, another event source, and lagging polls cannot restore eligibility. Metadata refreshes preserve the original confirmation deadline. A live Start absent from history prevents an older completion from alerting. Subtasks also require confirmed finished parents and ancestors, using structured spawn metadata rather than title text. A working ancestor or one whose state is unknown suppresses the child alert. Focused read-only parent lookup covers archived parents and those outside the discovery window, and resolves resumed parent history identities. Missing or cyclic parent links fail closed. Suppressed completions remain in activity history. Missing or unreadable metadata for the completion itself retries every five seconds; after ten minutes the completion is retained without notification eligibility. Stop and confirmed App Switchr standby cancel pending timers, with normal history recovery on resume. Failure and attention events keep their existing behavior. See the [completion regression checks](../../docs/completion-confirmation-regression.md). This source change does not update the installed app until a native release is approved and installed.

## Development

```sh
swift package resolve
swift run
```

The app searches normal command-line locations and the ChatGPT/Codex application resources for the `codex` executable. Local metadata observation continues if the separate App Server is unavailable. Codex's database schemas are private implementation details and can change.

## Distribution

See the [release reconciliation](../../docs/macos-release-reconciliation.md) for the installed/private/public version split and the prepared 0.1.18 candidate. Private distribution must advance the tracked latest-distributed-version floor. Preparing a candidate does not publish or install it.

The existing release path uses a versioned app bundle, a persistent Status Watchr signing identity, and Sparkle-signed archives and appcast. A private pilot build must not modify or publish that feed. Local certificate signing is not Developer ID signing or notarization. Public distribution requires separate approval and verified Developer ID, hardened runtime, notarization, and update-chain testing. Never overwrite a running application; verify increasing bundle version and preserve the old installed bundle before an approved replacement.
