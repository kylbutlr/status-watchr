# Local diagnostic history

The private pilot first gained local diagnostics in 0.1.15 / 1015. The SQLite detail and scan-freshness additions are installed locally in private build 0.1.33 / 1033. This is instrumentation, not by itself a fix for intermittent tracking errors. The original build contained the separately verified [history identity repair](history-identity-repair.md).

The Mac companion records failures and subsequent recoveries for event delivery, collector health requests, local run-source availability, and local queue writes. Network failures distinguish timeout, offline, and other connection errors. HTTP failures retain only the numeric status. An empty queue or stopped delivery batch does not count as transport recovery.

## Data and retention

The fields are first/last occurrence time, an enumerated operation and category, optional HTTP status, bounded queue count, and bounded occurrence count. A failed local SQLite query can also record its numeric SQLite result code, numeric SQLite schema version when readable, and numeric version from the selected database filename. These numbers are stored only in the local diagnostics history and appear in a manual export. No arbitrary error description, SQL text, database path, URL, token, task title, task ID, prompt, code, terminal output, event body, or server response body is accepted by the logging API. Older entries without these optional fields remain readable.

History is stored at `~/Library/Application Support/Status Watchr/diagnostics/history.json`. The directory is owner-only (0700), and the file is owner-readable/writable (0600). Updates replace the file atomically. Nothing is uploaded or copied to the clipboard automatically.

At most 200 entries from the last seven days are retained. Repeated failures are grouped only when their category, HTTP status, and SQLite numbers match; their count/latest timestamp is checkpointed at most once per minute. New failures and recoveries are written immediately. The last minute of repeated counts can be lost on an abrupt exit. Cleanup runs on startup, observation, and export; when the app is not running, the file remains until the next cleanup. Grouped first-occurrence timestamps may predate the seven-day last-occurrence window.

**Export diagnostics…** in the right-click menu opens a save dialog for the JSON file. Reading/sharing it is manual. It contains operational timestamps, so review it before sharing. Delete the local history file to remove retained diagnostics; the app can recreate it while running. Do not delete the neighboring outbox or credential stores. A malformed or oversized history reports a storage failure and can be replaced by the next recording attempt; there is no raw corrupt-file export.

The menu shows **Last successful scan**. While the local source is unavailable, it also shows elapsed degradation time; stopping the observer clears that duration. These values describe this app launch and are not sent to the hosted service. A new app launch starts the scan timestamp fresh, while diagnostic failure/recovery episodes remain in the retained history.

Failure to save diagnostics does not block normal delivery. Exporting diagnostics reports a safe storage error if writing fails. This version does not retain hook-setup, Keychain, launch-at-login, browser, or server-internal failure histories; existing hosted logging is unchanged. A generic HTTP 400 still cannot distinguish malformed ingestion from a storage failure.

## Verification and rollout

Tests exercise restart persistence, repeat grouping, recovery, count/age bounds, file permissions, privacy sentinels, storage failure, and real delivery-path rejection/timeout/recovery. No live credentials or private events are used.

At the 2026-09-21 check, the native suite passed with 41 tests and two opt-in skips; 78 web tests, TypeScript checks, and the production web build passed. The native menu had not yet been visually inspected or exercised in the installed app at that check.

The original private-pilot check established active delivery, not capture of a natural intermittent source failure. The new numeric SQLite fields are verified with an incompatible-schema fixture. Build 0.1.33 is installed and its process is running. The owner reported that Start first showed an error, then worked after a restart. Local hook diagnostics after that report show monitoring resumed, and read-only execution of the current inventory and turn-history queries succeeds. The first error text and a natural SQLite failure with the new numeric fields remain uncaptured. The menu inspection tool timed out, so the live menu label was not visually verified. No database migration or web deployment was required for these local additions.
