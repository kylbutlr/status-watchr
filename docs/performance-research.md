# Status Watchr performance and realtime research

Research date: 2026-09-02

Scope: a mobile-first Netlify frontend, a macOS connector that posts lifecycle events, and Neon as the system of record. This report compares ordinary polling, adaptive polling, Server-Sent Events (SSE), and WebSockets using current official documentation. Recommendations marked as such are architectural inferences from those sources and the current repository shape.

## Decision

Use adaptive polling as the first production delivery mechanism for dashboard reads. Keep the macOS connector responsible for collecting events and posting them over HTTPS. Keep Neon behind Netlify Functions, with the browser never receiving database credentials.

This fits the current boundaries: the connector already has lifecycle hooks plus polling as a recovery path, the API has a POST event-ingestion route and a GET session snapshot route, and the API currently marks JSON responses `Cache-Control: no-store` ([connector README](../README.md), [API function](../netlify/functions/api.mts)). It also avoids paying the operational cost of a long-lived browser connection for a private monitor whose primary need is reliable, recent state rather than sub-second collaboration.

## Implemented baseline

- Dashboard refreshes are sequential, pause while hidden or offline, resume immediately on visibility or reconnect, and use bounded failure backoff. The selected user interval remains the normal cadence.
- Snapshot refreshes send a revision token. Unchanged data returns `304 Not Modified`, while stale-threshold crossings also advance the revision so an abandoned active item still changes state on time.
- The snapshot carries only the latest event for each visible task. Full 30-day timelines load only for the selected task and are capped at 100 events.
- Connector lifecycle hooks remain immediate. Unchanged polling heartbeats have a two-minute floor, or use the selected connector interval when it is longer. A manual Mac refresh bypasses the heartbeat throttle.
- Event ingestion performs the session upsert and event insert in one Neon HTTP transaction. The dashboard query window is bounded to 30 days and supported by dedicated revision, freshness, task-ranking, and event indexes.

## Current repository shape

