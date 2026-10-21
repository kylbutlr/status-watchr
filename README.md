# Status Watchr

A private Mac-to-iPhone activity monitor for coding work started in the Desktop App.

This branch implements a completion-first personal monitoring path. The private web pilot is deployed. The owner reported successful phone test and watched-completion notifications; physical iPhone verification of temporary all-conversation alerts remains pending. Private Mac build 0.1.15 / 1015 is installed, and its repaired task tracking was verified through the live dashboard. Complete attention/question detection remains unresolved. See the [identity repair checkpoint](docs/history-identity-repair.md), [temporary-alert verification boundaries](docs/temporary-alerts.md), and [earlier rollout record](docs/pilot-rollout-2026-09-20.md). The earlier public multi-provider product expansion is paused.

## What this slice does

An optional [question-alert trial](docs/question-alert-trial.md) is prepared locally and disabled by default. It separates structured async question requests from run status, holds alerts for five seconds, and clears matching structured answers. Native and hosted activation, a signed app update, and end-to-end phone verification are separate rollout steps.

- Reads explicit conversation and run metadata from the Mac's local Codex SQLite projections without starting or resuming tasks.
- Checks known runs every five seconds, discovers up to 100 recent unarchived conversations every 15 to 60 seconds, and recovers recent completed runs between checks.
- Holds completion events for at least five seconds, then rereads local inventory and turn history before enabling a completion alert. A resumed follow-up preserves the earlier completion in history without a phone alert; unavailable metadata waits for confirmation. Hosted dispatch also drops pending completions superseded by a newer run. These source changes require a native release and hosted deployment before they affect the installed pilot.
- Checks subtask parent relationships during completion confirmation. A finished child stays quiet while a parent or ancestor is still running or cannot be confirmed idle. Parent completions keep their normal five-second confirmation. This additional native source change requires a companion update.
- Separates local-source availability, hook trust, observed hook execution, and pending delivery from a successful dashboard refresh.
- Queues normalized events on disk for network recovery.
- Persists optional conversation watches across subsequent runs until muted.
- Adds temporary all-conversation alerts for 15 minutes, 1 hour, or 4 hours without changing individual watches. Live in the private pilot with migration 005; physical iPhone verification for this mode remains pending.
- Sends optional completion and failure notifications with the watched conversation title and a short final-reply preview when available. Attention delivery remains experimental: ambiguous approval hooks and generic waiting flags no longer trigger a “Needs you” alert. Test alerts remain generic.
- Includes an iPhone Home Screen manifest, push-only service worker, explicit device opt-in, test notification, and revocation.
- Exposes no remote commands, replies, or approval controls.

“In progress” is not proof of active computation. A finished run is not proof that the assignment is complete. Questions are not reliably detected. Multiple simultaneous approval requests remain ambiguous without a unique source request ID.

Read [the architecture, privacy boundary, threat model, retention rules, and setup guide](docs/personal-monitor.md) and [the readiness report](docs/personal-monitor-readiness.md) before installing or deploying this branch.

## App Switchr

The optional [App Switchr integration](docs/app-switchr.md) pauses automatic cloud work. A confirmed Off also pauses the Mac's local observation until On resumes it; an unavailable permission keeps local capture but still blocks uploads. Source changes require a separate hosted and native rollout.

## Local development and verification

```sh
npm ci
npm run dev
npm run typecheck
npm test
npm run build
cd apps/macos
swift test
```

Vite development uses explicitly labeled demo data. The notification controls do not send requests in demo mode. For an intentionally configured local backend, set `VITE_WATCHR_LIVE=true` and run the documented Netlify development command, `npm run netlify:dev`. Never prefix secrets with `VITE_`.

The Node tests include embedded PostgreSQL tests of the migrations and real ingestion/notification queries. They do not use production Neon or send real push notifications. The native tests cover read-only projection parsing, hook trust, hook payload stripping, and persistent offline queue/attention state.

Read-only diagnostics:

```sh
node scripts/probe-desktop-activity.mjs --thread YOUR_CONVERSATION_UUID --expect-active --require-completed-history
CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex node scripts/probe-codex-hooks.mjs
```

The first selects lifecycle columns only. The second starts its own read-only App Server for hook inventory, then stops that diagnostic process. It neither trusts hooks nor starts agent work. Passing these checks does not establish phone delivery.

## Private hosted setup

The existing single-owner password cookie and separate ingest token remain in place. This is not public SaaS authentication or tenant isolation.

Apply [migrations 001 through 006](database/migrations) in order only after approval and backup. The existing private deployment has 005; migration 006 is required before deploying reply previews. [Temporary-alert rollout evidence](docs/temporary-alerts.md) records the earlier additive upgrade and remaining phone checks. Configure server secrets from [.env.example](.env.example), including VAPID keys for push. Deploying the scheduled retry function activates physical retention deletion, not just dashboard filtering. See the setup sequence and deletion boundaries in [the personal monitor guide](docs/personal-monitor.md).

