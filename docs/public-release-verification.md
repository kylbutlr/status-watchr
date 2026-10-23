# Public release verification, 2026-10-22

## Verification and limits

The extracted source passed type checking, all 148 packaged tests, and its standalone build. The extracted server passed real HTTP checks for optional password modes, origin enforcement, authenticated ingestion, persisted restart, and static source exclusion. The complete checkout passed 157 web/server tests; native tests executed 123 cases with five opt-in integration cases skipped and zero failures. Hook coexistence was tested against a disposable hooks file. File manifests and SHA-256 are attached.

Fresh browser visual acceptance remains pending because Browser Use rejected authority over a stale error page. No installed companion, real monitoring, phone notifications, or private update feed was changed or exercised. Physical phone delivery and live Codex metadata compatibility are separate, unverified acceptance checks. This is a secondary notification signal; question detection is experimental and delivery is not guaranteed.

Publication preparation retains the existing repository and history at Kyle's explicit request. A pattern scan of all blobs reachable from the release candidate and origin/main found no credential matches after checking one blank-setting false positive. This is pattern-based evidence, not a guarantee that arbitrary historic content is non-sensitive. Historical screenshots and rollout notes remain in the repository by request.

No agent-owned preview server remains running.
