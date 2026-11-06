# App Stylr exceptions

Status Watchr preserves these implementation differences from its pinned App Stylr v1.4.1 source contract.

| Area | App Stylr default | Local requirement | Reason | Owner | Review trigger |
| --- | --- | --- | --- | --- | --- |
| CSS integration | Generated semantic adapter | Local semantic aliases based on the pinned v1.4.1 foundation | Preserve dashboard-specific status styles while sharing theme and control roles | Status Watchr | Next App Stylr upgrade |
| Typography delivery | Bundled Geist font files | Locally bundled Geist and Geist Mono | Preserve the existing web build while the font delivery strategy remains unchanged | Status Watchr | Offline or privacy hardening |
| macOS menu-bar icon | App semantic status colors | Adaptive monochrome template: rising bars cut out of a filled circle while observing; three flattened bars inside an outlined circle when stopped; distinct outlined starting/attention/error glyphs | Match the approved state treatment while retaining accessible state labels; panel status colors remain unchanged | Status Watchr | Menu-bar accessibility or appearance review |

The selected design is preserved on local prototype branch `kylebutler/menu-icon-prototypes` in `flattened-bars.swift`: three rising bars when active and the same bars collapsed to equal-height baseline marks when stopped. Filled means the controller reports observing local runs, not that hosted delivery is healthy or an agent is currently busy.

## Public self-hosted release

Geist fonts are bundled under public/fonts with their license. No Google Fonts request is needed. Existing local semantic aliases, layouts, status labels, focus states, phone navigation, and reduced-motion behavior are retained.

Mac source builds and signed releases share the established app identity,
preferences, Keychain service, application-support directories, and hook
ownership. The native upgrade preserves existing connection settings. Do not
run the source observer and installed observer at the same time. Server entry
accepts HTTP only for loopback; all non-local origins retain HTTPS and redirect
rejection.

## Public interface refresh

The product retains its charcoal/mint identity and uses a local candidate of the optional shared controls recipe from the App Stylr v1.3.0 refresh. Workspace labels, density, default views and storage behavior remain product-owned. Browser-local display names never alter server authentication or audit identity. Fresh visual review remains pending browser authority.

## App Stylr v1.4.1 visual refresh

The shared adapters and Geist assets come from immutable source 6fbc524f07ed7aa7db9c8593bf8116b9440937bc. Sage/dark/Normal and Comfortable remain the defaults, with existing product preferences preserved. Shared geometry uses 4px controls/buttons, 8px cards and 12px dialogs. Feedback stays on neutral surfaces with semantic text/icons. Existing foreground glyphs use the palette-independent Graphite base, with scalable SVG masters and directly rendered high-resolution exports. Keep the incumbent layout, keyboard behavior, auth, data, integrations and platform-specific controls intact.