The dashboard source offers temporary all-conversation alerts at the top, persistent per-conversation Watch/Mute, and notification-device controls. On narrow screens, selecting a conversation opens its details immediately; Back to conversations restores list position. On iPhone, add the site to the Home Screen, open it there, explicitly enable notifications, and test delivery before relying on it. [WebKit platform requirements](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/).

Dashboard refresh offers On open / focus, 15 seconds, 30 seconds, 1 minute, or 5 minutes. New settings default to 30 seconds; existing supported choices remain unchanged. Saved 2-minute settings migrate to 1 minute, and saved 15-, 30-, or 60-minute settings migrate to 5 minutes, matching the previous scheduler cap for those longer choices. Dashboard refresh does not control push delivery or the Mac observer's polling interval. General notification coverage help is inside Notification device settings; active expiry and Always on status remain visible above it.

## Mac companion

### Neon compute budget

The dashboard uses its selected interval as a starting cadence, backing off unchanged snapshots to ten minutes. Returning to the page or receiving changed data restores the starting cadence. Notification settings refresh every ten minutes and on return or explicit interaction; expiry still updates locally.

Collector health is stored in Netlify Blobs without querying Neon. Empty notification retry ticks also stay outside Neon after one bootstrap for existing jobs. Durable receipts preserve delayed and failed delivery recovery. Physical retention runs every six hours while Switchr permits work. See [the compute budget and rollout checks](docs/performance-research.md#compute-budget-update-october-21-2026). These hosted changes require deployment; they do not require a native update or database migration. Savings and real phone delivery remain unverified until rollout.

The [native companion](apps/macos) uses read-only metadata queries as its Desktop observation source. Its separate App Server only inspects hook readiness. Source failure stays unavailable; native monitoring no longer falls back to rollout message files.

Internal Guardian reviews are filtered using Codex's type metadata before discovery limits. ID-only exclusion reports hide previously uploaded reviews and prevent their notifications. This requires migration 007, the updated API, and the native update. See [internal review filtering and rollout](docs/internal-review-filtering.md).

Codex hooks are optional and require review of their exact definitions. Installation alone does not mean they can execute. The revised installer preserves unrelated hook handlers and the existing Codex `notify` command. See [Codex hook trust documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

Raw hook stdin can contain sensitive content. It stays on loopback and is stripped at the receiver before callbacks or persistence. Hosted activity contains approved conversation titles and normalized status metadata. For a recent completed turn, the Mac companion can read the final agent answer and attach a bounded excerpt to the notification job and encrypted Web Push payload. It does not collect prompts, tool arguments, terminal output, diffs, or raw error messages. Titles and final replies can contain sensitive client information and may appear on the phone lock screen. See [notification preview rollout](docs/notification-reply-preview.md).

The [legacy command-line collector](collector/status-watchr.mjs) remains compatibility/diagnostic code, not the recommended always-on path. It does not have the native observer's disk queue or readiness reporting.

Unnamed subagents are labeled from their existing parent conversation and subtask metadata, for example `Project task: performance review`. Title changes can sync after a run finishes without generating another lifecycle event or completion alert. A separate bounded title-only repair corrects retained finished subagents outside the 100-conversation discovery window, including archived subtasks. Hosted ingestion preserves known names when an older collector sends a placeholder. See [conversation title repair and rollout gates](docs/conversation-title-repair.md). These changes require an approved web deployment and native release before they affect the installed pilot.

The dashboard groups subtasks under their highest retained parent using structured Codex IDs, with subtask activity in the parent's log. Counts and pagination apply to the grouped rows. Existing retained subtasks are backfilled without replaying completions; identical titles alone never merge conversations. This requires migration 008, an approved hosted deployment and a native update. See [conversation grouping and rollout gates](docs/conversation-grouping.md).

## Release and signing safety

Integration is `origin/main`. Work belongs on an isolated `kylebutler/` feature branch without tracking main.

The existing [manual macOS release workflow](.github/workflows/macos-release.yml) signs and publishes Sparkle artifacts, commits release assets, tags a release, and deploys production Netlify. Do not use it to test this branch. Source changes do not update the installed app.

Before any authorized native installation or publication, verify the source/base, monotonically increasing bundle version, code-signing identity and signature, notarization, Sparkle signature, and rollback path. Keep signing and VAPID private keys out of Git and chat. No push, PR, production migration, deployment, native installation/release, or public repository change is implied by local development.

## App Stylr

Pinned to [App Stylr v1.2.0 source](https://github.com/kylbutlr/app-stylr/tree/b3ca31ea264d5dd233fd871ac167247f1c306985). The existing Evening palette, semantic tokens, and product layout are preserved. See [the adoption note](docs/app-stylr-evening-adoption.md) and [implementation exceptions](docs/app-stylr-exceptions.md).
