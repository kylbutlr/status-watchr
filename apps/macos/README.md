# Status Watchr Mac companion

A menu-bar observer for selected Codex Desktop conversations. Requires macOS 14
or newer. The native app retains the established bundle ID,
preferences, Keychain service, queue directories, and loopback hook port 48731 so
an existing 0.1.x installation can upgrade without losing its connection settings.
A new installation starts with a local-server URL and no ingestion credential.

## Installation and updates

Signed native downloads use separate `macos-v<version>` tags in
[GitHub Releases](https://github.com/kylbutlr/status-watchr/releases).
Existing signed installations use Check for
Updates and the signed appcast at `https://statuswatchr.netlify.app/updates/appcast.xml`.
Do not confuse the web/server `v1.0.0` source release with this native channel.
Apple notarization is not claimed. Do not disable macOS security protections.

## Configure your server

Run the standalone server first, then enter its origin and ingestion token from
`data/server-secrets.json` in the companion's settings. The default origin is
`http://127.0.0.1:4288`. Remote origins require HTTPS. Credentials never belong in
URLs, issue reports, or screenshots. The server token is separate from the
optional dashboard password. Start monitoring explicitly.

Recovery intervals, hooks, and experimental question alerts remain configurable.
The observer does not start, resume, answer, or approve agent conversations.
Source availability, completion confirmation, and queued delivery remain distinct.
Phone delivery needs your own HTTPS setup and a physical-device test.

## Build and verify source

Use the source archive or repository checkout, with Swift 6.2 or newer. The
standalone server archive does not include the Mac source:


```sh
swift test --jobs 2 --package-path apps/macos
swift run --configuration release --package-path apps/macos
```

The foreground source run stops with Ctrl+C. It does not replace an installed
bundle. Source runs use the same app preferences and hook ownership as the signed
app; do not run both observers at once. Test-only fixtures use temporary storage.

See [self-hosting](../../docs/self-hosting.md) and [privacy](../../docs/privacy.md).
