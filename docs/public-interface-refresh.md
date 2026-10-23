# Public interface and native update scope

User-approved: keep App Stylr charcoal/mint; refresh dashboard layout, padding,
inputs, selects and readable displays. Add workspace/display names, dark/light
appearance, comfortable/compact density, and default activity view. Preferences
are browser-local, handle unavailable storage, and never change server identity,
authentication, watches, or notification opt-in.

Native v1.0.0 uses the existing app identity and signed update channel. Restore
the canonical preference, Keychain, data and hook ownership so 0.1.x upgrades keep
their settings. Retain user-configurable origins, recovery interval and opt-ins.
Use a separate `macos-v1.0.0` tag instead of rewriting the existing source tag.
Prepare and verify the signed archive and feed through the existing manual CI
workflow. No installed app is stopped or replaced during development.

Browser review remains blocked by the stale error-page URL policy. Source and
automated checks do not establish visual acceptance or physical phone delivery.

## Verification, 2026-10-22

- The full web/server pass passed 159 tests, the standalone HTTP rehearsal,
  type checking, and the build. Native tests executed 123 cases with five
  opt-in skips and no failures.
- After the final README and control refinements, type checking, 11 focused
  preference/release tests, shell syntax, the standalone build, and packaging
  passed again. Both curated archives contain the README images and all of
  their relative documentation targets.
- The native signing workflow is prepared, not dispatched. The signed archive,
  updated public appcast, and installed-app update remain unverified for 1.0.0.
- Publishing the web/server refresh as 1.1.0 preserves the existing v1.0.0 tag.
  Native 1.0.0 uses its own tag and does not rewrite that source release.
