<img src="public/favicon.svg" width="64" height="64" alt="">

# Status Watchr

Backup alerts for the coding-agent conversations you choose to watch.

Status Watchr pairs a Mac menu-bar observer for Codex Desktop with a self-hosted
activity dashboard. Follow a conversation, step away, and receive an optional
phone notification when confirmed work finishes or fails. Your server, watched
conversations, and notification devices stay under your control.

[Download releases](https://github.com/kylbutlr/status-watchr/releases) ·
[Self-hosting guide](docs/self-hosting.md) ·
[Mac companion](apps/macos/README.md) ·
[Report an issue](https://github.com/kylbutlr/status-watchr/issues)

## Availability

Versioned server and source archives are distributed through GitHub Releases,
with file manifests and SHA-256 checksums. The original web/server v1.0.0 release
includes Mac source. The signed **macOS v1.0.0** update is being prepared as a
separate native release; it is not included in the earlier server download.

| Component | Requirements | Installation |
| --- | --- | --- |
| Dashboard and server | Node.js 24 or newer | Server archive, persistent embedded database |
| Mac observer | macOS 14 or newer; Swift 6.2+ for source builds | Native releases or source build, see the Mac guide |
| Optional phone alerts | Supported Web Push browser and your own HTTPS origin | Explicit device registration and delivery test |

No maintainer-hosted account, Netlify account, managed database, or additional
companion app is required for local use. This is a secondary notification
signal, not a guarantee that every completion, question, or approval is detected.

## What it does

- Watch selected conversations across subsequent runs and resumed work.
- Separate active, finished, failed, stale, and attention states in one dashboard.
- Confirm completion before making an alert eligible; newer activity can
  supersede an earlier finished signal.
- Preserve normalized events and delivery retries through normal server restarts.
- Manage optional notification devices and watches without granting remote
  control of the agent.
- Show source availability and last check-in separately from dashboard refresh.

The observer does not start, resume, reply to, or approve agent conversations.
Question and attention detection is experimental because local agent metadata
can change.

## Quick start

Download the server archive and its checksums from Releases, verify and extract
it into a fresh directory, then open a terminal in that directory. With Node.js
24 or newer:

```sh
npm ci --omit=dev
npm run start:local
```

Open [your local dashboard](http://127.0.0.1:4288/). Stop the server with Ctrl+C
in the same terminal. The server binds to loopback and creates persistent data
and owner-only secrets under `data/`.

`start:local` explicitly selects passwordless local access. To use a password,
configure `WATCHR_AUTH_MODE=password` and `WATCHR_ACCESS_PASSWORD` in an ignored
`.env`, then use `npm start`. Missing credentials never silently disable
password protection. Follow [optional passwords and remote access](docs/self-hosting.md).

### Connect the Mac and watch a conversation

1. Start your server, then follow the [Mac setup guide](apps/macos/README.md).
2. Enter your server origin and its ingestion token in the companion. The token
   is stored in your local `data/server-secrets.json`; never paste it into chat
   or an issue. It is separate from the optional dashboard password.
3. Start monitoring deliberately and choose the conversations to watch.
4. For phone alerts, configure an HTTPS origin you control, register the device,
   and test delivery before relying on it.

A localhost address on a phone refers to that phone, not your Mac. Phone access
requires your own reachable HTTPS setup; the release does not create a tunnel,
domain, reverse proxy, or hosted service for you.

## Make it yours

Workspace preferences provide browser-local workspace and display names, dark
or light appearance, comfortable or compact spacing, and a default activity
view. Dashboard refresh cadence, watches, and notification devices have their
own controls. Personal display labels never change authentication, ingestion
credentials, or notification permissions.

The Mac companion lets you configure the server origin, recovery interval,
hooks, and experimental question alerts. The native upgrade retains the
established app identity, preferences, Keychain service, and queue directories
so existing users keep their configuration.

## Privacy and security

Activity lives on your server. Conversation titles and optional final-reply
excerpts can contain sensitive information and may appear on a phone lock
screen. The observer does not upload raw prompts, tool arguments, or source
diffs as dashboard activity. Web Push contacts the browser's push service only
for opted-in devices.

Keep `data/`, native queues, credentials, and backups private. Remote origins
require HTTPS. Native ingestion always requires a separate token, including
when the local dashboard has no password. Read [privacy](docs/privacy.md) and
[security reporting](SECURITY.md) before sharing diagnostics.

## Updates and limitations

Updates are manual for the standalone server. Stop it, back up its data,
extract the new release separately, and reconnect the existing data directory
as described in [self-hosting](docs/self-hosting.md). Do not overwrite a live
installation or remove a process lock to force another server to start.

Existing signed Mac installations use their signed appcast through Check for
Updates. Native downloads are published separately from server/source releases.
Apple notarization is not claimed. Fresh browser acceptance and physical phone
delivery remain separate checks; automated tests do not establish either.

## Development

Use the source download or a repository checkout with Node.js 24 or newer.
The server archive is for running the app, not development. Work with disposable
activity and notification fixtures:

```sh
npm ci
npm run typecheck
npm test
npm run build:standalone
npm run verify:standalone
npm run package
```

The standalone rehearsal starts and stops disposable loopback servers. Packaging
writes versioned server/source archives, manifests, and checksums under
`releases/`; it does not publish them. Native verification uses
`swift test --jobs 2 --package-path apps/macos` without starting real monitoring.
See [contributing](CONTRIBUTING.md) and the [changelog](CHANGELOG.md).

## Design foundation

The interface uses bundled Geist fonts and [App Stylr v1.2.0](https://github.com/kylbutlr/app-stylr/tree/b3ca31ea264d5dd233fd871ac167247f1c306985),
with the optional native-control recipe from the pending v1.3.0 refresh.
The [Visual Reference](https://kylbutlr.com/app-stylr) explains the shared
foundation; [implementation notes](docs/app-stylr-exceptions.md) record product
choices. Layout and application behavior remain owned by Status Watchr.

## Support and license

Use [GitHub Issues](https://github.com/kylbutlr/status-watchr/issues) for bugs and
suggestions. Include your version, operating system, installation type, and
reproduction steps using fictional data. Never include tokens, passwords,
private conversation titles, or confidential screenshots.

Created by [kylbutlr](https://kylbutlr.com). Available under the [MIT License](LICENSE).
