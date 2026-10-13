# Resumed task history identity repair

## Confirmed defect

On 2026-09-21, the owner showed three active Desktop tasks while the hosted dashboard showed only one. Read-only metadata checks reproduced the difference: Status Watchr and WD had old interrupted runs under their stable task IDs and current running turns under the history IDs referenced by their current rollout filenames. MIX used the same identity in both places and appeared correctly.

The observer used the inventory ID directly as the turn-history key. This was an incorrect identity assumption, not an iPhone refresh problem. Healthy transport and source readability did not establish correct lifecycle coverage.

## Repair

- Select the current rollout pointer as additional local inventory metadata. Never read its contents or transmit its path.
- Recognize only the observed anchored filename format containing the exact original task UUID followed by a history UUID. Other filenames and older inventories retain the original lookup behavior.
- Read turns using the resolved history ID, then key the resulting history by the original task ID. Event and watch identities stay stable.
- Do not fall back to an obsolete interrupted/completed history if an explicitly mapped current history has no rows yet.
- Refresh mappings with inventory discovery, currently at most 60 seconds apart. This remains an observer of an internal local schema, not a guaranteed provider API.

## Verification and boundaries

The SQLite-backed regression test first failed by returning `old-run` instead of `new-run`. It exercises inventory discovery through the same mapped-history method now called by the controller, tests active and completed runs, rejects a second dashboard identity, and checks missing history cannot resurrect old state. Separate tests reject malformed and unrelated rollout pointers. The opt-in live metadata test checks that this actual task's latest mapped run is working.

The private package also includes the previously committed [diagnostic history](diagnostics.md). No database migration, web deployment, native feed publication, or credential change is needed. The discovery limit of 100 tasks and incomplete attention detection are not fixed by this repair. See the installation and live verification checkpoints below; phone notification delivery is not established by desktop browser verification.

## Installation checkpoint

On 2026-09-21 the owner approved replacement and manually quit the previous app. Build 0.1.15 / 1015 was installed and reopened; strict deep signature verification passed and its executable SHA-256 matched the prepared bundle (`640be8d8b8ac10fa50c893169d202cd887fd4a146df5749e282d43cc751b82a7`). Build 1014 remains intact at ignored `build/installed-1014-backup/Status Watchr.app`. The new process is running and its owner-only diagnostic file exists. Monitoring starts through the menu's Start control, not automatically on launch. Live dashboard verification remains pending that action; opening the app and seeing an empty queue do not establish active observation.

## Live verification after Start

After the owner confirmed Start on 2026-09-21, the production dashboard was checked in Chrome. This original Status Watchr task appeared In progress with a fresh Task started event. WD appeared Finished with a recent Task completed event. The dashboard reported two in-progress tasks at that snapshot. The installed bundle version was rechecked as 1015, the local outbox contained zero events, and diagnostic history was empty. This verifies repaired observation through hosted ingestion and rendering for these tasks, not exhaustive coverage of all tasks or actual iPhone notification delivery. The dashboard still warned that attention hooks need review.
