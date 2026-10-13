# App Stylr exceptions

Status Watchr preserves these implementation differences from its pinned App Stylr v1.2.0 source contract.

| Area | App Stylr default | Local requirement | Reason | Owner | Review trigger |
| --- | --- | --- | --- | --- | --- |
| CSS integration | Generated semantic adapter | Existing local semantic aliases with matching v0.4.0 dark values | Preserve the established dashboard and status-specific state styles without a visual rewrite | Status Watchr | Next App Stylr upgrade |
| Typography delivery | Bundled Geist font files | Google-hosted Geist and Geist Mono | Preserve the existing web build while the font delivery strategy remains unchanged | Status Watchr | Offline or privacy hardening |
| macOS menu-bar icon | App semantic status colors | Adaptive monochrome template: rising bars cut out of a filled circle while observing; three flattened bars inside an outlined circle when stopped; distinct outlined starting/attention/error glyphs | Match the approved state treatment while retaining accessible state labels; panel status colors remain unchanged | Status Watchr | Menu-bar accessibility or appearance review |

The selected design is preserved on local prototype branch `kylebutler/menu-icon-prototypes` in `flattened-bars.swift`: three rising bars when active and the same bars collapsed to equal-height baseline marks when stopped. Filled means the controller reports observing local runs, not that hosted delivery is healthy or an agent is currently busy.
