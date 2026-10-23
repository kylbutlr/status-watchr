# Status Watchr agent contract

Status Watchr is a self-hosted web dashboard and macOS companion pinned to [App Stylr v1.2.0 source](https://github.com/kylbutlr/app-stylr/tree/b3ca31ea264d5dd233fd871ac167247f1c306985).

## Interface rules

- Keep `app-stylr.json`, the README pin, and `docs/app-stylr-exceptions.md` aligned.
- Preserve server-enforced single-owner authentication for hosted/password modes and explicit loopback-only passwordless access. Keep all credentials outside the client bundle.
- Use the pinned App Stylr dark semantic values for application chrome.
- Record intentional visual or implementation differences in `docs/app-stylr-exceptions.md`.
- Render the creator handle only as `kylbutlr`.
- Keep status colors paired with text labels and preserve keyboard focus, phone layout, and reduced-motion behavior.
- Do not push, create a pull request, publish a release, or deploy without explicit approval in the current request.

## Required visual review

Before interface work, review the [App Stylr Visual Reference](https://app-stylr.netlify.app/reference/) and [Style Guide](https://app-stylr.netlify.app/reference/style-guide.html). The pinned v1.2.0 source revision remains the implementation source of truth.

## Verification

Run `npm run typecheck`, `npm test`, and `npm run build` before considering a change complete.
