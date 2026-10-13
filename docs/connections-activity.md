# Connections activity reporting

Local implementation, not installed or published. Status Watchr's native API attempts are recorded as allowlisted metadata for App Switchr's Connections window. No URLs, bodies, headers, credentials, task contents or IDs are recorded. The journal is under this app's Application Support directory in `connections-v1`, capped at 5 MiB and seven days of visible history. Old disk records are pruned on startup and hourly while running; closed apps cannot perform retention cleanup.

`ConnectionActivity.swift` is vendored unchanged from App Switchr's `Sources/ConnectionActivity/ConnectionActivity.swift` so the apps do not depend on sibling checkouts or network package resolution. Update all three copies together and verify matching SHA-256 digests. The common contract tests live in App Switchr.

Reporting never changes request permission, cancellation or retry decisions. Manual request intent is carried from explicit operations; scheduled and catch-up activity stays automatic. App Switchr's control requests remain separately visible while Off. Todo Trackr marks conflict retries explicitly. Status Watchr tracks repeated queued request bodies in memory, so retry flags do not survive a process restart. New attempts are still counted after restart.

This is not billing or complete network accounting. Browser, updater, hosted functions, downstream providers and other devices are not measured. File errors, crashes and queue overflow can lose metadata; history must be labelled incomplete. Existing work data and credentials are untouched.

Recording health uses local macOS distributed notifications while Connections is open. This adds no network requests. An explicit failure displays History incomplete; no fresh response displays Recording health unconfirmed. Health responses are advisory application reports, not authenticated OS network evidence.

## Restored reporting in 0.1.20

The 0.1.19 release retained Switchr permission gating but did not include the
Connections telemetry branch. Its native executable lacked `connections-v1` and
the local health responder, leaving App Switchr with a stale 0.1.17 journal.
This restoration is based on current main and preserves the newer private-release
workflow and dashboard check-in display.

`build-macos-app.sh` now runs `check-connections-bundle.py` against the packaged
executable. The check fails on the installed 0.1.19 binary. Native regression tests
also exercise current-session permission reports and live recorder responses in
both Off and On states without requiring a provider request.

Local packaging is not publication. Merge and publish this fix through the normal
signed release workflow before relying on automatic updates to preserve it.
