# Mac release reconciliation

## Private diagnostics install, 2026-09-27

The owner confirmed quitting Status Watchr and approved replacing and reopening only that app. Process checks found no running `StatusWatchr` before replacement. Private build 0.1.33 / 1033 was prepared from clean source `1198b0047994ece680ce7fa863fa7269ee98e309` using the existing Status Watchr Local Code Signing identity. Deep, strict signature verification passed for the staged and installed bundles; the installed executable matches the staged SHA-256 `b8ae9d66d86da59ada9ebf15ba89ee30d2fcb1c77f2e871520a3e48bd86997d4`.

The former 0.1.32 / 1032 app was verified and preserved at `build/rollback-0.1.32-1032/Status Watchr.app` and `/Applications/Status Watchr.app.pre-0.1.33`. The new app is installed at `/Applications/Status Watchr.app`, and its process was verified running. Native UI inspection timed out. The owner reported that Start first showed an error, then worked after a restart. Local hook diagnostics show monitoring resumed; read-only execution of both current metadata queries succeeded, with no new local-source failure recorded since this installation. The first error text is unknown. No source push, public update-feed change, deployment, notarization, or natural SQLite failure capture occurred during this installation.

## Observed on 2026-09-21

- Installed application: 0.1.17 / 1017. Its deep, strict code-signature verification passed outside the restricted tool sandbox. The persistent Status Watchr Local Code Signing identity is available.
- Public Sparkle feed: 0.1.12 / 1012. Source version metadata was also 0.1.12 / 1012.
- The installed bundle contains no source revision or build manifest. Its exact source commit cannot be established from that bundle. A valid signature is not proof of source equivalence, Developer ID distribution, or notarization.
- Installed executable SHA-256: `d654147ed7f81ca0bd02a8a34ed4e15b311b9b04c0474b1a7a9ab854dfd777f8`, recorded as an identity baseline, not a source-provenance claim.
- Recent dashboard fixes are web-only and do not require a native update.

## Prepared candidate

The prepared candidate is 0.1.18 / 1018. `apps/macos/Resources/latest-distributed-version.txt` records the highest known distributed version, including private installs, now 0.1.18. Update this record after every approved private distribution, not merely when preparing a build.

## Approved private installation

The user approved replacing and reopening only Status Watchr. After confirming the app had stopped, the 0.1.18 / 1018 candidate was installed and reopened. Deep, strict signature verification passed before and after installation. Its embedded clean source revision is `4727caf20eb023326212776f8adccf9b74d9699e`; this distribution record is a subsequent documentation change, not the binary's source revision.

The exact former application is preserved at `build/rollback-0.1.17-1017/Status Watchr.app`. No public release, update-feed change, notarization, or end-to-end phone notification verification was performed by this installation.

The workflow considers both this floor and the live public feed. Local release packaging also rejects versions at or below the known floor, versions not newer than the installed bundle, and archive overwrites. Future app bundles embed their source revision and whether the checkout was dirty before signing. Only a clean build establishes an exact recorded commit.

Version comparison now uses explicit decimal arithmetic. The previous zero-padded representation was interpreted as octal by Bash and failed for versions containing 8 or 9, including 0.1.18.

The workflow verifies Kyle Butler <kyle@sdg.la> as author and committer before its release commit, and dry-runs the explicit main/tag destinations before an atomic push. It remains manual. Running it publishes a signed update feed and deploys production, so dispatch requires explicit approval.

## Remaining gates

## Private pilot install, 2026-09-22

The local 0.1.26 / 1026 test build was compiled from `e40516439f4c25547295248ec6c3daf28dffd509` with uncommitted changes, signed by the existing Status Watchr Local Code Signing identity, and installed at `/Applications/Status Watchr.app`. Deep, strict signature verification passed before and after installation. The app was reopened and its process and installed version were verified. Its executable SHA-256 is `808c8843a063ff264df14646d8489bc178056c59a04a0115f5cc43573acba234`.

The previous 0.1.25 / 1025 app remains preserved at `build/rollback-0.1.25-1025/Status Watchr.app` and `/Applications/Status Watchr.app.pre-0.1.26`. This is a local private test installation only. No Sparkle feed, hosted service, deployment, or public release was changed. Real Codex auto-approval and manual-attention event behavior still needs runtime validation; local tests do not establish that app-server event stream behavior on the installed machine.

### Private update channel

The existing single-owner update channel uses the persistent local code-signing identity and Sparkle Ed25519 signatures. Continuing this private channel is distinct from a broader Developer ID / notarized public distribution. Archive and feed URLs on the existing website are publicly retrievable, even though dashboard activity requires authentication; no credentials or activity data should be included in the archive.

Version 0.1.19 / 1019 was prepared from clean source `694af0d4f1efaad4d97e31b703cd53c5f706fc65`. Its archive and appcast signatures were verified with Sparkle, and the extracted app passed deep, strict code-signature verification. Publication remains pending. Keep the distribution floor at 0.1.18 until 0.1.19 is actually distributed. Once published, verify the downloaded feed and archive, then test the installed app's update flow with user approval for any restart.

- Run web and native tests, prepare a local signed candidate, and verify its version, provenance, and signature.
- Do not replace or quit the installed application without separate current approval and a preserved rollback bundle.
- Do not publish the archive/feed, trigger the release workflow, tag, or deploy without separate current approval.
- Local-certificate signing is not Developer ID signing or notarization. Public distribution requires verified Developer ID signing, hardened runtime, notarization, and update-chain testing. Those are not implemented or verified by this reconciliation.
- The Open ChatGPT button and coarse hook-readiness wording are unchanged. This is release preparation, not a fix for those UX issues.
