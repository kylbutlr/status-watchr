# status-watchr: public v1.0.0 release scope

## User-approved requirements

- Prepare a professional public-source app using the existing App Stylr design.
- Run on the user's own machine without Kyle's hosted services or private records.
- Make local password protection optional through an explicit configuration choice.
- Preserve authentication for the existing public Netlify frontend.
- Keep native/agent ingestion credentials separate from the optional owner password.
- Rewrite the README for a new user, with actual installation and update steps.
- Package GitHub downloads with file manifests, checksums, and an open-source license.
- Use v1.0.0 because the verified current versions are below 1.0.0 and no GitHub releases exist.
- Keep the existing repository and its history. Kyle explicitly chose to make the existing repository public after being informed that it contains prior rollout documentation and screenshots. Check for credentials before changing visibility.

## Verification boundary

Use disposable data only. Verify password and passwordless modes, origin/CSRF
checks, persistence and restart, build, package contents, and current source.
Native Status Watchr is source-only, without installing or modifying the private
pilot or publishing its update feed. Physical phone delivery is separate evidence.

Fresh browser review is pending because Browser Use rejects the stale error tab.
Kyle chose existing-repository publication, without renaming or replacing it. No repository visibility, hosted deployment, real ledger, native
installation, or notification-device settings have been changed in this pass.
