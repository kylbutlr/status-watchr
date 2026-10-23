# Status Watchr

Backup alerts for the coding-agent conversations you choose to watch.

Status Watchr is a self-hosted dashboard and macOS observer for Codex Desktop
activity. Watch a conversation, leave the desk, and receive an optional phone
notification when a confirmed run finishes or fails. It supplements the agent
app's own notifications; it does not guarantee that every question, approval,
or completion will be detected or delivered.

[Downloads](https://github.com/kylbutlr/status-watchr/releases) ·
[Self-hosting](docs/self-hosting.md) ·
[Mac companion](apps/macos/README.md) ·
[Report an issue](https://github.com/kylbutlr/status-watchr/issues)

## Run locally

Requires Node.js 24 or newer. Extract the server download into its own directory:

```sh
npm ci --omit=dev
npm run start:local
```

Open [Status Watchr](http://127.0.0.1:4288/). This explicitly selects passwordless
loopback access. The server creates its own persistent embedded database and
owner-readable local secrets under `data/`. No Netlify account, Neon database,
App Switchr installation, or managed hosting account is required.

Stop the server with Ctrl+C in that terminal. Keep the data directory private and
retain it when upgrading. A missing password never silently turns authentication
off: `npm start` requires a configured password; `start:local` is the explicit
local choice. See [optional passwords and remote access](docs/self-hosting.md).

## What it does

- Observe local Codex conversation and run metadata without starting, resuming,
  replying to, or approving agent work.
- Persist watches across subsequent runs of a selected conversation.
- Confirm completion before making an alert eligible, including parent/child
  relationships and resumed work that can supersede an earlier completion.
- Queue normalized events locally when the server cannot be reached.
- Offer opt-in Web Push subscriptions, a generic test alert, device revocation,
  and visible notification coverage controls.
- Keep source availability, queued delivery, and observed status distinct so a
  successful dashboard refresh is not mistaken for successful monitoring.

Question and attention detection remains experimental. Codex's local metadata
schemas can change, and unavailable data must remain unavailable rather than be
guessed. Use this as a secondary signal, not an emergency or unattended-work
completion guarantee.

## Mac companion and phone alerts

The Mac companion is **source-only** in v1.0.0. Build it with Swift 6.2 or newer
on macOS 14 or newer. There is no prebuilt or notarized Mac download and no public
Sparkle update feed. Source builds use manual updates and do not install over an
existing app. The separate observer ingestion credential is not a dashboard
password. Follow [the Mac setup guide](apps/macos/README.md).

For an iPhone, the server must be reachable through an HTTPS origin you control.
Add the dashboard to the Home Screen, explicitly enable its notification device,
and test delivery. An HTTP loopback URL on your phone refers to the phone itself,
not the Mac. Local-only use does not require a domain or reverse proxy; phone
access does. The release does not provision that infrastructure for you.

## Privacy

Conversation titles and optional final-reply excerpts can contain private
information and may appear on a phone lock screen. Do not publish your data
directory, native queue, secrets, or database backups. The observer does not
provide remote-control endpoints or upload raw prompts and tool arguments.

Geist fonts and App Stylr assets are bundled locally. Web Push uses the browser's
push service only after you opt in. See [privacy and security](docs/privacy.md).

## Development

```sh
npm ci
npm run typecheck
npm test
npm run build:standalone
npm run package
cd apps/macos
swift test
```

The package command writes a standalone server archive, a clean source archive,
and SHA-256 checksums under `releases/`. These exclude personal rollout history,
old native update binaries, credentials, and real activity data. Local tests use
disposable data, not the installed private pilot or its hosted database.

Created by [Kyle Butler](https://kylbutlr.com). [MIT license](LICENSE).
