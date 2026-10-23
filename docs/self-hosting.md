# Self-hosting Status Watchr

## Install the server

Use Node.js 24 or newer. Download and extract the server archive, then run
`npm ci --omit=dev` followed by `npm run start:local`. Open
http://127.0.0.1:4288. Stop with Ctrl+C in the same terminal.

The server binds only to 127.0.0.1 and uses a persistent PGlite database under
`data/database`. Generated ingestion, session, and Web Push secrets live in
`data/server-secrets.json`, with owner-only file permissions. They are not
printed at startup or served by the web server. Do not commit or share them.

## Optional password

Use `.env.example` as a template for an ignored `.env`, without overwriting an
existing file. Set `WATCHR_AUTH_MODE=password` and a unique 16–256 character
`WATCHR_ACCESS_PASSWORD`, then run `npm start`. Passwordless mode requires the
explicit `WATCHR_AUTH_MODE=none` choice and a loopback origin. Remove a configured
password before selecting that mode. The dashboard has no separate cloud account.

The native companion always uses its own ingestion token. Local passwordless
access does not allow an unauthenticated client to upload agent activity.

## Pair the Mac companion

Build from [the Mac source](../apps/macos/README.md). In its settings, enter the
server origin and the `ingestToken` from your local secrets file. Open that file
locally; do not paste it into an issue or chat. Start monitoring deliberately.
HTTP is accepted only for loopback; remote ingestion requires HTTPS. Redirects
are not followed with the ingestion credential.

## Phone access

Choose a stable HTTPS origin served by your own reverse proxy and set
`WATCHR_ORIGIN` to that exact origin. Use password authentication. Route the proxy
to this loopback server without exposing its data directory. The release does
not request a domain, create a tunnel, or configure your router automatically.

On iPhone, add the site to the Home Screen, sign in there, explicitly enable the
notification device, and send a test notification. A localhost address on the
phone cannot reach the Mac. Browser/OS push permission and a successful test
remain prerequisites; unit tests do not prove phone delivery.

VAPID keys are generated locally on first startup. Advanced installations can
supply their own `WATCHR_VAPID_PUBLIC_KEY`, `WATCHR_VAPID_PRIVATE_KEY`, and
`WATCHR_VAPID_SUBJECT`. Preserve the keys when updating, or existing subscriptions
will need to be recreated. External push requests occur only for opted-in devices.

## Persistence and updates

The server locks its data directory to one process. Stop it before backing up
or moving that directory. After a crash, verify the old process is gone before
removing a stale `server.lock`. Never delete a live lock to force a second server.

Extract updates separately, keep a stopped-server backup, install the locked
runtime dependencies, and select the existing directory with `WATCHR_DATA_DIR`.
Schema migrations are tracked transactionally and do not rerun completed files.
Pending events and notification retries survive normal restarts. Retention
removes old events and delivery records under the documented application policy;
keep backups if you need longer history.

## Existing hosted adapters

The Netlify adapter remains available for deliberately configured hosted installs.
It keeps its existing password, ingestion, database, and server-only secret
boundaries. The standalone passwordless option is injected only by the local
server and cannot silently disable authentication in the hosted handler.
