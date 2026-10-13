# Local attention diagnostics

The macOS attention icon indicates a reported user-input request, not an error in Status Watchr. A `PermissionRequest` hook or generic `waitingOnApproval` flag alone no longer lights the icon, because Codex may be using Auto-review. Manual approval coverage is incomplete until a confirmed human-waiting signal is available.

The attention glyph uses a thicker, full-height mark within the existing menu-bar circle. Active and stopped artwork and the circle size are unchanged.

The existing local diagnostic history now records allowlisted attention categories: `approvalHook`, `appServerAttention`, `attentionChanged`, and `attentionCleared`. Existing timestamp, occurrence, and queue fields remain unchanged. No conversation titles, IDs, tool arguments, prompts, code, credentials, or arbitrary payloads are added. Conversation titles shown in the menu come from the existing in-memory metadata, not the diagnostic history.

History remains local under `~/Library/Application Support/Status Watchr/diagnostics/history.json`, retained for seven days and bounded to 200 entries. It is not transmitted. Right-click (or Control-click) the menu-bar icon and choose **Export diagnostics** to save an owner-readable JSON copy to a location you choose. Export does not open the file in its default application or upload it. Exported copies remain until you delete them; automatic retention only applies to the app's internal history. Removing the internal file deletes the saved history; new diagnostics may be recorded while monitoring runs.

The main panel retains **Last scan** and actionable errors/attention. Hook readiness and collection counters now live under **Troubleshooting** in the right-click menu, alongside dashboard, update, and quit actions. The redundant Open ChatGPT shortcut was removed; the hook trust guide remains in Troubleshooting.

Diagnostic `approvalHook` records remain evidence that a hook ran, not evidence that the owner needed to act. If a false attention state recurs, compare its timestamp with the recorded source and clear transitions before changing lifecycle handling.

Attention push delivery holds a newly observed request for ten seconds, then rechecks that the conversation still needs input and has not resumed work since that request. Auto-approved requests that resolve before dispatch are discarded. Completion and failure pushes keep their existing immediate path. The scheduled delivery check runs every minute, so a real attention push may arrive on the next minute tick rather than immediately. This requires the hosted API update; installing a Mac build alone does not activate it.

The disabled [async question trial](question-alert-trial.md) uses a separate five-second confirmation window and independent request state. Continued work does not clear those requests; matching structured answers do. The existing approval path is unchanged.