- The macOS companion observes hook events and retains polling as a fallback. Its documented refresh choices are 15 seconds through 60 minutes, with 30 seconds as the default ([project README](../README.md#macos-companion-app)).
- The connector posts normalized metadata only, not prompts, source code, terminal output, or diffs by default ([project README](../README.md#data-boundary)).
- `/api/sessions` reads the current session snapshot and recent events from Neon. `/api/events` accepts authenticated lifecycle events and uses event IDs for duplicate protection ([API function](../netlify/functions/api.mts#L74), [API function](../netlify/functions/api.mts#L128)).
- The shared JSON response helper explicitly sets `Cache-Control: no-store`, which is appropriate for private, rapidly changing status data ([API function](../netlify/functions/api.mts#L17)).

## Official platform findings

### Netlify Functions and hosting

- Netlify Functions are request/response endpoints. The current Functions configuration documentation lists a 60-second synchronous execution limit, 6 MB buffered request/response payload, and 20 MB streamed response payload. Background Functions can run up to 15 minutes, but return an immediate `202` and do not stream a response ([Functions configuration](https://docs.netlify.com/build/functions/configuration/), [Background Functions](https://docs.netlify.com/build/functions/background-functions/)).
- Netlify documents streaming by returning a `ReadableStream`, and its current Functions API reference says streamed responses have a 60-second execution limit and 20 MB response limit ([Functions API reference](https://docs.netlify.com/build/functions/api/)). However, a separate official Lambda compatibility page, crawled recently, says streaming has a 10-second execution limit. This is an unresolved documentation conflict. Any SSE proof of concept should verify the effective limit for the project and plan, and should not assume an indefinitely open stream ([Lambda compatibility](https://docs.netlify.com/build/functions/lambda-compatibility/)).
- Netlify Functions and Edge Functions are not cached by default. Netlify's documented default for dynamic responses is `Cache-Control: public, max-age=0, must-revalidate`; the current Status Watchr API is stricter with `no-store`, which avoids shared-cache exposure and stale private state ([caching overview](https://docs.netlify.com/build/caching/caching-overview/)). Do not add public CDN caching to an authenticated per-owner status snapshot. A short CDN TTL is only appropriate for intentionally public, non-sensitive aggregates.
- Netlify lets a site or function run in one selected Functions region and recommends placing compute near the database when measured roundtrip savings justify it. The documented new-site default is `cmh` in Ohio, but the actual project and Neon region should be checked before changing it ([Functions configuration, region](https://docs.netlify.com/build/functions/configuration/#region)).
- The Edge Functions API lists the WebSocket Web API as supported, but the official Edge documentation describes request middleware/endpoints, not a Netlify-managed, durable WebSocket service. Edge limits include 50 ms of CPU time per request and a 40-second response-header timeout ([Edge Functions API](https://docs.netlify.com/build/edge-functions/api/), [Edge Functions limits](https://docs.netlify.com/build/edge-functions/limits/)). Netlify's own WebSocket example uses an external managed realtime provider, Ably, with a Netlify Function issuing short-lived authentication material ([Netlify's WebSockets and serverless guide](https://www.netlify.com/blog/web-sockets-in-a-serverless-world/)).
- Function usage is metered by compute duration on current credit-based plans, while legacy plans bill by request count. Either way, an unnecessarily frequent dashboard poll creates measurable platform usage ([Functions usage and billing](https://docs.netlify.com/build/functions/usage-and-billing/)).

### Neon serverless driver and connections

- The Neon serverless driver carries PostgreSQL queries over HTTP or WebSockets instead of raw TCP. Neon recommends HTTP for faster single, non-interactive, one-shot queries, including multiple queries in one non-interactive transaction. It recommends WebSockets when session state, interactive transactions, or `node-postgres` compatibility is required ([Neon serverless driver](https://neon.com/docs/serverless/serverless-driver)).
- The same Neon driver documentation lists a 64 MB maximum request and response size for HTTP queries. Status snapshots and lifecycle events should remain far below this by selecting only needed columns and bounding the event window ([Neon serverless driver](https://neon.com/docs/serverless/serverless-driver)).
- Neon says HTTP connection caching is enabled by default at the Neon proxy for serverless-driver fetch queries. It provides server-side connection reuse for both pooled and unpooled connection strings, so creating the HTTP query function inside a short-lived Netlify invocation does not imply a brand-new database connection for every query ([Neon connection-caching changelog](https://neon.com/docs/changelog/2024-02-16)).
- Neon pooling uses a `-pooler` connection string and can support up to 10,000 concurrent client connections, but the pool is transaction-oriented and does not make 10,000 interactive database sessions available simultaneously. Neon recommends a direct, non-pooled connection for migrations ([Neon connection pooling](https://neon.com/docs/connect/connection-pooling)).
- Neon documents that WebSocket `Pool` or `Client` connections cannot outlive a single request in serverless environments, and must be connected, used, and closed within that request. Applying that lifecycle rule to Netlify Functions is an architectural inference, but it is the safe assumption. The current HTTP `neon()` pattern avoids making a database WebSocket the same thing as a browser realtime channel ([Neon serverless driver](https://neon.com/docs/serverless/serverless-driver)).

## Delivery comparison

| Option | Freshness and behavior | Netlify and Neon fit | Main costs or risks | Verdict for Status Watchr |
| --- | --- | --- | --- | --- |
| Ordinary polling | Fixed interval; worst-case freshness is roughly one interval. At the documented 30-second default, one continuously open tab makes 2,880 reads per 24 hours, a simple arithmetic inference. | Excellent. Each read is a short HTTP Function invocation and a one-shot Neon HTTP query. | Repeated requests while nothing changes; predictable but wasteful. | Good baseline, but improve it with state-aware cadence. |
| Adaptive polling | Poll quickly while a session is working or needs attention, slow down when all sessions are quiet, pause or greatly reduce work for a hidden tab, and fetch immediately on focus, manual refresh, reconnect, or a connector event acknowledgement. | Best fit. It uses documented Functions behavior and current connector interval choices without requiring a persistent server process. | Requires a small client state machine and careful backoff. A quiet tab must still resync when it becomes visible. | Recommended now. Start at 15 to 30 seconds for active/attention states, move to 60 seconds or longer when quiet, and use bounded exponential backoff for failures. These cadence values are recommendations, not platform limits. |
| SSE | One-way server-to-browser stream using `EventSource`; browsers can reconnect when a connection closes. SSE is a natural read-only model, but requires keepalives, replay/cursor handling, and a source that can fan out new events ([MDN SSE](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)). | Weak as a long-lived Netlify Function. Netlify documents streaming, but its official pages conflict between 60 seconds and 10 seconds, and Background Functions cannot stream. Neon can store the event log, but a database query does not itself provide browser fanout. | Stream termination, mobile/network reconnects, duplicate or missed events without `id`/cursor replay, and a Function invocation that remains open until the documented limit. | Defer. Consider only with an external realtime relay or a separately hosted long-running service, and retain polling as resync fallback. |
| WebSockets | Bidirectional persistent connection with explicit open, message, error, and close handling. The browser API has no built-in backpressure, so a high-rate producer can exhaust memory or CPU ([MDN WebSocket](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket)). | Poor need-to-complexity ratio. The macOS connector only needs to post events, not receive a command stream. Netlify's official example delegates persistent WebSocket hosting to Ably. Neon WebSockets are for database-driver sessions, not a browser notification bus. | External service or long-running server, authentication and reconnect protocol, ordering/replay, connection fanout, mobile connection churn, and a separate operational failure mode. | Not justified for the current architecture. Revisit only if the product needs interactive browser-to-connector messaging or genuinely sub-second updates at scale. |

## Recommended implementation direction

1. Keep POST ingestion event-driven from the macOS connector. Hooks provide low-latency hints, while the connector's existing polling scan remains the recovery path. The database remains the durable source of truth.
2. Make dashboard reads adaptive. Use one in-flight request at a time, reset the timer after a response, add jitter to avoid synchronized clients, back off on network or `5xx` errors, and force a fresh read on visibility/focus and manual refresh. Treat a response as a snapshot, not as an append-only event stream.
3. Preserve `no-store` for authenticated status responses. Do not use Netlify's public CDN caching or durable cache for this per-owner snapshot. Netlify Functions are uncached by default, but explicitly avoiding storage is clearer and safer for this data class.
4. Keep the Neon read path on the HTTP serverless driver. If session and event writes later need atomic multi-query behavior, Neon supports a non-interactive `transaction()` over HTTP. Use WebSocket `Pool` or `Client` only for a real session/interactive-transaction requirement, and close it inside the Function invocation. Verify whether the deployment connection string should be pooled as concurrency grows, while keeping migrations on a direct connection.
5. If a future requirement demands realtime push, add a dedicated realtime layer rather than holding a Netlify Function open indefinitely. A Netlify Function can authenticate the browser to a managed provider, following Netlify's documented Ably pattern. The provider should publish an event or invalidation signal, while the browser still performs an authenticated snapshot fetch to reconcile state. This preserves Neon as the source of truth and makes reconnects safe.

## Sources

Primary sources reviewed on 2026-09-02:

- [Netlify Functions configuration and limits](https://docs.netlify.com/build/functions/configuration/)
- [Netlify Functions API reference](https://docs.netlify.com/build/functions/api/)
- [Netlify Lambda compatibility and streaming](https://docs.netlify.com/build/functions/lambda-compatibility/)
- [Netlify Background Functions](https://docs.netlify.com/build/functions/background-functions/)
- [Netlify caching overview](https://docs.netlify.com/build/caching/caching-overview/)
- [Netlify Edge Functions API](https://docs.netlify.com/build/edge-functions/api/)
- [Netlify Edge Functions limits](https://docs.netlify.com/build/edge-functions/limits/)
- [Netlify Functions usage and billing](https://docs.netlify.com/build/functions/usage-and-billing/)
- [Netlify WebSockets in a serverless world](https://www.netlify.com/blog/web-sockets-in-a-serverless-world/)
- [Neon serverless driver](https://neon.com/docs/serverless/serverless-driver)
- [Neon connection pooling](https://neon.com/docs/connect/connection-pooling)
- [Neon serverless-driver connection caching changelog](https://neon.com/docs/changelog/2024-02-16)
- [MDN: Using server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)
- [MDN: WebSocket](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket)
