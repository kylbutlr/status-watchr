# Status Watchr Mac companion

A source-built menu-bar observer for selected Codex Desktop conversations.

Requires macOS 14 or newer and the Swift 6.2 toolchain. From the repository root:

```sh
swift run --configuration release --package-path apps/macos
```

This runs the source-built companion. It does not install over an existing Mac
app and does not use the private pilot's update feed. Stop this foreground run
with Ctrl+C. Public source builds update manually.

Start the standalone server first, then set the companion's server URL to
http://127.0.0.1:4288 and enter the ingestion token from the server's local
`data/server-secrets.json`. That token is separate from the optional dashboard
password. Start monitoring explicitly. Never put a token in a URL or issue.

Remote server URLs require HTTPS. Loopback HTTP is accepted for a server on the
same Mac. Requests carrying credentials do not follow redirects. Saved connection
settings use the existing native preferences and credential store; the public
release does not change or migrate another installed copy's settings.

The observer reads local Codex metadata without starting or resuming conversations.
A successful connection is not proof that the source is available. Completion
confirmation, parent/child suppression, and queued delivery all preserve explicit
unavailable states. Question/attention detection remains experimental.

```sh
swift test --package-path apps/macos
```

There is no prebuilt, notarized, or automatically updated Mac binary in v1.0.0.
A public signed-app channel would be a separate release with its own validation.
Read [self-hosting](../../docs/self-hosting.md) and [privacy](../../docs/privacy.md)
before configuring phone alerts or optional hooks.

Public source builds use loopback hook port `48732`, separate from the private pilot's `48731`. Installing or removing public hooks preserves the private handlers.
