# Status Watchr agent contract

Status Watchr is a self-hosted web dashboard and macOS companion pinned to [App Stylr v1.4.1 source](https://github.com/kylbutlr/app-stylr/tree/v1.4.1).

## Interface rules

- Keep `app-stylr.json`, the README pin, and `docs/app-stylr-exceptions.md` aligned.
- Preserve server-enforced single-owner authentication for hosted/password modes and explicit loopback-only passwordless access. Keep all credentials outside the client bundle.
- Use the pinned App Stylr dark semantic values for application chrome.
- Record intentional visual or implementation differences in `docs/app-stylr-exceptions.md`.
- Render the creator handle only as `kylbutlr`.
- Keep status colors paired with text labels and preserve keyboard focus, phone layout, and reduced-motion behavior.
- Do not push, create a pull request, publish a release, or deploy without explicit approval in the current request.

## Required visual review

Before interface work, review the [App Stylr Visual Reference](https://kylbutlr.com/app-stylr) and [Style Guide](https://kylbutlr.com/app-stylr). The pinned v1.4.1 source revision remains the implementation source of truth.

## Verification

Run `npm run typecheck`, `npm test`, and `npm run build` before considering a change complete.

## Visual foundation maintenance

Keep Sage/dark/Normal defaults, precise 4px controls, 8px cards and 12px dialogs, and quiet semantic feedback. Preserve product layouts and existing glyphs. Keep a scalable SVG master and inspect 16/32px legibility plus 128/512px Retina quality. Use the neutral Graphite base independently of accent palettes. Shared adapters are generated or vendored from the exact public v1.4.1 source, never edited independently.
