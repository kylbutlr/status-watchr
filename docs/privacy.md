# Privacy

Status Watchr observes local Codex conversation and run metadata. It sends
normalized lifecycle events, selected titles, and optionally a bounded final-reply
excerpt to the server you configure. It does not send raw prompts, tool arguments,
terminal output, or raw hook stdin. Local queues and database backups can still
contain sensitive titles and excerpts and should stay private.

The dashboard has no analytics or font CDN requirement. Local-only use does not
contact a hosted Status Watchr service. Optional Web Push sends encrypted payloads
through the browser's push service after device opt-in; the server retains the
subscription required for delivery. Revoke the device through notification settings.

The native observer's optional hook path and its permissions are separate from
installing or building the app. Monitoring never starts or approves agent work.
Metadata availability and phone delivery can fail independently. Do not treat an
observed status as proof that an assignment is finished or a person has seen it.

By default, event/session history is retained for 30 days and old notification
and question records for seven days, with a periodic local cleanup. Backups are
outside that cleanup and remain your responsibility. Review exports and screenshots
before sharing an issue. Never include secrets, tokens, or a real activity database.
